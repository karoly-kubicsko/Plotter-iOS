import SwiftUI
import UIKit

/// A curve ready to draw: its compiled function and colour.
struct CurveInput: Identifiable {
    let id: UUID
    /// The real value, or the real part of a complex value (solid line).
    let function: CompiledFunction
    /// The imaginary part of a complex value (dashed line), if any.
    let imaginary: CompiledFunction?
    let color: Color
    let name: String
    /// Cartesian: the function is y(x). Polar: it is r(θ).
    let system: CoordinateSystem
}

/// The 2D graph: grid, axes, curves and a hover read-out.
struct Plot2DView: View {
    /// The plot background. Color is Sendable, so the renderer may read it from any thread.
    nonisolated static let background = Color(uiColor: .systemBackground)

    let document: PlotDocument
    @State private var hover: CGPoint?
    @State private var size: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let curves = document.visibleFunctions.compactMap { f -> CurveInput? in
            guard let compiled = f.compiled else { return nil }
            return CurveInput(id: f.id, function: compiled, imaginary: f.imaginary, color: f.color,
                              name: f.displayName, system: f.system ?? .cartesian)
        }
        let thetaMax = 2 * Double.pi * Double(max(document.thetaTurns, 1))
        let polarGrid = document.plane == .polar
        let camera = document.camera2D ?? Camera2D.standard(for: size)
        let hoverInfo = hover.flatMap { nearestPoint(to: $0, curves: curves, camera: camera, thetaMax: thetaMax) }
        let pixel = 1 / max(displayScale, 1)

        Canvas(opaque: false) { context, canvasSize in
            let renderer = Plot2DRenderer(camera: camera, size: canvasSize, pixel: pixel, thetaMax: thetaMax)
            if polarGrid {
                renderer.drawPolarGrid(in: &context)
            } else {
                renderer.drawGrid(in: &context)
            }
            renderer.drawCurves(curves, in: &context)
            if let hoverInfo {
                renderer.drawHover(hoverInfo, in: &context)
            }
        }
        .overlay {
            PlotInteractionView(
                onPan: { delta in
                    var c = document.camera2D ?? Camera2D.standard(for: size)
                    c.pan(by: delta)
                    document.camera2D = c
                },
                onZoom: { factor, anchor in
                    var c = document.camera2D ?? Camera2D.standard(for: size)
                    c.zoom(by: factor, at: anchor, size: size)
                    document.camera2D = c
                },
                onHover: { hover = $0 },
                onDoubleClick: { document.resetView() },
                onGestureEnd: { document.save() }
            )
        }
        .overlay(alignment: .topLeading) {
            if let hoverInfo {
                HoverLabel(info: hoverInfo)
                    .position(x: hoverInfo.screen.x, y: hoverInfo.screen.y)
                    .offset(labelOffset(for: hoverInfo.screen))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            size = newSize
            if document.camera2D == nil, newSize.width > 0 {
                document.camera2D = Camera2D.standard(for: newSize)
            }
        }
        .onChange(of: document.resetToken) {
            withAnimation(.smooth(duration: 0.35)) {
                document.camera2D = Camera2D.standard(for: size)
            }
            document.save()
        }
        .accessibilityElement()
        .accessibilityIdentifier("plot2d")
        .accessibilityLabel("2D graph")
        .accessibilityValue(UITesting.isEnabled
            ? String(format: "cx=%.5f cy=%.5f upp=%.8f hover=%d", camera.centerX, camera.centerY,
                     camera.unitsPerPoint, hoverInfo == nil ? 0 : 1)
            : curves.map(\.name).joined(separator: ", "))
    }

    /// Places the hover label beside the point, flipping it near the right and top edges.
    private func labelOffset(for point: CGPoint) -> CGSize {
        let dx: CGFloat = point.x > size.width - 200 ? -96 : 96
        let dy: CGFloat = point.y < 60 ? 30 : -30
        return CGSize(width: dx, height: dy)
    }

