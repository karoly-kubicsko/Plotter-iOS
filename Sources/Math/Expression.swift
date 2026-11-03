import Foundation

/// Mathematical constants that have a name in LaTeX.
public enum MathConstant: Sendable, Equatable {
    case e, pi, infinity

    public var value: Double {
        switch self {
        case .e: 2.718_281_828_459_045
        case .pi: Double.pi
        case .infinity: Double.infinity
        }
    }
}

/// A variable or parameter name such as `x`, `a_1` or `\omega`.
public struct Symbol: Hashable, Sendable {
    /// A Latin letter ("a") or a Greek TeX name ("omega").
    public let base: String
    /// Subscript text as written, e.g. "1" for `a_1`, "max" for `a_{max}`.
    public let subscriptText: String?

    public init(_ base: String, sub: String? = nil) {
        self.base = base
        self.subscriptText = sub
    }

    /// Canonical name used as a dictionary key, e.g. "a_1", "omega".
    public var name: String {
        if let subscriptText { return "\(base)_\(subscriptText)" }
        return base
    }

    public var isGreek: Bool { Greek.letters[base] != nil }

    /// A short Unicode label for the UI, e.g. "ω", "a₁".
    public var displayName: String {
        let head = Greek.letters[base].map(String.init) ?? base
        guard let subscriptText else { return head }
        let digits: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        ]
        if subscriptText.allSatisfy({ digits[$0] != nil }) {
            return head + String(subscriptText.compactMap { digits[$0] })
        }
        return "\(head)_\(subscriptText)"
    }
}

/// How a product was written. Only affects typesetting.
public enum MultiplicationStyle: Sendable, Equatable {
    case implicit, cdot, times, star
}

/// How a quotient was written. Only affects typesetting.
public enum DivisionStyle: Sendable, Equatable {
    case fraction, slash
}

public enum BinaryOperator: Sendable, Equatable {
    case add, subtract
    case multiply(MultiplicationStyle)
    case divide(DivisionStyle)
    case power
}

/// Named functions. The raw value is the LaTeX command name.
public enum MathFunction: String, Sendable, CaseIterable {
    case sin, cos, tan, cot, sec, csc
    case arcsin, arccos, arctan, arccot
    case sinh, cosh, tanh, coth, sech, csch
    case arsinh, arcosh, artanh
    case exp, ln, log, lg
    case sgn, sign, floor, ceil, round, erf
    case min, max

    /// Accepts common alternative spellings.
    public init?(command: String) {
        switch command {
        case "arcsinh", "asinh": self = .arsinh
        case "arccosh", "acosh": self = .arcosh
        case "arctanh", "atanh": self = .artanh
        case "asin": self = .arcsin
        case "acos": self = .arccos
        case "atan": self = .arctan
        default: self.init(rawValue: command)
        }
    }

    /// The function written as `f^{-1}` maps to its inverse.
    var inverse: MathFunction? {
        switch self {
        case .sin: .arcsin
        case .cos: .arccos
        case .tan: .arctan
        case .cot: .arccot
        case .sinh: .arsinh
        case .cosh: .arcosh
        case .tanh: .artanh
        default: nil
        }
    }

    /// Functions that take a parenthesised, comma-separated argument list.
    var takesArgumentList: Bool { self == .min || self == .max }
}

/// The syntax tree. It keeps presentation details (grouping, operator style)
/// so the same tree drives both evaluation and typesetting.
public indirect enum Expr: Sendable, Equatable {
    case number(Double, String)
    case constant(MathConstant)
    case variable(Symbol)
    case negate(Expr)
    case binary(BinaryOperator, Expr, Expr)
    /// `\sin^2 x` stores the power separately; `\log_b x` stores the base.
    case call(MathFunction, [Expr], power: Expr?, base: Expr?)
    case root(Expr, index: Expr?)
    case abs(Expr)
    /// Visible brackets. Paren, bracket and brace groups are transparent for
    /// evaluation; floor and ceiling brackets apply their function.
    case group(Expr, Delimiter)
    case factorial(Expr)

    /// Fully parenthesised prefix form, used by tests and for debugging.
    public var sExpression: String {
        switch self {
        case .number(_, let text): return text
        case .constant(let c):
            switch c {
            case .e: return "e"
            case .pi: return "pi"
            case .infinity: return "inf"
            }
        case .variable(let s): return s.name
        case .negate(let x): return "(neg \(x.sExpression))"
        case .binary(let op, let l, let r):
            let symbol: String
            switch op {
            case .add: symbol = "+"
            case .subtract: symbol = "-"
            case .multiply: symbol = "*"
            case .divide: symbol = "/"
            case .power: symbol = "^"
            }
            return "(\(symbol) \(l.sExpression) \(r.sExpression))"
        case .call(let f, let args, let power, let base):
            var head = f.rawValue
            if let base { head += "_\(base.sExpression)" }
            if let power { head += "^\(power.sExpression)" }
            return "(\(head) \(args.map(\.sExpression).joined(separator: " ")))"
        case .root(let x, let index):
            if let index { return "(root \(index.sExpression) \(x.sExpression))" }
            return "(sqrt \(x.sExpression))"
        case .abs(let x): return "(abs \(x.sExpression))"
        case .group(let x, let d):
            switch d {
            case .floor: return "(floor \(x.sExpression))"
            case .ceil: return "(ceil \(x.sExpression))"
            default: return x.sExpression
            }
        case .factorial(let x): return "(! \(x.sExpression))"
        }
    }

    /// Variables in order of first appearance.
    public var symbols: [Symbol] {
        var seen: [Symbol] = []
        collectSymbols(into: &seen)
        return seen
    }

    private func collectSymbols(into seen: inout [Symbol]) {
        switch self {
        case .number, .constant: break
        case .variable(let s): if !seen.contains(s) { seen.append(s) }
        case .negate(let x), .abs(let x), .group(let x, _), .factorial(let x): x.collectSymbols(into: &seen)
        case .binary(_, let l, let r):
            l.collectSymbols(into: &seen)
            r.collectSymbols(into: &seen)
        case .call(_, let args, let power, let base):
            base?.collectSymbols(into: &seen)
            for a in args { a.collectSymbols(into: &seen) }
            power?.collectSymbols(into: &seen)
        case .root(let x, let index):
            index?.collectSymbols(into: &seen)
            x.collectSymbols(into: &seen)
        }
    }
}

/// What kind of graph an equation describes.
public enum PlotKind: String, Sendable, Codable {
    /// y = f(x), drawn in the 2D view.
    case curve
    /// z = f(x, y), drawn in the 3D view.
    case surface
}

/// The left-hand side as written by the user.
public enum LeftHandSide: Sendable, Equatable {
    case none
    case variable(Symbol)                    // y = …, z = …
    case function(Symbol, [Symbol])          // f(x) = …, g(x, y) = …
}

/// A parsed and classified input line.
public struct Equation: Sendable {
    public let lhs: LeftHandSide
    public let rhs: Expr
    public let kind: PlotKind
    /// Independent variables, in evaluation order: ["x"] or ["x", "y"].
    public let arguments: [Symbol]
    /// Free parameters (every other symbol), in order of appearance.
    public let parameters: [Symbol]
}
