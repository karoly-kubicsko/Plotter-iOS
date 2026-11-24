import AppKit
import Metal
import MetalKit
import SwiftUI
import simd

// The macOS (AppKit) view of the 3D graph; the renderer is in Surface3D.swift.

/// The 3D graph: surfaces z = f(x, y) or r = f(θ, φ) rendered with Metal inside a labelled box.
struct Plot3DView: NSViewRepresentable {
    let surfaces: [SurfaceInput]
    let settings: SurfaceSettings
    /// Spherical coordinates: the box is drawn true to scale, as for any r = f(θ, φ) surface.
    var trueScale = false
    let resetToken: Int
    let zoomRequest: ZoomRequest

    func makeNSView(context: Context) -> SurfaceContainerView {
        SurfaceContainerView(frame: .zero)
    }

    func updateNSView(_ view: SurfaceContainerView, context: Context) {
        view.update(surfaces: surfaces, settings: settings, trueScale: trueScale)
        view.reset(token: resetToken)
        view.zoom(zoomRequest)
    }
}

// MARK: - Container

final class SurfaceContainerView: NSView {
    private let metalView: SurfaceMTKView?
    private let labelsView = AxisLabelsView()
    private var lastResetToken: Int?
    private var lastZoomToken: Int?

    override init(frame frameRect: NSRect) {
        var view: SurfaceMTKView?
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                let renderer = try SurfaceRenderer(device: device)
                view = SurfaceMTKView(renderer: renderer)
            } catch {
                FileHandle.standardError.write(Data("Plotter: cannot create the Metal renderer: \(error)\n".utf8))
            }
        }
        metalView = view
        super.init(frame: frameRect)

        if let metalView {
            metalView.autoresizingMask = [.width, .height]
            addSubview(metalView)
            labelsView.autoresizingMask = [.width, .height]
            addSubview(labelsView)
            metalView.onLabels = { [weak labelsView] labels in
                labelsView?.labels = labels
            }
        } else {
            let label = NSTextField(labelWithString: "3D graphs need Metal, which is not available on this Mac.")
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("3D graph. Drag to rotate, pinch to zoom, double-click to reset.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(surfaces: [SurfaceInput], settings: SurfaceSettings, trueScale: Bool) {
        metalView?.update(surfaces: surfaces, settings: settings, trueScale: trueScale)
    }

    func reset(token: Int) {
        defer { lastResetToken = token }
        guard let lastResetToken, lastResetToken != token else { return }
        metalView?.resetCamera()
    }

    func zoom(_ request: ZoomRequest) {
        defer { lastZoomToken = request.token }
        guard let lastZoomToken, lastZoomToken != request.token else { return }
        metalView?.zoom(by: Float(request.factor))
        metalView?.needsDisplay = true
    }
}

// MARK: - Metal view

final class SurfaceMTKView: MTKView {
    private let renderer: SurfaceRenderer
    private var camera = OrbitCamera.standard
    var onLabels: ([AxisLabel]) -> Void = { _ in }

    // Inertia after a drag, in radians per second.
    private var velocity = SIMD2<Float>(0, 0)
    private var lastDragTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    // Animated return to the standard view.
    private var resetFrom: OrbitCamera?
    private var resetStart: CFTimeInterval = 0

    init(renderer: SurfaceRenderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        sampleCount = SurfaceRenderer.sampleCount
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        preferredFramesPerSecond = 120
        isPaused = true
        enableSetNeedsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(surfaces: [SurfaceInput], settings: SurfaceSettings, trueScale: Bool) {
        if renderer.update(surfaces: surfaces, settings: settings, trueScale: trueScale) {
            needsDisplay = true
        }
    }

    func resetCamera() {
        velocity = .zero
        resetFrom = camera
        resetStart = CACurrentMediaTime()
        startAnimating()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: Drawing and animation

    private func startAnimating() {
        lastFrameTime = CACurrentMediaTime()
        enableSetNeedsDisplay = false
        isPaused = false
    }

    private func stopAnimating() {
        isPaused = true
        enableSetNeedsDisplay = true
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 0), 0.05))
        lastFrameTime = now
        var animating = false

        if let from = resetFrom {
            let t = Float(min((now - resetStart) / 0.45, 1))
            let eased = 1 - pow(1 - t, 3)
            var target = OrbitCamera.standard
            // Take the short way round.
            let twoPi = Float.pi * 2
            target.azimuth = from.azimuth + (OrbitCamera.standard.azimuth - from.azimuth).remainder(dividingBy: twoPi)
            camera = OrbitCamera.interpolate(from, target, eased)
            if t >= 1 { resetFrom = nil } else { animating = true }
        } else if simd_length(velocity) > 0.02 {
            rotate(by: velocity * dt)
            velocity *= exp(-4.5 * dt)
            animating = true
        } else {
            velocity = .zero
        }
        if !animating && !isPaused { stopAnimating() }
    }

    override func draw(_ dirtyRect: NSRect) {
        step()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let size = drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let viewProjection = camera.viewProjection(aspect: aspect)
        renderer.render(in: self, viewProjection: viewProjection, eye: camera.eye, dark: dark)
        onLabels(renderer.labels(viewProjection: viewProjection, eye: camera.eye, viewSize: bounds.size))
    }

    // MARK: Input

    private func rotate(by delta: SIMD2<Float>) {
        camera.azimuth -= delta.x
        camera.elevation = min(max(camera.elevation + delta.y, -1.52), 1.52)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        velocity = .zero
        resetFrom = nil
        if event.clickCount == 2 { resetCamera() }
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = SIMD2<Float>(Float(event.deltaX), Float(event.deltaY)) * 0.008
        rotate(by: delta)
        let now = CACurrentMediaTime()
        let dt = Float(max(now - lastDragTime, 1.0 / 120))
        velocity = velocity * 0.4 + (delta / dt) * 0.6
        lastDragTime = now
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if CACurrentMediaTime() - lastDragTime < 0.06, simd_length(velocity) > 0.3 {
            startAnimating()
        } else {
            velocity = .zero
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // Two-finger scroll rotates; the system's momentum events supply inertia.
            rotate(by: SIMD2<Float>(Float(-event.scrollingDeltaX), Float(-event.scrollingDeltaY)) * 0.006)
        } else {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            zoom(by: exp(Float(delta)))
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + Float(event.magnification))
        needsDisplay = true
    }

    func zoom(by factor: Float) {
        guard factor.isFinite, factor > 0 else { return }
        camera.distance = min(max(camera.distance / factor, 2.2), 14)
    }
}

// MARK: - Axis labels

/// Draws the 3D axis labels as crisp AppKit text over the Metal view.
final class AxisLabelsView: NSView {
    var labels: [AxisLabel] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let tick: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let title: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "STIXTwoText-Italic", size: 17) ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
        ]
        for label in labels {
            let string = NSAttributedString(string: label.text, attributes: label.isTitle ? title : tick)
            let size = string.size()
            let origin = CGPoint(x: label.point.x - size.width * label.anchor.x,
                                 y: label.point.y - size.height * label.anchor.y)
            string.draw(at: origin)
        }
    }
}