    private func nearestPoint(to point: CGPoint, curves: [CurveInput], camera: Camera2D,
                              thetaMax: Double) -> HoverInfo? {
        let world = camera.worldPoint(point, size: size)
        var best: HoverInfo?
        let step = NiceNumbers.step(span: camera.unitsPerPoint * 100, targetCount: 10)
        for curve in curves {
            if curve.system == .polar {
                if let candidate = nearestPolarPoint(curve, world: world, pointer: point, camera: camera,
                                                     thetaMax: thetaMax, step: step),
                   best == nil || candidate.distance < best!.distance {
                    best = candidate.info
                }
                continue
            }
            let re = curve.function(world.x)
            let im = curve.imaginary.map { $0(world.x) }
            // The dot goes on whichever part (Re or Im) is nearer the pointer.
            var candidates: [Double] = [re]
            if let im { candidates.append(im) }
            for y in candidates where y.isFinite {
                let screen = camera.screenPoint(x: world.x, y: y, size: size)
                let distance = Double(abs(screen.y - point.y))
                guard distance < 120, screen.y > -20, screen.y < size.height + 20 else { continue }
                if best == nil || distance < best!.distance {
                    best = HoverInfo(x: world.x, y: re, imaginary: im, screen: screen, color: curve.color,
                                     name: curve.name, step: step, distance: distance)
                }
            }
        }
        return best
    }
}

extension Plot2DView {
    /// The point of a polar curve nearest the pointer. For the pointer's direction θ₀ it tries
    /// every θ = θ₀ + kπ in the drawn range (odd k reach the curve through a negative r) and
    /// keeps the one closest on screen.
    fileprivate func nearestPolarPoint(
        _ curve: CurveInput, world: (x: Double, y: Double), pointer: CGPoint, camera: Camera2D,
        thetaMax: Double, step: Double
    ) -> (info: HoverInfo, distance: Double)? {
        guard world.x != 0 || world.y != 0 else { return nil }
        let base = atan2(world.y, world.x)
        var best: (info: HoverInfo, distance: Double)?
        var k = Int((-base / Double.pi).rounded(.down)) - 1
        while true {
            let theta = base + Double(k) * Double.pi
            k += 1
            if theta > thetaMax + Double.pi { break }
            guard theta >= -1e-9, theta <= thetaMax + 1e-9 else { continue }
            let r = curve.function(theta)
            guard r.isFinite else { continue }
            let p = Coordinates.polar(r: r, theta: theta)
            let screen = camera.screenPoint(x: p.x, y: p.y, size: size)
            let distance = Double(hypot(screen.x - pointer.x, screen.y - pointer.y))
            guard distance < 40 else { continue }
            if best == nil || distance < best!.distance {
                let info = HoverInfo(x: p.x, y: p.y, imaginary: nil, screen: screen, color: curve.color,
                                     name: curve.name, step: step, distance: distance, polar: (r, theta))
                best = (info, distance)
            }
        }
        return best
    }
}

struct HoverInfo {
    let x: Double
    /// The value, or the real part of a complex value.
    let y: Double
    /// The imaginary part of a complex value.
    let imaginary: Double?
    let screen: CGPoint
    let color: Color
    let name: String
    /// Precision for the labels.
    let step: Double
    /// Distance from the pointer in points, used to pick the nearest curve.
    var distance: Double = 0
    /// (r, θ) for a polar curve.
    var polar: (r: Double, theta: Double)?
}

private struct HoverLabel: View {
    let info: HoverInfo

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(info.color).frame(width: 8, height: 8)
            Text(readout)
                .font(.callout.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }

    private var readout: String {
        if let polar = info.polar {
            return "r = " + NiceNumbers.label(polar.r, step: info.step)
                + "   θ = " + NiceNumbers.label(polar.theta * 180 / Double.pi, step: info.step * 10) + "°"
        }
        let x = "x = " + NiceNumbers.label(info.x, step: info.step)
        guard let im = info.imaginary else {
            return x + "   \(info.name) = " + NiceNumbers.label(info.y, step: info.step)
        }
        return x + "   Re \(info.name) = " + NiceNumbers.label(info.y, step: info.step)
            + "   Im \(info.name) = " + NiceNumbers.label(im, step: info.step)
    }
}

// MARK: - Rendering

