import AppKit
import Metal
import MetalKit
import SwiftUI
import simd

/// A surface ready to mesh. `revision` changes whenever the function changes.
struct SurfaceInput {
    let id: UUID
    let revision: Int
    let colorIndex: Int
    let function: CompiledFunction
}

/// The 3D graph: surfaces z = f(x, y) rendered with Metal inside a labelled box.
struct Plot3DView: NSViewRepresentable {
    let surfaces: [SurfaceInput]
    let settings: SurfaceSettings
    let resetToken: Int
    let zoomRequest: ZoomRequest

    func makeNSView(context: Context) -> SurfaceContainerView {
        SurfaceContainerView(frame: .zero)
    }

    func updateNSView(_ view: SurfaceContainerView, context: Context) {
        view.update(surfaces: surfaces, settings: settings)
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

    func update(surfaces: [SurfaceInput], settings: SurfaceSettings) {
        metalView?.update(surfaces: surfaces, settings: settings)
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

// MARK: - Camera

struct OrbitCamera: Equatable {
    var azimuth: Float = -1.05
    var elevation: Float = 0.52
    var distance: Float = 5.2

    static let standard = OrbitCamera()

    var eye: SIMD3<Float> {
        SIMD3(distance * cos(elevation) * cos(azimuth),
              distance * cos(elevation) * sin(azimuth),
              distance * sin(elevation))
    }

    func viewProjection(aspect: Float) -> simd_float4x4 {
        projection(aspect: aspect) * view()
    }

    private func view() -> simd_float4x4 {
        let eye = self.eye
        let f = simd_normalize(-eye)
        let s = simd_normalize(simd_cross(f, SIMD3<Float>(0, 0, 1)))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    private func projection(aspect: Float) -> simd_float4x4 {
        let near: Float = 0.1, far: Float = 100
        let ys = 1 / tan(Float(0.6) / 2)
        let xs = ys / max(aspect, 0.01)
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * near, 0)))
    }

    static func interpolate(_ a: OrbitCamera, _ b: OrbitCamera, _ t: Float) -> OrbitCamera {
        OrbitCamera(azimuth: a.azimuth + (b.azimuth - a.azimuth) * t,
                    elevation: a.elevation + (b.elevation - a.elevation) * t,
                    distance: a.distance + (b.distance - a.distance) * t)
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

    func update(surfaces: [SurfaceInput], settings: SurfaceSettings) {
        if renderer.update(surfaces: surfaces, settings: settings) {
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

// MARK: - Renderer

private struct SurfaceVertex {
    var position: SIMD4<Float>   // x, y in box units; z raw; w = 1
    var normal: SIMD4<Float>     // normal of (x, y, z raw)
}

/// Shared by Swift and the shaders; the layout matches `Uniforms` in the shader source.
private struct Uniforms {
    var viewProjection: simd_float4x4
    var eye: SIMD4<Float>
    var color: SIMD4<Float>
    var zMid: Float
    var zScale: Float
    var zLimit: Float
    var tLow: Float
    var tInvRange: Float
    var colorMode: Int32
    var depthBias: Float
    var padding: Float = 0
}

private struct Mesh {
    let revision: Int
    let halfWidth: Double
    let resolution: Int
    let colorIndex: Int
    let zRange: ClosedRange<Double>
    let vertices: MTLBuffer
    let indices: MTLBuffer?
    let indexCount: Int
    let lines: MTLBuffer?
    let lineCount: Int
}

struct AxisLabel {
    let text: String
    /// Position in view coordinates (y down).
    let point: CGPoint
    /// Which point of the text sits at `point`: (0, 0) top left … (1, 1) bottom right.
    let anchor: CGPoint
    let isTitle: Bool
}

@MainActor
final class SurfaceRenderer {
    static let sampleCount = 4
    /// The box spans [−1, 1] in x and y and [−zLimit, zLimit] in z.
    static let zLimit: Float = 0.72

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let surfacePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let surfaceDepth: MTLDepthStencilState
    private let lineDepth: MTLDepthStencilState

    private var meshes: [UUID: Mesh] = [:]
    private var order: [UUID] = []
    private var settings = SurfaceSettings()
    private var zRange: ClosedRange<Double> = -1...1
    private var frame: MTLBuffer?
    private var frameCount = 0
    private var frameKey: [Double] = []

    enum RendererError: Error {
        case noCommandQueue, noFunctions, noDepthState
    }

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        self.queue = queue

        let library = try device.makeLibrary(source: shaderSource, options: nil)
        guard let surfaceVertex = library.makeFunction(name: "surface_vertex"),
              let surfaceFragment = library.makeFunction(name: "surface_fragment"),
              let lineVertex = library.makeFunction(name: "line_vertex"),
              let lineFragment = library.makeFunction(name: "line_fragment") else {
            throw RendererError.noFunctions
        }

        func pipeline(_ vertex: MTLFunction, _ fragment: MTLFunction) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vertex
            d.fragmentFunction = fragment
            d.rasterSampleCount = Self.sampleCount
            d.depthAttachmentPixelFormat = .depth32Float
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .sourceAlpha
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        surfacePipeline = try pipeline(surfaceVertex, surfaceFragment)
        linePipeline = try pipeline(lineVertex, lineFragment)

        let surfaceDepthDescriptor = MTLDepthStencilDescriptor()
        surfaceDepthDescriptor.depthCompareFunction = .less
        surfaceDepthDescriptor.isDepthWriteEnabled = true
        let lineDepthDescriptor = MTLDepthStencilDescriptor()
        lineDepthDescriptor.depthCompareFunction = .lessEqual
        lineDepthDescriptor.isDepthWriteEnabled = false
        guard let s = device.makeDepthStencilState(descriptor: surfaceDepthDescriptor),
              let l = device.makeDepthStencilState(descriptor: lineDepthDescriptor) else {
            throw RendererError.noDepthState
        }
        surfaceDepth = s
        lineDepth = l
    }

    /// Re-meshes changed surfaces. Returns true if anything changed.
    func update(surfaces: [SurfaceInput], settings newSettings: SurfaceSettings) -> Bool {
        var changed = newSettings != settings || surfaces.map(\.id) != order
        settings = newSettings
        order = surfaces.map(\.id)
        let ids = Set(order)
        for id in meshes.keys where !ids.contains(id) {
            meshes[id] = nil
        }
        for surface in surfaces {
            if let m = meshes[surface.id], m.revision == surface.revision, m.halfWidth == settings.halfWidth,
               m.resolution == settings.resolution {
                if m.colorIndex != surface.colorIndex {
                    meshes[surface.id] = Mesh(revision: m.revision, halfWidth: m.halfWidth, resolution: m.resolution,
                                              colorIndex: surface.colorIndex, zRange: m.zRange, vertices: m.vertices,
                                              indices: m.indices, indexCount: m.indexCount, lines: m.lines,
                                              lineCount: m.lineCount)
                    changed = true
                }
                continue
            }
            meshes[surface.id] = buildMesh(surface)
            changed = true
        }
        if changed {
            let ranges = order.compactMap { meshes[$0]?.zRange }
            if let lo = ranges.map(\.lowerBound).min(), let hi = ranges.map(\.upperBound).max() {
                zRange = lo...hi
            } else {
                zRange = -1...1
            }
            buildFrame()
        }
        return changed
    }

    private func buildMesh(_ surface: SurfaceInput) -> Mesh? {
        let w = settings.halfWidth
        let n = min(max(settings.resolution, 10), 400)
        let grid = SurfaceGrid.sample(surface.function, xRange: -w...w, yRange: -w...w, resolution: n)
        let values = grid.values
        let d = 2 / Float(n - 1)

        func z(_ i: Int, _ j: Int) -> Float? {
            guard i >= 0, i < n, j >= 0, j < n else { return nil }
            let v = values[j * n + i]
            return v.isNaN ? nil : v
        }

        var vertices = [SurfaceVertex](repeating: SurfaceVertex(position: .zero, normal: .zero), count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let x = -1 + Float(i) * d
                let y = -1 + Float(j) * d
                guard let zc = z(i, j) else {
                    vertices[j * n + i] = SurfaceVertex(position: SIMD4(x, y, 0, 0), normal: SIMD4(0, 0, 1, 0))
                    continue
                }
                func slope(_ lo: Float?, _ hi: Float?) -> Float {
                    switch (lo, hi) {
                    case let (l?, h?): return (h - l) / (2 * d)
                    case let (l?, nil): return (zc - l) / d
                    case let (nil, h?): return (h - zc) / d
                    default: return 0
                    }
                }
                let zx = slope(z(i - 1, j), z(i + 1, j))
                let zy = slope(z(i, j - 1), z(i, j + 1))
                vertices[j * n + i] = SurfaceVertex(position: SIMD4(x, y, zc, 1), normal: SIMD4(-zx, -zy, 1, 0))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((n - 1) * (n - 1) * 6)
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = j * n + i, b = a + 1, c = a + n, e = c + 1
                let va = z(i, j) != nil, vb = z(i + 1, j) != nil, vc = z(i, j + 1) != nil, ve = z(i + 1, j + 1) != nil
                if va && vb && ve { indices += [UInt32(a), UInt32(b), UInt32(e)] }
                if va && ve && vc { indices += [UInt32(a), UInt32(e), UInt32(c)] }
                if !ve && va && vb && vc { indices += [UInt32(a), UInt32(b), UInt32(c)] }
                if !va && vb && ve && vc { indices += [UInt32(b), UInt32(e), UInt32(c)] }
            }
        }

        // Mesh lines along about 24 grid rows and columns.
        var lines: [SIMD4<Float>] = []
        let stride = max(1, (n - 1) / 24)
        for j in Swift.stride(from: 0, to: n, by: stride) {
            for i in 0..<(n - 1) {
                if let z0 = z(i, j), let z1 = z(i + 1, j) {
                    lines.append(SIMD4(-1 + Float(i) * d, -1 + Float(j) * d, z0, 1))
                    lines.append(SIMD4(-1 + Float(i + 1) * d, -1 + Float(j) * d, z1, 1))
                }
            }
        }
        for i in Swift.stride(from: 0, to: n, by: stride) {
            for j in 0..<(n - 1) {
                if let z0 = z(i, j), let z1 = z(i, j + 1) {
                    lines.append(SIMD4(-1 + Float(i) * d, -1 + Float(j) * d, z0, 1))
                    lines.append(SIMD4(-1 + Float(i) * d, -1 + Float(j + 1) * d, z1, 1))
                }
            }
        }

        guard let vertexBuffer = makeBuffer(vertices) else { return nil }
        return Mesh(revision: surface.revision, halfWidth: w, resolution: settings.resolution,
                    colorIndex: surface.colorIndex, zRange: grid.zRange, vertices: vertexBuffer,
                    indices: makeBuffer(indices), indexCount: indices.count,
                    lines: makeBuffer(lines), lineCount: lines.count)
    }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
    }

    // MARK: Box, floor grid and labels

    private var xyStep: Double {
        NiceNumbers.step(span: 2 * settings.halfWidth, targetCount: 5)
    }

    private var zStep: Double {
        NiceNumbers.step(span: zRange.upperBound - zRange.lowerBound, targetCount: 4)
    }

    private func boxZ(_ z: Double) -> Float {
        let mid = (zRange.lowerBound + zRange.upperBound) / 2
        let scale = 2 * Double(Self.zLimit) / max(zRange.upperBound - zRange.lowerBound, 1e-12)
        return Float((z - mid) * scale)
    }

    private func buildFrame() {
        let h = Self.zLimit
        var points: [SIMD4<Float>] = []
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, alpha: Float) {
            points.append(SIMD4(a, alpha))
            points.append(SIMD4(b, alpha))
        }
        // Box edges.
        let corners: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
        for k in 0..<4 {
            let p = corners[k], q = corners[(k + 1) % 4]
            line(SIMD3(p, -h), SIMD3(q, -h), alpha: 0.9)
            line(SIMD3(p, h), SIMD3(q, h), alpha: 0.35)
            line(SIMD3(p, -h), SIMD3(p, h), alpha: 0.5)
        }
        // Floor grid.
        let w = settings.halfWidth
        for v in NiceNumbers.ticks(in: -w...w, step: xyStep) where abs(abs(v) - w) > 1e-9 {
            let b = Float(v / w)
            line(SIMD3(b, -1, -h), SIMD3(b, 1, -h), alpha: 0.45)
            line(SIMD3(-1, b, -h), SIMD3(1, b, -h), alpha: 0.45)
        }
        frame = makeBuffer(points)
        frameCount = points.count
    }

    func labels(viewProjection: simd_float4x4, eye: SIMD3<Float>, viewSize: CGSize) -> [AxisLabel] {
        let h = Self.zLimit
        let w = settings.halfWidth
        func project(_ p: SIMD3<Float>) -> CGPoint? {
            let clip = viewProjection * SIMD4(p, 1)
            guard clip.w > 0.01 else { return nil }
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            return CGPoint(x: CGFloat(ndc.x + 1) / 2 * viewSize.width, y: CGFloat(1 - ndc.y) / 2 * viewSize.height)
        }
        func anchor(for p: CGPoint, from center: CGPoint) -> CGPoint {
            // Place the text on the side facing away from the box centre.
            let dx = p.x - center.x, dy = p.y - center.y
            let len = max(hypot(dx, dy), 1)
            return CGPoint(x: 0.5 - 0.5 * dx / len, y: 0.5 - 0.5 * dy / len)
        }
        guard let center = project(SIMD3(0, 0, -h)) else { return [] }
        var result: [AxisLabel] = []

        // x labels on the floor edge nearer the viewer, y labels on the nearer side edge.
        let yEdge: Float = eye.y < 0 ? -1.12 : 1.12
        let xEdge: Float = eye.x < 0 ? -1.12 : 1.12
        let step = xyStep
        for v in NiceNumbers.ticks(in: -w...w, step: step) {
            let b = Float(v / w)
            if let p = project(SIMD3(b, yEdge, -h)) {
                result.append(AxisLabel(text: NiceNumbers.label(v, step: step), point: p,
                                        anchor: anchor(for: p, from: center), isTitle: false))
            }
            if let p = project(SIMD3(xEdge, b, -h)) {
                result.append(AxisLabel(text: NiceNumbers.label(v, step: step), point: p,
                                        anchor: anchor(for: p, from: center), isTitle: false))
            }
        }
        if let p = project(SIMD3(0, yEdge * 1.25, -h)) {
            result.append(AxisLabel(text: "x", point: p, anchor: anchor(for: p, from: center), isTitle: true))
        }
        if let p = project(SIMD3(xEdge * 1.25, 0, -h)) {
            result.append(AxisLabel(text: "y", point: p, anchor: anchor(for: p, from: center), isTitle: true))
        }

        // z labels on the vertical edge that appears leftmost.
        let candidates: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
        let corner = candidates.min { a, b in
            (project(SIMD3(a, 0))?.x ?? .infinity) < (project(SIMD3(b, 0))?.x ?? .infinity)
        } ?? SIMD2(-1, -1)
        let zs = zStep
        for v in NiceNumbers.ticks(in: zRange, step: zs) {
            if let p = project(SIMD3(corner * 1.04, boxZ(v))) {
                result.append(AxisLabel(text: NiceNumbers.label(v, step: zs), point: CGPoint(x: p.x - 6, y: p.y),
                                        anchor: CGPoint(x: 1, y: 0.5), isTitle: false))
            }
        }
        if let p = project(SIMD3(corner * 1.04, h + 0.12)) {
            result.append(AxisLabel(text: "z", point: p, anchor: CGPoint(x: 0.5, y: 1), isTitle: true))
        }
        return result
    }

    // MARK: Drawing

    func render(in view: MTKView, viewProjection: simd_float4x4, eye: SIMD3<Float>, dark: Bool) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let lo = zRange.lowerBound, hi = zRange.upperBound
        let span = max(hi - lo, 1e-12)
        var uniforms = Uniforms(
            viewProjection: viewProjection,
            eye: SIMD4(eye, 1),
            color: SIMD4(1, 1, 1, 1),
            zMid: Float((lo + hi) / 2),
            zScale: Float(2 * Double(Self.zLimit) / span),
            zLimit: Self.zLimit,
            tLow: Float(lo),
            tInvRange: Float(1 / span),
            colorMode: 0,
            depthBias: 0)

        encoder.setCullMode(.none)

        // Surfaces.
        encoder.setRenderPipelineState(surfacePipeline)
        encoder.setDepthStencilState(surfaceDepth)
        for id in order {
            guard let mesh = meshes[id], let indices = mesh.indices else { continue }
            switch settings.coloring {
            case .viridis: uniforms.colorMode = 0
            case .magma: uniforms.colorMode = 1
            case .function: uniforms.colorMode = 2
            }
            uniforms.color = CurvePalette.rgba(mesh.colorIndex, dark: dark)
            encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32,
                                          indexBuffer: indices, indexBufferOffset: 0)
        }

