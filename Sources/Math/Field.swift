import Foundation

// MARK: - Scalar fields

/// F(x, y, z) − G(x, y, z) from an equation F = G, with `r` replaced by √(x² + y² + z²).
/// The surface is where this is zero.
public struct ScalarField: Sendable {
    let expression: Expr
    let arguments: [Symbol]
    let parameters: [String: Double]

    /// The field in the plane at height `z`, as a function of x and y. (The compiler
    /// handles two variables, so z is passed as a parameter.)
    public func slice(z: Double) -> CompiledFunction {
        var values = parameters
        values[arguments[2].name] = z
        return CompiledFunction(expression, arguments: [arguments[0], arguments[1]], parameters: values)
    }
}

extension Equation {
    /// The field of a level surface; nil for any other equation.
    public func scalarField(parameters: [String: Double] = [:]) -> ScalarField? {
        guard system == .implicit, case .expression(let left) = lhs, arguments.count == 3 else { return nil }
        func square(_ s: Symbol) -> Expr { .binary(.power, .variable(s), .number(2, "2")) }
        let sum = Expr.binary(.add, .binary(.add, square(arguments[0]), square(arguments[1])), square(arguments[2]))
        let radius = Expr.root(sum, index: nil)
        let r = Symbol("r")
        let difference = Expr.binary(.subtract, left.replacing(r, with: radius), rhs.replacing(r, with: radius))
        return ScalarField(expression: difference, arguments: arguments, parameters: parameters)
    }
}

/// A field sampled on an n × n × n grid over [−half, half]³.
public struct FieldGrid: Sendable {
    public let n: Int
    public let half: Double
    /// Index `(k * n + j) * n + i` for x_i, y_j, z_k. NaN where undefined.
    public let values: [Float]

    public static func sample(_ field: ScalarField, half: Double, n requested: Int) -> FieldGrid {
        let n = Swift.max(2, requested)
        var values = [Float](repeating: .nan, count: n * n * n)
        let d = 2 * half / Double(n - 1)
        for k in 0..<n {
            let slice = field.slice(z: -half + Double(k) * d)
            for j in 0..<n {
                let y = -half + Double(j) * d
                for i in 0..<n {
                    let v = slice(-half + Double(i) * d, y)
                    if v.isFinite, Swift.abs(v) < 1e30 { values[(k * n + j) * n + i] = Float(v) }
                }
            }
        }
        return FieldGrid(n: n, half: half, values: values)
    }
}

// MARK: - Iso-surface

/// Triangles of an iso-surface: three consecutive vertices make one triangle.
public struct IsoMesh: Sendable {
    public var positions: [SIMD3<Float>] = []
    /// The field's gradient at each vertex (not normalised; zero where it vanishes).
    public var gradients: [SIMD3<Float>] = []
}

/// Marching tetrahedra: each cell is cut into six tetrahedra around a diagonal, and each
/// tetrahedron contributes zero, one or two triangles. No lookup tables, and no ambiguous cases.
public enum IsoSurface {
    private static let corners: [(Int, Int, Int)] = [
        (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0), (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
    ]
    private static let tetrahedra: [[Int]] = [
        [0, 5, 1, 6], [0, 1, 2, 6], [0, 2, 3, 6], [0, 3, 7, 6], [0, 7, 4, 6], [0, 4, 5, 6],
    ]

    public static func extract(_ grid: FieldGrid, level: Float = 0) -> IsoMesh {
        let n = grid.n
        let values = grid.values
        let h = Float(grid.half)
        let d = 2 * h / Float(n - 1)
        var mesh = IsoMesh()

        func fieldValue(_ i: Int, _ j: Int, _ k: Int) -> Float {
            values[(k * n + j) * n + i]
        }
        /// Central differences, one-sided at the edge of the grid or next to an undefined value.
        func gradient(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
            let c = fieldValue(i, j, k)
            func slope(_ lo: Float, _ hi: Float, _ loValid: Bool, _ hiValid: Bool) -> Float {
                if loValid && hiValid { return (hi - lo) / (2 * d) }
                if hiValid { return (hi - c) / d }
                if loValid { return (c - lo) / d }
                return 0
            }
            func neighbour(_ a: Int, _ b: Int, _ c3: Int) -> (Float, Bool) {
                guard a >= 0, a < n, b >= 0, b < n, c3 >= 0, c3 < n else { return (0, false) }
                let v = fieldValue(a, b, c3)
                return (v, !v.isNaN)
            }
            let (xl, xlv) = neighbour(i - 1, j, k), (xh, xhv) = neighbour(i + 1, j, k)
            let (yl, ylv) = neighbour(i, j - 1, k), (yh, yhv) = neighbour(i, j + 1, k)
            let (zl, zlv) = neighbour(i, j, k - 1), (zh, zhv) = neighbour(i, j, k + 1)
            return SIMD3(slope(xl, xh, xlv, xhv), slope(yl, yh, ylv, yhv), slope(zl, zh, zlv, zhv))
        }

        for k in 0..<(n - 1) {
            for j in 0..<(n - 1) {
                for i in 0..<(n - 1) {
                    var v = [Float](repeating: 0, count: 8)
                    var anyInside = false, anyOutside = false, defined = true
                    for c in 0..<8 {
                        let o = corners[c]
                        let sample = fieldValue(i + o.0, j + o.1, k + o.2)
                        if sample.isNaN { defined = false; break }
                        v[c] = sample
                        if sample >= level { anyInside = true } else { anyOutside = true }
                    }
                    guard defined, anyInside, anyOutside else { continue }

                    var p = [SIMD3<Float>](repeating: .zero, count: 8)
                    var g = [SIMD3<Float>](repeating: .zero, count: 8)
                    for c in 0..<8 {
                        let o = corners[c]
                        p[c] = SIMD3(-h + Float(i + o.0) * d, -h + Float(j + o.1) * d, -h + Float(k + o.2) * d)
                        g[c] = gradient(i + o.0, j + o.1, k + o.2)
                    }

                    func cut(_ a: Int, _ b: Int) -> (SIMD3<Float>, SIMD3<Float>) {
                        let denominator = v[b] - v[a]
                        let t = denominator == 0 ? 0.5 : (level - v[a]) / denominator
                        return (p[a] + t * (p[b] - p[a]), g[a] + t * (g[b] - g[a]))
                    }
                    func emit(_ a: (SIMD3<Float>, SIMD3<Float>), _ b: (SIMD3<Float>, SIMD3<Float>),
                              _ c: (SIMD3<Float>, SIMD3<Float>)) {
                        mesh.positions += [a.0, b.0, c.0]
                        mesh.gradients += [a.1, b.1, c.1]
                    }

                    for tetrahedron in tetrahedra {
                        let inside = tetrahedron.filter { v[$0] >= level }
                        let outside = tetrahedron.filter { v[$0] < level }
                        switch inside.count {
                        case 1:
                            let a = inside[0]
                            emit(cut(a, outside[0]), cut(a, outside[1]), cut(a, outside[2]))
                        case 3:
                            let a = outside[0]
                            emit(cut(a, inside[0]), cut(a, inside[1]), cut(a, inside[2]))
                        case 2:
                            let a = inside[0], b = inside[1], c = outside[0], e = outside[1]
                            emit(cut(a, c), cut(a, e), cut(b, e))
                            emit(cut(a, c), cut(b, e), cut(b, c))
                        default:
                            break
                        }
                    }
                }
            }
        }
        return mesh
    }
}