struct Plot2DRenderer {
    let camera: Camera2D
    let size: CGSize
    /// One device pixel, in points.
    let pixel: CGFloat
    /// Polar curves are drawn for θ from 0 to this angle.
    var thetaMax: Double = 2 * Double.pi

    private var viewport: Viewport { camera.viewport(for: size) }

    private var majorStep: Double {
        NiceNumbers.step(span: viewport.width, targetCount: max(2, Double(size.width) / 110))
    }

    /// Snaps a coordinate to the centre of a device pixel so 1-pixel lines stay crisp.
    private func crisp(_ v: CGFloat) -> CGFloat {
        (floor(v / pixel) + 0.5) * pixel
    }

    func drawGrid(in context: inout GraphicsContext) {
        let vp = viewport
        let major = majorStep
        let minor = NiceNumbers.minorStep(for: major)

        var minorPath = Path()
        var majorPath = Path()
        for x in NiceNumbers.ticks(in: vp.xMin...vp.xMax, step: minor) {
            let sx = crisp(camera.screenPoint(x: x, y: 0, size: size).x)
            let isMajor = abs(x / major - (x / major).rounded()) < 1e-6
            if isMajor {
                majorPath.move(to: CGPoint(x: sx, y: 0))
                majorPath.addLine(to: CGPoint(x: sx, y: size.height))
            } else {
                minorPath.move(to: CGPoint(x: sx, y: 0))
                minorPath.addLine(to: CGPoint(x: sx, y: size.height))
            }
        }
        for y in NiceNumbers.ticks(in: vp.yMin...vp.yMax, step: minor) {
            let sy = crisp(camera.screenPoint(x: 0, y: y, size: size).y)
            let isMajor = abs(y / major - (y / major).rounded()) < 1e-6
            if isMajor {
                majorPath.move(to: CGPoint(x: 0, y: sy))
                majorPath.addLine(to: CGPoint(x: size.width, y: sy))
            } else {
                minorPath.move(to: CGPoint(x: 0, y: sy))
                minorPath.addLine(to: CGPoint(x: size.width, y: sy))
            }
        }
        context.stroke(minorPath, with: .color(Color.primary.opacity(0.06)), lineWidth: pixel)
        context.stroke(majorPath, with: .color(Color.primary.opacity(0.13)), lineWidth: pixel)

        // Axes.
        let origin = camera.screenPoint(x: 0, y: 0, size: size)
        var axes = Path()
        if origin.y >= 0 && origin.y <= size.height {
            let y = crisp(origin.y)
            axes.move(to: CGPoint(x: 0, y: y))
            axes.addLine(to: CGPoint(x: size.width, y: y))
        }
        if origin.x >= 0 && origin.x <= size.width {
            let x = crisp(origin.x)
            axes.move(to: CGPoint(x: x, y: 0))
            axes.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(axes, with: .color(Color.primary.opacity(0.55)), lineWidth: max(pixel, 1))

        drawLabels(in: &context, origin: origin, step: major)
    }

    /// Concentric circles at multiples of a nice radius and spokes every 15°, with
    /// the radius labelled along the x-axis and the angles at the rim.
    func drawPolarGrid(in context: inout GraphicsContext) {
        let vp = viewport
        let major = majorStep
        let origin = camera.screenPoint(x: 0, y: 0, size: size)
        let unit = 1 / camera.unitsPerPoint   // points per world unit

        // Distances from the origin to the nearest and farthest point of the view.
        let nearX = vp.xMin > 0 ? vp.xMin : (vp.xMax < 0 ? -vp.xMax : 0)
        let nearY = vp.yMin > 0 ? vp.yMin : (vp.yMax < 0 ? -vp.yMax : 0)
        let nearest = hypot(nearX, nearY)
        let farthest = hypot(max(abs(vp.xMin), abs(vp.xMax)), max(abs(vp.yMin), abs(vp.yMax)))

        let firstCircle = max(1, Int((nearest / major).rounded(.down)))
        let lastCircle = min(Int((farthest / major).rounded(.up)), firstCircle + 80)
        var circles = Path()
        if firstCircle <= lastCircle {
            for k in firstCircle...lastCircle {
                let radius = CGFloat(Double(k) * major * unit)
                circles.addEllipse(in: CGRect(x: origin.x - radius, y: origin.y - radius,
                                              width: 2 * radius, height: 2 * radius))
            }
        }
        // Minor circles halfway between the major ones.
        var minorCircles = Path()
        let minor = NiceNumbers.minorStep(for: major)
        let minorFirst = max(1, Int((nearest / minor).rounded(.down)))
        let minorLast = min(Int((farthest / minor).rounded(.up)), minorFirst + 200)
        if minorFirst <= minorLast {
            for k in minorFirst...minorLast where abs(Double(k) * minor / major - (Double(k) * minor / major).rounded()) > 1e-6 {
                let radius = CGFloat(Double(k) * minor * unit)
                minorCircles.addEllipse(in: CGRect(x: origin.x - radius, y: origin.y - radius,
                                                   width: 2 * radius, height: 2 * radius))
            }
        }

        var spokes = Path()
        var minorSpokes = Path()
        let reach = CGFloat(farthest * unit) + 2
        for i in 0..<24 {
            let angle = Double(i) * Double.pi / 12
            let end = CGPoint(x: origin.x + reach * CGFloat(cos(angle)), y: origin.y - reach * CGFloat(sin(angle)))
            if i % 2 == 0 {
                spokes.move(to: origin)
                spokes.addLine(to: end)
            } else {
                minorSpokes.move(to: origin)
                minorSpokes.addLine(to: end)
            }
        }
        context.stroke(minorCircles, with: .color(Color.primary.opacity(0.05)), lineWidth: pixel)
        context.stroke(minorSpokes, with: .color(Color.primary.opacity(0.05)), lineWidth: pixel)
        context.stroke(circles, with: .color(Color.primary.opacity(0.13)), lineWidth: pixel)
        context.stroke(spokes, with: .color(Color.primary.opacity(0.13)), lineWidth: pixel)

        // The x- and y-axes.
        var axes = Path()
        if origin.y >= 0 && origin.y <= size.height {
            axes.move(to: CGPoint(x: 0, y: crisp(origin.y)))
            axes.addLine(to: CGPoint(x: size.width, y: crisp(origin.y)))
        }
        if origin.x >= 0 && origin.x <= size.width {
            axes.move(to: CGPoint(x: crisp(origin.x), y: 0))
            axes.addLine(to: CGPoint(x: crisp(origin.x), y: size.height))
        }
        context.stroke(axes, with: .color(Color.primary.opacity(0.55)), lineWidth: max(pixel, 1))

        drawPolarLabels(in: &context, origin: origin, step: major, unit: unit)
    }

    private func drawPolarLabels(in context: inout GraphicsContext, origin: CGPoint, step: Double, unit: Double) {
        let font = Font.system(size: 11).monospacedDigit()
        guard origin.x > 0, origin.x < size.width, origin.y > 0, origin.y < size.height else { return }

        // Radii along the positive x-axis.
        let maxRadius = Double(size.width - origin.x) / unit
        if maxRadius >= step {
            for k in 1...min(Int(maxRadius / step), 60) {
                let r = Double(k) * step
                let text = Text(NiceNumbers.label(r, step: step)).font(font).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: origin.x + CGFloat(r * unit) - 3, y: origin.y + 4), anchor: .topTrailing)
            }
        }