        // Mesh lines, lifted slightly towards the viewer to avoid z-fighting.
        encoder.setRenderPipelineState(linePipeline)
        encoder.setDepthStencilState(lineDepth)
        if settings.showsMesh {
            uniforms.color = dark ? SIMD4(1, 1, 1, 0.22) : SIMD4(0, 0, 0, 0.2)
            uniforms.depthBias = 0.0004
            for id in order {
                guard let mesh = meshes[id], let lines = mesh.lines else { continue }
                encoder.setVertexBuffer(lines, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: mesh.lineCount)
            }
        }

        // Box and floor grid (already in box coordinates).
        if let frame {
            uniforms.zMid = 0
            uniforms.zScale = 1
            uniforms.zLimit = 10
            uniforms.depthBias = 0
            uniforms.color = dark ? SIMD4(1, 1, 1, 0.4) : SIMD4(0, 0, 0, 0.35)
            encoder.setVertexBuffer(frame, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: frameCount)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
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

// MARK: - Shaders

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct SurfaceVertex {
    float4 position;
    float4 normal;
};

struct Uniforms {
    float4x4 viewProjection;
    float4 eye;
    float4 color;
    float zMid;
    float zScale;
    float zLimit;
    float tLow;
    float tInvRange;
    int colorMode;
    float depthBias;
    float padding;
};

struct SurfaceOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float t;
};

// Polynomial fits of matplotlib's viridis and magma colormaps (Matt Zucker, CC0).
static float3 viridis(float t) {
    const float3 c0 = float3(0.2777273272234177, 0.005407344544966578, 0.3340998053353061);
    const float3 c1 = float3(0.1050930431085774, 1.404613529898575, 1.384590162594685);
    const float3 c2 = float3(-0.3308618287255563, 0.214847559468213, 0.09509516302823659);
    const float3 c3 = float3(-4.634230498983486, -5.799100973351585, -19.33244095627987);
    const float3 c4 = float3(6.228269936347081, 14.17993336680509, 56.69055260068105);
    const float3 c5 = float3(4.776384997670288, -13.74514537774601, -65.35303263337234);
    const float3 c6 = float3(-5.435455855934631, 4.645852612178535, 26.3124352495832);
    return c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6)))));
}

