import MetalKit
import SwiftUI
import UIKit
import simd

// The UIKit view of the 3D graph. The renderer, camera and shaders are in Surface3D.swift.

/// The 3D graph: surfaces z = f(x, y) or r = f(θ, φ) rendered with Metal inside a labelled box.
/// One finger rotates (with inertia), pinching zooms, a double tap returns to the standard view.
struct Plot3DView: UIViewRepresentable {
    let surfaces: [SurfaceInput]
    let settings: SurfaceSettings
    /// Spherical coordinates: the box is drawn true to scale, as for any r = f(θ, φ) surface.
    var trueScale = false
    let resetToken: Int
    let zoomRequest: ZoomRequest

    func makeUIView(context: Context) -> SurfaceContainerUIView {
        SurfaceContainerUIView(frame: .zero)
    }

    func updateUIView(_ view: SurfaceContainerUIView, context: Context) {
        view.update(surfaces: surfaces, settings: settings, trueScale: trueScale)
        view.reset(token: resetToken)
        view.zoom(zoomRequest)
    }
}

// MARK: - Container

final class SurfaceContainerUIView: UIView {
    private let metalView: SurfaceUIMTKView?
    private let labelsView = AxisLabelsUIView()
    private var lastResetToken: Int?
    private var lastZoomToken: Int?

    override init(frame: CGRect) {
        var view: SurfaceUIMTKView?
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                let renderer = try SurfaceRenderer(device: device)
                view = SurfaceUIMTKView(renderer: renderer)
            } catch {
                FileHandle.standardError.write(Data("Plotter: cannot create the Metal renderer: \(error)\n".utf8))
            }
        }
        metalView = view
        super.init(frame: frame)

        if let metalView {
            metalView.frame = bounds
            metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(metalView)
            labelsView.frame = bounds
            labelsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(labelsView)
            metalView.onLabels = { [weak labelsView] labels in
                labelsView?.labels = labels
            }
        } else {
            let label = UILabel()
            label.text = "3D graphs need Metal, which is not available here."
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            ])
        }
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = "3D graph. Drag to rotate, pinch to zoom, double-tap to reset."
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
        metalView?.setNeedsDisplay()
    }
}

// MARK: - Metal view

final class SurfaceUIMTKView: MTKView, UIGestureRecognizerDelegate {
    private let renderer: SurfaceRenderer
    private var camera = OrbitCamera.standard
    var onLabels: ([AxisLabel]) -> Void = { _ in }

    // Inertia after a drag, in radians per second.
    private var velocity = SIMD2<Float>(0, 0)
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
        isOpaque = false
        backgroundColor = .clear
        preferredFramesPerSecond = 120
        isPaused = true
        enableSetNeedsDisplay = true
        isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        for recognizer in [pan, pinch, doubleTap] { addGestureRecognizer(recognizer) }

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SurfaceUIMTKView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func update(surfaces: [SurfaceInput], settings: SurfaceSettings, trueScale: Bool) {
        if renderer.update(surfaces: surfaces, settings: settings, trueScale: trueScale) {
            setNeedsDisplay()
        }
    }

    func resetCamera() {
        velocity = .zero
        resetFrom = camera
        resetStart = CACurrentMediaTime()
        startAnimating()
    }

    func zoom(by factor: Float) {
        guard factor.isFinite, factor > 0 else { return }
        camera.distance = min(max(camera.distance / factor, 2.2), 14)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
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

    override func draw(_ rect: CGRect) {
        step()
        let dark = traitCollection.userInterfaceStyle == .dark
        let size = drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let viewProjection = camera.viewProjection(aspect: aspect)
        renderer.render(in: self, viewProjection: viewProjection, eye: camera.eye, dark: dark)
        onLabels(renderer.labels(viewProjection: viewProjection, eye: camera.eye, viewSize: bounds.size))
    }

    // MARK: Touch input

    private func rotate(by delta: SIMD2<Float>) {
        camera.azimuth -= delta.x
        camera.elevation = min(max(camera.elevation + delta.y, -1.52), 1.52)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            velocity = .zero
            resetFrom = nil
        case .changed:
            let t = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            rotate(by: SIMD2(Float(t.x), Float(t.y)) * 0.008)
            setNeedsDisplay()
        case .ended:
            let v = recognizer.velocity(in: self)
            velocity = SIMD2(Float(v.x), Float(v.y)) * 0.008
            if simd_length(velocity) > 0.3 { startAnimating() } else { velocity = .zero }
        case .cancelled, .failed:
            velocity = .zero
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            velocity = .zero
            resetFrom = nil
        case .changed:
            zoom(by: Float(recognizer.scale))
            recognizer.scale = 1
            setNeedsDisplay()
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        resetCamera()
    }
}

// MARK: - Axis labels

/// Draws the 3D axis labels as crisp text over the Metal view.
final class AxisLabelsUIView: UIView {
    var labels: [AxisLabel] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ rect: CGRect) {
        let tick: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let title: [NSAttributedString.Key: Any] = [
            .font: UIFont(name: "STIXTwoText-Italic", size: 17) ?? UIFont.systemFont(ofSize: 15),
            .foregroundColor: UIColor.label,
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