        // Angles at the outermost circle that fits inside the view.
        let fit = Double(min(origin.x, size.width - origin.x, origin.y, size.height - origin.y)) - 22
        let rim = (fit / unit / step).rounded(.down) * step
        guard rim >= step else { return }
        let rimPoints = CGFloat(rim * unit) + 12
        for i in 1..<12 {
            let degrees = i * 30
            let angle = Double(degrees) * Double.pi / 180
            let at = CGPoint(x: origin.x + rimPoints * CGFloat(cos(angle)), y: origin.y - rimPoints * CGFloat(sin(angle)))
            let text = Text("\(degrees)°").font(font).foregroundStyle(.secondary)
            context.draw(text, at: at, anchor: .center)
        }
    }

    private func drawLabels(in context: inout GraphicsContext, origin: CGPoint, step: Double) {
        let vp = viewport
        let font = Font.system(size: 11).monospacedDigit()
        // Keep labels on screen when an axis scrolls out of view.
        let labelY = min(max(origin.y + 5, 5), size.height - 20)
        let labelX = min(max(origin.x - 6, 40), size.width - 6)
        let leftAligned = origin.x - 6 < 40

        for x in NiceNumbers.ticks(in: vp.xMin...vp.xMax, step: step) where abs(x) > step * 1e-6 {
            let sx = camera.screenPoint(x: x, y: 0, size: size).x
            guard sx > 16, sx < size.width - 16 else { continue }
            let text = Text(NiceNumbers.label(x, step: step)).font(font).foregroundStyle(.secondary)
            context.draw(text, at: CGPoint(x: sx, y: labelY), anchor: .top)
        }
        for y in NiceNumbers.ticks(in: vp.yMin...vp.yMax, step: step) where abs(y) > step * 1e-6 {
            let sy = camera.screenPoint(x: 0, y: y, size: size).y
            guard sy > 12, sy < size.height - 12 else { continue }
            let text = Text(NiceNumbers.label(y, step: step)).font(font).foregroundStyle(.secondary)
            if leftAligned {
                context.draw(text, at: CGPoint(x: 6, y: sy), anchor: .leading)
            } else {
                context.draw(text, at: CGPoint(x: labelX, y: sy), anchor: .trailing)
            }
        }
        if origin.x > 0, origin.x < size.width, origin.y > 0, origin.y < size.height {
            let zero = Text("0").font(font).foregroundStyle(.secondary)
            context.draw(zero, at: CGPoint(x: origin.x - 6, y: origin.y + 5), anchor: .topTrailing)
        }
    }

    func drawCurves(_ curves: [CurveInput], in context: inout GraphicsContext) {
        let vp = viewport
        let solid = StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
        let dashed = StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round, dash: [7, 6])
        for curve in curves {
            if curve.system == .polar {
                let polar = PolarSampler.sample(curve.function, thetaRange: 0...thetaMax, viewport: vp,
                                                pixelWidth: Double(size.width), pixelHeight: Double(size.height))
                context.stroke(path(polar), with: .color(curve.color), style: solid)
                continue
            }
            let real = CurveSampler.sample(curve.function, viewport: vp,
                                           pixelWidth: Double(size.width), pixelHeight: Double(size.height))
            context.stroke(path(real), with: .color(curve.color), style: solid)

            // The imaginary part of a complex value, dashed; left out where it is zero
            // throughout (e.g. |e^{ix}| written with a complex intermediate).
            guard let imaginary = curve.imaginary else { continue }
            let imag = CurveSampler.sample(imaginary, viewport: vp,
                                           pixelWidth: Double(size.width), pixelHeight: Double(size.height))
            let tiny = 1e-12 * max(1, vp.height)
            if imag.contains(where: { segment in segment.contains { abs($0.y) > tiny } }) {
                context.stroke(path(imag), with: .color(curve.color), style: dashed)
            }
        }
    }

    private func path(_ segments: [[SIMD2<Double>]]) -> Path {
        var path = Path()
        for segment in segments {
            guard let first = segment.first else { continue }
            path.move(to: camera.screenPoint(x: first.x, y: first.y, size: size))
            for p in segment.dropFirst() {
                path.addLine(to: camera.screenPoint(x: p.x, y: p.y, size: size))
            }
        }
        return path
    }

    func drawHover(_ info: HoverInfo, in context: inout GraphicsContext) {
        var guide = Path()
        if info.polar != nil {
            // A line from the origin to the point.
            guide.move(to: camera.screenPoint(x: 0, y: 0, size: size))
            guide.addLine(to: info.screen)
        } else {
            let x = crisp(info.screen.x)
            guide.move(to: CGPoint(x: x, y: 0))
            guide.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(guide, with: .color(Color.primary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        let dot = CGRect(x: info.screen.x - 5, y: info.screen.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(Plot2DView.background))
        context.fill(Path(ellipseIn: dot), with: .color(info.color))
    }
}
