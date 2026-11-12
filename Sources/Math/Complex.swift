import Foundation

/// A complex number in double precision. Functions return principal values; the
/// branch cut of log, sqrt and non-integer powers lies along the negative real axis.
public struct Complex: Sendable, Equatable {
    public var re: Double
    public var im: Double

    public init(_ re: Double, _ im: Double = 0) {
        self.re = re
        self.im = im
    }

    public static let zero = Complex(0)
    public static let one = Complex(1)
    public static let i = Complex(0, 1)
    public static let nan = Complex(.nan, .nan)

    public var isReal: Bool { im == 0 }
    public var modulus: Double { hypot(re, im) }
    public var argument: Double { Foundation.atan2(im, re) }
    /// The conjugate. A zero imaginary part stays +0, so that real numbers keep the
    /// principal argument (π, not −π, for a negative real).
    public var conjugate: Complex { Complex(re, im == 0 ? 0 : -im) }

    // MARK: Arithmetic

    public static func + (a: Complex, b: Complex) -> Complex { Complex(a.re + b.re, a.im + b.im) }
    public static func - (a: Complex, b: Complex) -> Complex { Complex(a.re - b.re, a.im - b.im) }
    /// Negation; as for the conjugate, a zero imaginary part stays +0, so −8 lies on
    /// the upper side of the branch cut and ∛(−8) is the principal 1 + √3 i.
    public static prefix func - (a: Complex) -> Complex { Complex(-a.re, a.im == 0 ? 0 : -a.im) }

    public static func * (a: Complex, b: Complex) -> Complex {
        if a.im == 0 && b.im == 0 { return Complex(a.re * b.re) }
        return Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }

    /// Smith's algorithm, which avoids overflow in the denominator.
    public static func / (a: Complex, b: Complex) -> Complex {
        if a.im == 0 && b.im == 0 { return Complex(a.re / b.re) }
        if Swift.abs(b.re) >= Swift.abs(b.im) {
            if b.re == 0 && b.im == 0 { return Complex(a.re / 0, a.im / 0) }
            let r = b.im / b.re
            let d = b.re + b.im * r
            return Complex((a.re + a.im * r) / d, (a.im - a.re * r) / d)
        } else {
            let r = b.re / b.im
            let d = b.re * r + b.im
            return Complex((a.re * r + a.im) / d, (a.im * r - a.re) / d)
        }
    }

    // MARK: Elementary functions

    public static func exp(_ z: Complex) -> Complex {
        let m = Foundation.exp(z.re)
        if z.im == 0 { return Complex(m) }
        return Complex(m * Foundation.cos(z.im), m * Foundation.sin(z.im))
    }

    /// Principal natural logarithm: ln|z| + i·arg z, with arg in (−π, π].
    public static func log(_ z: Complex) -> Complex {
        Complex(Foundation.log(z.modulus), z.argument)
    }

    /// Principal square root (non-negative real part).
    public static func sqrt(_ z: Complex) -> Complex {
        if z.im == 0 {
            return z.re >= 0 ? Complex(z.re.squareRoot()) : Complex(0, (-z.re).squareRoot())
        }
        let t = ((z.modulus + Swift.abs(z.re)) / 2).squareRoot()
        if z.re >= 0 {
            return Complex(t, z.im / (2 * t))
        }
        return Complex(Swift.abs(z.im) / (2 * t), z.im < 0 ? -t : t)
    }

    /// Principal power z^w = exp(w·log z). Integer exponents are computed by
    /// repeated multiplication, so that i² is exactly −1.
    public static func pow(_ z: Complex, _ w: Complex) -> Complex {
        if w.im == 0, w.re == w.re.rounded(), Swift.abs(w.re) <= 1024 {
            return integerPower(z, Int(w.re))
        }
        if z.re == 0 && z.im == 0 {
            if w.re > 0 { return .zero }
            return .nan
        }
        return exp(w * log(z))
    }

    private static func integerPower(_ z: Complex, _ n: Int) -> Complex {
        if n == 0 { return .one }
        var base = n < 0 ? one / z : z
        var k = Swift.abs(n)
        var result = Complex.one
        while k > 0 {
            if k & 1 == 1 { result = result * base }
            base = base * base
            k >>= 1
        }
        return result
    }

    public static func sin(_ z: Complex) -> Complex {
        if z.im == 0 { return Complex(Foundation.sin(z.re)) }
        return Complex(Foundation.sin(z.re) * Foundation.cosh(z.im), Foundation.cos(z.re) * Foundation.sinh(z.im))
    }

    public static func cos(_ z: Complex) -> Complex {
        if z.im == 0 { return Complex(Foundation.cos(z.re)) }
        return Complex(Foundation.cos(z.re) * Foundation.cosh(z.im), -Foundation.sin(z.re) * Foundation.sinh(z.im))
    }

    public static func sinh(_ z: Complex) -> Complex {
        if z.im == 0 { return Complex(Foundation.sinh(z.re)) }
        return Complex(Foundation.sinh(z.re) * Foundation.cos(z.im), Foundation.cosh(z.re) * Foundation.sin(z.im))
    }

