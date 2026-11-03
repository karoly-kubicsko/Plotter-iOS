import AppKit
import SwiftUI

/// A curve ready to draw: its compiled function and colour.
struct CurveInput: Identifiable {
    let id: UUID
    let function: CompiledFunction
    let color: Color
    let name: String
}

/// The 2D graph: grid, axes, curves and a hover read-out.
struct Plot2DView: View {
    static let background = Color(nsColor: .textBackgroundColor)

    let document: PlotDocument
    @State private var hover: CGPoint?
    @State private var size: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let curves = document.visibleFunctions.compactMap { f -> CurveInput? in
            guard let compiled = f.compiled else { return nil }
            return CurveInput(id: f.id, function: compiled, color: f.color, name: f.displayName)
        }
        let camera = document.camera2D ?? Camera2D.standard(for: size)
        let hoverInfo = hover.flatMap { nearestPoint(to: $0, curves: curves, camera: camera) }
        let pixel = 1 / max(displayScale, 1)

        Canvas(opaque: false) { context, canvasSize in
            let renderer = Plot2DRenderer(camera: camera, size: canvasSize, pixel: pixel)
            renderer.drawGrid(in: &context)
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
                    .offset(x: hoverInfo.screen.x > size.width - 200 ? -96 : 96,
                            y: hoverInfo.screen.y < 60 ? 30 : -30)
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
        .accessibilityLabel("2D graph")
        .accessibilityValue(curves.map(\.name).joined(separator: ", "))
    }

    private func nearestPoint(to point: CGPoint, curves: [CurveInput], camera: Camera2D) -> HoverInfo? {
        let world = camera.worldPoint(point, size: size)
        var best: HoverInfo?
        for curve in curves {
            let y = curve.function(world.x)
            guard y.isFinite else { continue }
            let screen = camera.screenPoint(x: world.x, y: y, size: size)
            let distance = abs(screen.y - point.y)
            guard distance < 120, screen.y > -20, screen.y < size.height + 20 else { continue }
            if best == nil || distance < abs(best!.screen.y - point.y) {
                best = HoverInfo(x: world.x, y: y, screen: screen, color: curve.color, name: curve.name,
                                 step: NiceNumbers.step(span: camera.unitsPerPoint * 100, targetCount: 10))
            }
        }
        return best
    }
}

struct HoverInfo {
    let x: Double
    let y: Double
    let screen: CGPoint
    let color: Color
    let name: String
    /// Precision for the labels.
    let step: Double
}

private struct HoverLabel: View {
    let info: HoverInfo

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(info.color).frame(width: 8, height: 8)
            Text("x = \(NiceNumbers.label(info.x, step: info.step))   \(info.name) = \(NiceNumbers.label(info.y, step: info.step))")
                .font(.callout.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }
}

// MARK: - Rendering

struct Plot2DRenderer {
    let camera: Camera2D
    let size: CGSize
    /// One device pixel, in points.
    let pixel: CGFloat

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
        let style = StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
        for curve in curves {
            let segments = CurveSampler.sample(curve.function, viewport: vp,
                                               pixelWidth: Double(size.width), pixelHeight: Double(size.height))
            var path = Path()
            for segment in segments {
                guard let first = segment.first else { continue }
                path.move(to: camera.screenPoint(x: first.x, y: first.y, size: size))
                for p in segment.dropFirst() {
                    path.addLine(to: camera.screenPoint(x: p.x, y: p.y, size: size))
                }
            }
            context.stroke(path, with: .color(curve.color), style: style)
        }
    }

    func drawHover(_ info: HoverInfo, in context: inout GraphicsContext) {
        var guide = Path()
        let x = crisp(info.screen.x)
        guide.move(to: CGPoint(x: x, y: 0))
        guide.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(guide, with: .color(Color.primary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        let dot = CGRect(x: info.screen.x - 5, y: info.screen.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(Plot2DView.background))
        context.fill(Path(ellipseIn: dot), with: .color(info.color))
    }
}

// MARK: - Mouse and trackpad input

/// Transparent AppKit layer that turns mouse and trackpad events into pan, zoom
/// and hover callbacks: drag or two-finger scroll pans, pinch or the mouse wheel
/// (or ⌘-scroll) zooms around the pointer, double-click resets.
struct PlotInteractionView: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onZoom: (Double, CGPoint) -> Void
    var onHover: (CGPoint?) -> Void
    var onDoubleClick: () -> Void
    var onGestureEnd: () -> Void

    func makeNSView(context: Context) -> InteractionNSView {
        InteractionNSView()
    }

    func updateNSView(_ view: InteractionNSView, context: Context) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.onHover = onHover
        view.onDoubleClick = onDoubleClick
        view.onGestureEnd = onGestureEnd
    }
}

final class InteractionNSView: NSView {
    var onPan: (CGSize) -> Void = { _ in }
    var onZoom: (Double, CGPoint) -> Void = { _, _ in }
    var onHover: (CGPoint?) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onGestureEnd: () -> Void = {}
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        onHover(location(event))
    }

    override func mouseExited(with event: NSEvent) {
        onHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onDoubleClick() }
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.closedHand.set()
        onHover(nil)
        onPan(CGSize(width: event.deltaX, height: event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.arrow.set()
        onHover(location(event))
        onGestureEnd()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            onPan(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            onHover(nil)
        } else {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            onZoom(exp(Double(delta)), location(event))
        }
        if event.phase == .ended || event.momentumPhase == .ended { onGestureEnd() }
    }

    override func magnify(with event: NSEvent) {
        onZoom(1 + Double(event.magnification), location(event))
        if event.phase == .ended { onGestureEnd() }
    }
}
