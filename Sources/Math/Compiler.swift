import Foundation

/// A function compiled from an expression tree into nested closures, with constant
/// sub-expressions folded and parameters baked in. Evaluating it does not walk the
/// tree. Undefined points (domain errors) evaluate to NaN.
public struct CompiledFunction: Sendable {
    public typealias Body = @Sendable (Double, Double) -> Double

    private let body: Body

    /// Compiles `expr`. `arguments` names the one or two independent variables;
    /// every other symbol takes its value from `parameters` (default 1).
    public init(_ expr: Expr, arguments: [Symbol], parameters: [String: Double] = [:]) {
        let context = Context(arguments: arguments.map(\.name), parameters: parameters)
        switch Self.build(expr, context) {
        case .constant(let c): body = { _, _ in c }
        case .code(let f): body = f
        }
    }

    public func callAsFunction(_ a: Double, _ b: Double = 0) -> Double {
        body(a, b)
    }

    // MARK: - Building

    private struct Context {
        let arguments: [String]
        let parameters: [String: Double]
    }

    private enum Code {
        case constant(Double)
        case code(Body)
    }

    private static func unary(_ x: Code, _ op: @escaping @Sendable (Double) -> Double) -> Code {
        switch x {
        case .constant(let c): return .constant(op(c))
        case .code(let f): return .code { a, b in op(f(a, b)) }
        }
    }

    private static func binary(_ l: Code, _ r: Code, _ op: @escaping @Sendable (Double, Double) -> Double) -> Code {
        switch (l, r) {
        case (.constant(let p), .constant(let q)): return .constant(op(p, q))
        case (.constant(let p), .code(let g)): return .code { a, b in op(p, g(a, b)) }
        case (.code(let f), .constant(let q)): return .code { a, b in op(f(a, b), q) }
        case (.code(let f), .code(let g)): return .code { a, b in op(f(a, b), g(a, b)) }
        }
    }

    private static func build(_ expr: Expr, _ ctx: Context) -> Code {
        switch expr {
        case .number(let v, _):
            return .constant(v)
        case .constant(let c):
            return .constant(c.value)
        case .variable(let s):
            if ctx.arguments.first == s.name { return .code { a, _ in a } }
            if ctx.arguments.count > 1, ctx.arguments[1] == s.name { return .code { _, b in b } }
            return .constant(ctx.parameters[s.name] ?? 1)
        case .negate(let x):
            return unary(build(x, ctx)) { -$0 }
        case .binary(let op, let l, let r):
            return buildBinary(op, l, r, ctx)
        case .call(let function, let args, let power, let base):
            return buildCall(function, args, power: power, base: base, ctx)
        case .root(let x, let index):
            let radicand = build(x, ctx)
            guard let index else { return unary(radicand) { $0.squareRoot() } }
            let n = build(index, ctx)
            if case .constant(let k) = n, k == k.rounded(), Int(k) % 2 != 0 {
                // Odd roots of negative numbers are real: ∛(−8) = −2.
                let inv = 1 / k
                return unary(radicand) { v in v < 0 ? -Foundation.pow(-v, inv) : Foundation.pow(v, inv) }
            }
            return binary(radicand, n) { v, k in Foundation.pow(v, 1 / k) }
        case .abs(let x):
            return unary(build(x, ctx)) { Swift.abs($0) }
        case .group(let x, let delimiter):
            let inner = build(x, ctx)
            switch delimiter {
            case .floor: return unary(inner) { Foundation.floor($0) }
            case .ceil: return unary(inner) { Foundation.ceil($0) }
            default: return inner
            }
        case .factorial(let x):
            return unary(build(x, ctx)) { Foundation.tgamma($0 + 1) }
        }
    }

    private static func buildBinary(_ op: BinaryOperator, _ l: Expr, _ r: Expr, _ ctx: Context) -> Code {
        let left = build(l, ctx)
        switch op {
        case .add: return binary(left, build(r, ctx)) { $0 + $1 }
        case .subtract: return binary(left, build(r, ctx)) { $0 - $1 }
        case .multiply: return binary(left, build(r, ctx)) { $0 * $1 }
        case .divide: return binary(left, build(r, ctx)) { $0 / $1 }
        case .power:
            if let rational = oddRational(r) {
                let (p, q) = rational
                // x^{p/q} with odd q is real for negative x: x^{1/3}, x^{2/3}.
                let exponent = Double(p) / Double(q)
                let oddP = p % 2 != 0
                return unary(left) { v in
                    guard v < 0 else { return Foundation.pow(v, exponent) }
                    let m = Foundation.pow(-v, exponent)
                    return oddP ? -m : m
                }
            }
            let right = build(r, ctx)
            if case .constant(let k) = right {
                switch k {
                case 1: return left
                case 2: return unary(left) { $0 * $0 }
                case 3: return unary(left) { $0 * $0 * $0 }
                case 0.5: return unary(left) { $0.squareRoot() }
                case -1: return unary(left) { 1 / $0 }
                default: break
                }
            }
            return binary(left, right) { Foundation.pow($0, $1) }
        }
    }