    public static func cosh(_ z: Complex) -> Complex {
        if z.im == 0 { return Complex(Foundation.cosh(z.re)) }
        return Complex(Foundation.cosh(z.re) * Foundation.cos(z.im), Foundation.sinh(z.re) * Foundation.sin(z.im))
    }

    // Inverse functions via logarithms (principal branches).

    public static func asin(_ z: Complex) -> Complex {
        if z.im == 0 && Swift.abs(z.re) <= 1 { return Complex(Foundation.asin(z.re)) }
        // −i·ln(iz + √(1 − z²))
        let w = log(i * z + sqrt(one - z * z))
        return Complex(w.im, -w.re)
    }

    public static func acos(_ z: Complex) -> Complex {
        if z.im == 0 && Swift.abs(z.re) <= 1 { return Complex(Foundation.acos(z.re)) }
        return Complex(Double.pi / 2) - asin(z)
    }

    public static func atan(_ z: Complex) -> Complex {
        if z.im == 0 { return Complex(Foundation.atan(z.re)) }
        // (i/2)·(ln(1 − iz) − ln(1 + iz))
        let d = log(one - i * z) - log(one + i * z)
        return Complex(-d.im / 2, d.re / 2)
    }

    public static func asinh(_ z: Complex) -> Complex {
        if z.im == 0 { return Complex(Foundation.asinh(z.re)) }
        return log(z + sqrt(z * z + one))
    }

    public static func acosh(_ z: Complex) -> Complex {
        if z.im == 0 && z.re >= 1 { return Complex(Foundation.acosh(z.re)) }
        return log(z + sqrt(z + one) * sqrt(z - one))
    }

    public static func atanh(_ z: Complex) -> Complex {
        if z.im == 0 && Swift.abs(z.re) < 1 { return Complex(Foundation.atanh(z.re)) }
        let d = log(one + z) - log(one - z)
        return Complex(d.re / 2, d.im / 2)
    }
}

/// A function compiled with complex arithmetic, like `CompiledFunction` for real
/// values: closures with constant folding, parameters baked in.
public struct ComplexFunction: Sendable {
    public typealias Body = @Sendable (Double, Double) -> Complex

    private let body: Body

    public init(_ expr: Expr, arguments: [Symbol], parameters: [String: Double] = [:]) {
        let context = Context(arguments: arguments.map(\.name), parameters: parameters)
        switch Self.build(expr, context) {
        case .constant(let c): body = { _, _ in c }
        case .code(let f): body = f
        }
    }

    public func callAsFunction(_ a: Double, _ b: Double = 0) -> Complex {
        body(a, b)
    }

    // MARK: Building

    private struct Context {
        let arguments: [String]
        let parameters: [String: Double]
    }

    private enum Code {
        case constant(Complex)
        case code(Body)
    }

    private static func unary(_ x: Code, _ op: @escaping @Sendable (Complex) -> Complex) -> Code {
        switch x {
        case .constant(let c): return .constant(op(c))
        case .code(let f): return .code { a, b in op(f(a, b)) }
        }
    }

    private static func binary(_ l: Code, _ r: Code, _ op: @escaping @Sendable (Complex, Complex) -> Complex) -> Code {
        switch (l, r) {
        case (.constant(let p), .constant(let q)): return .constant(op(p, q))
        case (.constant(let p), .code(let g)): return .code { a, b in op(p, g(a, b)) }
        case (.code(let f), .constant(let q)): return .code { a, b in op(f(a, b), q) }
        case (.code(let f), .code(let g)): return .code { a, b in op(f(a, b), g(a, b)) }
        }
    }

    /// Applies a real function to real arguments; a complex argument gives NaN.
    private static func realOnly(_ f: @escaping @Sendable (Double) -> Double) -> @Sendable (Complex) -> Complex {
        { z in z.im == 0 ? Complex(f(z.re)) : .nan }
    }