static float3 magma(float t) {
    const float3 c0 = float3(-0.002136485053939582, -0.000749655052795221, -0.005386127855323933);
    const float3 c1 = float3(0.2516605407371642, 0.6775232436837668, 2.494026599312351);
    const float3 c2 = float3(8.353717279216625, -3.577719514958484, 0.3144679030132573);
    const float3 c3 = float3(-27.66873308576866, 14.26473078096533, -13.64921318813922);
    const float3 c4 = float3(52.17613981234068, -27.94360607168351, 12.94416944238394);
    const float3 c5 = float3(-50.76852536473588, 29.04658282127291, 4.23415299384598);
    const float3 c6 = float3(18.65570506591883, -11.48977351997711, -5.601961508734096);
    return saturate(c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6))))));
}

vertex SurfaceOut surface_vertex(uint vid [[vertex_id]],
                                 const device SurfaceVertex *vertices [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
    SurfaceVertex v = vertices[vid];
    float z = clamp((v.position.z - u.zMid) * u.zScale, -8.0, 8.0);
    float3 p = float3(v.position.xy, z);
    SurfaceOut out;
    out.position = u.viewProjection * float4(p, 1.0);
    out.world = p;
    out.normal = float3(v.normal.xy, v.normal.z / max(u.zScale, 1e-6));
    out.t = saturate((v.position.z - u.tLow) * u.tInvRange);
    return out;
}

fragment float4 surface_fragment(SurfaceOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    if (abs(in.world.z) > u.zLimit) {
        discard_fragment();
    }
    float3 n = normalize(in.normal);
    float3 v = normalize(u.eye.xyz - in.world);
    if (dot(n, v) < 0.0) {
        n = -n;
    }
    float3 base = u.colorMode == 0 ? viridis(in.t) : (u.colorMode == 1 ? magma(in.t) : u.color.rgb);
    float3 key = normalize(v + float3(0.0, 0.0, 0.7));
    float3 fillDirection = normalize(float3(-0.5, 0.4, 0.8));
    float diffuse = max(dot(n, key), 0.0);
    float fill = max(dot(n, fillDirection), 0.0);
    float specular = pow(max(dot(n, normalize(key + v)), 0.0), 40.0) * 0.16;
    float3 color = base * (0.34 + 0.58 * diffuse + 0.16 * fill) + specular;
    return float4(color, 1.0);
}

struct LineOut {
    float4 position [[position]];
    float3 world;
    float alpha;
};

vertex LineOut line_vertex(uint vid [[vertex_id]],
                           const device float4 *points [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    float4 v = points[vid];
    float3 p = float3(v.xy, clamp((v.z - u.zMid) * u.zScale, -8.0, 8.0));
    LineOut out;
    out.position = u.viewProjection * float4(p, 1.0);
    out.position.z -= u.depthBias * out.position.w;
    out.world = p;
    out.alpha = v.w;
    return out;
}

fragment float4 line_fragment(LineOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    if (abs(in.world.z) > u.zLimit + 0.0001) {
        discard_fragment();
    }
    return float4(u.color.rgb, u.color.a * in.alpha);
}
"""