    /// Recognises exponents written as p/q (or \frac{p}{q}) with integer p and odd q > 1.
    private static func oddRational(_ e: Expr) -> (Int, Int)? {
        var e = e
        var sign = 1
        while true {
            if case .group(let inner, let d) = e, d != .floor, d != .ceil { e = inner; continue }
            if case .negate(let inner) = e { sign = -sign; e = inner; continue }
            break
        }
        guard case .binary(.divide, .number(let p, _), .number(let q, _)) = e,
              p == p.rounded(), q == q.rounded(), q > 1, Swift.abs(p) < 1e9, q < 1e9 else { return nil }
        let qi = Int(q)
        guard qi % 2 != 0 else { return nil }
        return (sign * Int(p), qi)
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
            function = inverse  // \sin^{-1} x = arcsin x
            power = nil
        }

        let codes = args.map { build($0, ctx) }
        var result: Code
        switch function {
        case .min:
            result = codes.dropFirst().reduce(codes[0]) { acc, next in binary(acc, next) { Swift.min($0, $1) } }
        case .max:
            result = codes.dropFirst().reduce(codes[0]) { acc, next in binary(acc, next) { Swift.max($0, $1) } }
        case .log:
            if let base {
                result = binary(codes[0], build(base, ctx)) { Foundation.log($0) / Foundation.log($1) }
            } else {
                result = unary(codes[0]) { Foundation.log10($0) }
            }
        default:
            result = unary(codes[0], Self.function(function))
        }
        if let power {
            let p = build(power, ctx)
            if case .constant(2) = p {
                result = unary(result) { $0 * $0 }
            } else {
                result = binary(result, p) { Foundation.pow($0, $1) }
            }
        }
        return result
    }

    private static func function(_ f: MathFunction) -> @Sendable (Double) -> Double {
        switch f {
        case .sin: return { Foundation.sin($0) }
        case .cos: return { Foundation.cos($0) }
        case .tan: return { Foundation.tan($0) }
        case .cot: return { 1 / Foundation.tan($0) }
        case .sec: return { 1 / Foundation.cos($0) }
        case .csc: return { 1 / Foundation.sin($0) }
        case .arcsin: return { Foundation.asin($0) }
        case .arccos: return { Foundation.acos($0) }
        case .arctan: return { Foundation.atan($0) }
        case .arccot: return { Double.pi / 2 - Foundation.atan($0) }
        case .sinh: return { Foundation.sinh($0) }
        case .cosh: return { Foundation.cosh($0) }
        case .tanh: return { Foundation.tanh($0) }
        case .coth: return { 1 / Foundation.tanh($0) }
        case .sech: return { 1 / Foundation.cosh($0) }
        case .csch: return { 1 / Foundation.sinh($0) }
        case .arsinh: return { Foundation.asinh($0) }
        case .arcosh: return { Foundation.acosh($0) }
        case .artanh: return { Foundation.atanh($0) }
        case .exp: return { Foundation.exp($0) }
        case .ln: return { Foundation.log($0) }
        case .log, .lg: return { Foundation.log10($0) }
        case .sgn, .sign: return { $0 > 0 ? 1 : ($0 < 0 ? -1 : ($0 == 0 ? 0 : .nan)) }
        case .floor: return { Foundation.floor($0) }
        case .ceil: return { Foundation.ceil($0) }
        case .round: return { Foundation.round($0) }
        case .erf: return { Foundation.erf($0) }
        case .min, .max: return { $0 }
        }
    }
}

extension Equation {
    /// Compiles the right-hand side with the given parameter values.
    public func compile(parameters: [String: Double] = [:]) -> CompiledFunction {
        CompiledFunction(rhs, arguments: arguments, parameters: parameters)
    }
}