    private static func build(_ expr: Expr, _ ctx: Context) -> Code {
        switch expr {
        case .number(let v, _):
            return .constant(Complex(v))
        case .constant(let c):
            return .constant(c == .imaginaryUnit ? .i : Complex(c.value))
        case .variable(let s):
            if ctx.arguments.first == s.name { return .code { a, _ in Complex(a) } }
            if ctx.arguments.count > 1, ctx.arguments[1] == s.name { return .code { _, b in Complex(b) } }
            return .constant(Complex(ctx.parameters[s.name] ?? 1))
        case .negate(let x):
            return unary(build(x, ctx)) { -$0 }
        case .binary(let op, let l, let r):
            switch op {
            case .add: return binary(build(l, ctx), build(r, ctx)) { $0 + $1 }
            case .subtract: return binary(build(l, ctx), build(r, ctx)) { $0 - $1 }
            case .multiply: return binary(build(l, ctx), build(r, ctx)) { $0 * $1 }
            case .divide: return binary(build(l, ctx), build(r, ctx)) { $0 / $1 }
            case .power:
                if case .constant(.e) = l {
                    return unary(build(r, ctx)) { Complex.exp($0) }  // e^z exactly, not exp(z·ln e)
                }
                return binary(build(l, ctx), build(r, ctx)) { Complex.pow($0, $1) }
            }
        case .call(let function, let args, let power, let base):
            return buildCall(function, args, power: power, base: base, ctx)
        case .root(let x, let index):
            let radicand = build(x, ctx)
            guard let index else { return unary(radicand) { Complex.sqrt($0) } }
            return binary(radicand, build(index, ctx)) { z, n in Complex.pow(z, Complex.one / n) }
        case .abs(let x):
            return unary(build(x, ctx)) { Complex($0.modulus) }
        case .group(let x, let delimiter):
            let inner = build(x, ctx)
            switch delimiter {
            case .floor: return unary(inner) { Complex(Foundation.floor($0.re), Foundation.floor($0.im)) }
            case .ceil: return unary(inner) { Complex(Foundation.ceil($0.re), Foundation.ceil($0.im)) }
            default: return inner
            }
        case .factorial(let x):
            return unary(build(x, ctx), realOnly { Foundation.tgamma($0 + 1) })
        case .conjugate(let x):
            return unary(build(x, ctx)) { $0.conjugate }
        }
    }

    private static func isMinusOne(_ e: Expr?) -> Bool {
        guard var e else { return false }
        if case .group(let inner, .paren) = e { e = inner }
        if case .negate(.number(let v, _)) = e { return v == 1 }
        return false
    }

    private static func buildCall(_ function: MathFunction, _ args: [Expr], power: Expr?, base: Expr?,
                                  _ ctx: Context) -> Code {
        var function = function
        var power = power
        if isMinusOne(power), let inverse = function.inverse {
            function = inverse
            power = nil
        }
        let codes = args.map { build($0, ctx) }
        var result: Code
        switch function {
        case .min, .max:
            let pick: @Sendable (Double, Double) -> Double = function == .min ? { Swift.min($0, $1) } : { Swift.max($0, $1) }
            result = codes.dropFirst().reduce(codes[0]) { acc, next in
                binary(acc, next) { p, q in p.im == 0 && q.im == 0 ? Complex(pick(p.re, q.re)) : .nan }
            }
        case .log:
            if let base {
                result = binary(codes[0], build(base, ctx)) { Complex.log($0) / Complex.log($1) }
            } else {
                result = unary(codes[0]) { Complex.log($0) / Complex(Foundation.log(10)) }
            }
        default:
            result = unary(codes[0], Self.function(function))
        }
        if let power {
            result = binary(result, build(power, ctx)) { Complex.pow($0, $1) }
        }
        return result
    }

    private static func function(_ f: MathFunction) -> @Sendable (Complex) -> Complex {
        switch f {
        case .sin: return { Complex.sin($0) }
        case .cos: return { Complex.cos($0) }
        case .tan: return { Complex.sin($0) / Complex.cos($0) }
        case .cot: return { Complex.cos($0) / Complex.sin($0) }
        case .sec: return { Complex.one / Complex.cos($0) }
        case .csc: return { Complex.one / Complex.sin($0) }
        case .arcsin: return { Complex.asin($0) }
        case .arccos: return { Complex.acos($0) }
        case .arctan: return { Complex.atan($0) }
        case .arccot: return { Complex(Double.pi / 2) - Complex.atan($0) }
        case .sinh: return { Complex.sinh($0) }
        case .cosh: return { Complex.cosh($0) }
        case .tanh: return { Complex.sinh($0) / Complex.cosh($0) }
        case .coth: return { Complex.cosh($0) / Complex.sinh($0) }
        case .sech: return { Complex.one / Complex.cosh($0) }
        case .csch: return { Complex.one / Complex.sinh($0) }
        case .arsinh: return { Complex.asinh($0) }
        case .arcosh: return { Complex.acosh($0) }
        case .artanh: return { Complex.atanh($0) }
        case .exp: return { Complex.exp($0) }
        case .ln: return { Complex.log($0) }
        case .log, .lg: return { Complex.log($0) / Complex(Foundation.log(10)) }
        case .sgn, .sign:
            return { z in
                let m = z.modulus
                if m == 0 { return .zero }
                return Complex(z.re / m, z.im / m)
            }
        case .floor: return { Complex(Foundation.floor($0.re), Foundation.floor($0.im)) }
        case .ceil: return { Complex(Foundation.ceil($0.re), Foundation.ceil($0.im)) }
        case .round: return { Complex(Foundation.round($0.re), Foundation.round($0.im)) }
        case .erf: return realOnly { Foundation.erf($0) }
        case .min, .max: return { $0 }
        case .re: return { Complex($0.re) }
        case .im: return { Complex($0.im) }
        case .arg: return { Complex($0.argument) }
        case .conj: return { $0.conjugate }
        }
    }
}
