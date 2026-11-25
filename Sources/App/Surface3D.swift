import Metal
import MetalKit
import SwiftUI
import simd

// The 3D graph's model and renderer: the surface input, the orbit camera, the Metal renderer
// (meshing, shaders, axis-label placement). The UIKit view around it is in Plot3DView.swift.

/// A surface ready to mesh. `revision` changes whenever the function changes.
struct SurfaceInput {
    let id: UUID
    let revision: Int
    let colorIndex: Int
    /// Cartesian: z(x, y). Spherical: the radius r(θ, φ).
    let function: CompiledFunction
    let system: CoordinateSystem
    /// For a level surface: the field F − G, whose zero set is drawn.
    var field: ScalarField?
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
        // The vertical field of view is fixed in a view that is wider than tall. In a tall one
        // (a phone held upright) the horizontal field of view is kept at that of a square view
        // instead, so the whole box fits across the width rather than being cropped at the sides.
        let square = 1 / tan(Float(0.6) / 2)
        let aspect = max(aspect, 0.01)
        let xs = aspect >= 1 ? square / aspect : square
        let ys = aspect >= 1 ? square : square * aspect
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
    /// A spherical surface is drawn true to scale: the box then spans ±halfWidth in z
    /// and, since the box is 1 : zLimit in height, ±halfWidth / zLimit in x and y.
    private var hasSpherical = false
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
    func update(surfaces: [SurfaceInput], settings newSettings: SurfaceSettings, trueScale: Bool) -> Bool {
        let spherical = trueScale || surfaces.contains { $0.system == .spherical || $0.system == .implicit }
        var changed = newSettings != settings || surfaces.map(\.id) != order || spherical != hasSpherical
        settings = newSettings
        hasSpherical = spherical
        order = surfaces.map(\.id)
        let ids = Set(order)
        for id in meshes.keys where !ids.contains(id) {
            meshes[id] = nil
        }
        for surface in surfaces {
            if let m = meshes[surface.id], m.revision == surface.revision, m.halfWidth == xyHalf,
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

    /// Half the extent of the box in x and y, in world units.
    private var xyHalf: Double {
        hasSpherical ? settings.halfWidth / Double(Self.zLimit) : settings.halfWidth
    }

    private func buildMesh(_ surface: SurfaceInput) -> Mesh? {
        if surface.system == .spherical { return buildSphericalMesh(surface) }
        if surface.system == .implicit { return buildLevelMesh(surface) }
        let w = xyHalf
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

    /// F(x, y, z) = G: the zero set of the field, by marching tetrahedra. Drawn true to scale, in
    /// the box x = X / xyHalf, y = Y / xyHalf and z = Z (scaled by the shader).
    private func buildLevelMesh(_ surface: SurfaceInput) -> Mesh? {
        guard let field = surface.field else { return nil }
        let half = settings.halfWidth
        let w = xyHalf
        // The grid is coarser than the surface grids: the cost grows with the cube of the size.
        let n = min(max(settings.resolution / 3, 24), 80)
        let grid = FieldGrid.sample(field, half: half, n: n)
        let iso = IsoSurface.extract(grid)

        var vertices: [SurfaceVertex] = []
        vertices.reserveCapacity(iso.positions.count)
        let inverse = Float(1 / w)
        for (p, g) in zip(iso.positions, iso.gradients) {
            // The shader divides the normal's z by the z scale, so x and y are scaled here.
            let normal = simd_length(g) > 1e-12 ? SIMD3(g.x * Float(w), g.y * Float(w), g.z) : SIMD3<Float>(0, 0, 1)
            vertices.append(SurfaceVertex(position: SIMD4(p.x * inverse, p.y * inverse, p.z, 1),
                                          normal: SIMD4(normal, 0)))
        }
        let indices = (0..<UInt32(vertices.count)).map { $0 }
        // An empty surface (a level outside the field's range) is kept as an empty mesh, so it
        // is not sampled again on every redraw.
        if vertices.isEmpty { vertices.append(SurfaceVertex(position: .zero, normal: .zero)) }
        guard let vertexBuffer = makeBuffer(vertices) else { return nil }
        return Mesh(revision: surface.revision, halfWidth: w, resolution: settings.resolution,
                    colorIndex: surface.colorIndex, zRange: -half...half, vertices: vertexBuffer,
                    indices: makeBuffer(indices), indexCount: indices.count, lines: nil, lineCount: 0)
    }

    /// r = f(θ, φ): a grid over θ ∈ [0, π] (index i) and φ ∈ [0, 2π] (index j), placed in
    /// the box as x = X / xyHalf, y = Y / xyHalf and z = Z (scaled by the shader).
    private func buildSphericalMesh(_ surface: SurfaceInput) -> Mesh? {
        let n = min(max(settings.resolution, 10), 400)
        let w = xyHalf
        let radius = settings.halfWidth
        let inverse = 1 / w

        var points = [SIMD3<Float>?](repeating: nil, count: n * n)
        for j in 0..<n {
            let phi = 2 * Double.pi * Double(j) / Double(n - 1)
            for i in 0..<n {
                let theta = Double.pi * Double(i) / Double(n - 1)
                let r = surface.function(theta, phi)
                guard r.isFinite, Swift.abs(r) < 1e30 else { continue }
                let p = Coordinates.spherical(r: r, theta: theta, phi: phi)
                // Points outside the box are left out (the shader clips z itself).
                guard Swift.abs(p.x) <= w, Swift.abs(p.y) <= w else { continue }
                points[j * n + i] = SIMD3(Float(p.x * inverse), Float(p.y * inverse), Float(p.z))
            }
        }

        func point(_ i: Int, _ j: Int) -> SIMD3<Float>? {
            guard i >= 0, i < n else { return nil }
            // φ is periodic: the last column repeats the first.
            let jj = j < 0 ? n - 2 : (j > n - 1 ? 1 : j)
            return points[jj * n + i]
        }

        /// Normal from the tangents along θ and φ, in the box's x, y and unscaled z.
        func normal(_ i: Int, _ j: Int) -> SIMD3<Float> {
            func tangent(_ i: Int, _ j: Int, _ di: Int, _ dj: Int) -> SIMD3<Float>? {
                guard let c = point(i, j) else { return nil }
                let lo = point(i - di, j - dj), hi = point(i + di, j + dj)
                switch (lo, hi) {
                case let (l?, h?): return h - l
                case let (l?, nil): return c - l
                case let (nil, h?): return h - c
                default: return nil
                }
            }
            // At the poles every φ gives the same point; look one ring further in.
            for ii in [i, i == 0 ? 1 : (i == n - 1 ? n - 2 : i)] {
                if let a = tangent(ii, j, 1, 0), let b = tangent(ii, j, 0, 1) {
                    let c = simd_cross(a, b)
                    if simd_length(c) > 1e-12 { return c }
                }
            }
            return SIMD3(0, 0, 1)
        }

        var vertices = [SurfaceVertex](repeating: SurfaceVertex(position: .zero, normal: .zero), count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                guard let p = points[j * n + i] else {
                    vertices[j * n + i] = SurfaceVertex(position: SIMD4(0, 0, 0, 0), normal: SIMD4(0, 0, 1, 0))
                    continue
                }
                vertices[j * n + i] = SurfaceVertex(position: SIMD4(p, 1), normal: SIMD4(normal(i, j), 0))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((n - 1) * (n - 1) * 6)
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = j * n + i, b = a + 1, c = a + n, e = c + 1
                let va = points[a] != nil, vb = points[b] != nil, vc = points[c] != nil, ve = points[e] != nil
                if va && vb && ve { indices += [UInt32(a), UInt32(b), UInt32(e)] }
                if va && ve && vc { indices += [UInt32(a), UInt32(e), UInt32(c)] }
                if !ve && va && vb && vc { indices += [UInt32(a), UInt32(b), UInt32(c)] }
                if !va && vb && ve && vc { indices += [UInt32(b), UInt32(e), UInt32(c)] }
            }
        }

        // Mesh lines: about 24 meridians and 24 parallels.
        var lines: [SIMD4<Float>] = []
        let skip = max(1, (n - 1) / 24)
        for j in Swift.stride(from: 0, to: n, by: skip) {
            for i in 0..<(n - 1) {
                if let p = points[j * n + i], let q = points[j * n + i + 1] {
                    lines.append(SIMD4(p, 1))
                    lines.append(SIMD4(q, 1))
                }
            }
        }
        for i in Swift.stride(from: 0, to: n, by: skip) {
            for j in 0..<(n - 1) {
                if let p = points[j * n + i], let q = points[(j + 1) * n + i] {
                    lines.append(SIMD4(p, 1))
                    lines.append(SIMD4(q, 1))
                }
            }
        }

        guard let vertexBuffer = makeBuffer(vertices) else { return nil }
        return Mesh(revision: surface.revision, halfWidth: w, resolution: settings.resolution,
                    colorIndex: surface.colorIndex, zRange: -radius...radius, vertices: vertexBuffer,
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
        NiceNumbers.step(span: 2 * xyHalf, targetCount: 5)
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
        let w = xyHalf
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
        let w = xyHalf
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
