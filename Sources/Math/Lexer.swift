import Foundation

/// A parse or lexing error with the character range of the offending input,
/// counted in `Character`s from the start of the source string.
public struct MathError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let range: Range<Int>

    public init(_ message: String, at range: Range<Int>) {
        self.message = message
        self.range = range
    }

    public var description: String { "\(message) [\(range.lowerBound)..<\(range.upperBound)]" }
}

/// Bracket kinds that can open or close a group.
public enum Delimiter: Sendable, Equatable {
    case paren      // ( )
    case bracket    // [ ]
    case brace      // \{ \}
    case floor      // \lfloor \rfloor
    case ceil       // \lceil \rceil
}

/// One lexical unit of the LaTeX input.
public enum TokenKind: Sendable, Equatable {
    case number(String)       // "3.14" (digits as written)
    case letter(Character)    // a single Latin letter
    case command(String)      // "sin", "frac", "alpha", ... (without the backslash)
    case plus, minus, star, slash, caret, underscore, equals, comma, bang, bar
    case cdot, times
    case open(Delimiter), close(Delimiter)
    case groupOpen, groupClose   // TeX braces { }
    case end
}

public struct Token: Sendable, Equatable {
    public var kind: TokenKind
    public var range: Range<Int>
}

/// Turns a LaTeX string into tokens. Spacing commands (`\,`, `\quad`, …) and
/// sizing commands (`\left`, `\right`, `\big`, …) are dropped here because they
/// carry no mathematical meaning; the typesetter sizes delimiters by itself.
public struct Lexer {
    private let chars: [Character]
    private var index = 0

    public init(_ source: String) {
        chars = Array(source)
    }

    /// Function names users commonly type without a backslash.
    private static let bareFunctionNames = [
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "sqrt",
        "sin", "cos", "tan", "cot", "sec", "csc", "exp", "log", "ln",
    ]

    private static let ignoredCommands: Set<String> = [
        "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
        "biggl", "biggr", "Biggl", "Biggr", "displaystyle", "textstyle", "quad", "qquad",
        "limits", "nolimits",
    ]

    public mutating func tokenize() throws(MathError) -> [Token] {
        var tokens: [Token] = []
        while true {
            skipWhitespace()
            guard index < chars.count else { break }
            let start = index
            let c = chars[index]

            if c.isASCII && (c.isNumber || (c == "." && peekIsDigit(1))) {
                tokens.append(Token(kind: .number(readNumber()), range: start..<index))
                continue
            }
            if c.isASCII && c.isLetter {
                if let name = bareFunctionName(at: index) {
                    throw MathError("Write \\\(name) for the function \(name)", at: index..<(index + name.count))
                }
                index += 1
                tokens.append(Token(kind: .letter(c), range: start..<index))
                continue
            }
            if c == "\\" {
                if let token = try readCommand() {
                    tokens.append(token)
                }
                continue
            }

            index += 1
            let kind: TokenKind
            switch c {
            case "+": kind = .plus
            case "-", "−": kind = .minus
            case "*", "∗": kind = .star
            case "/": kind = .slash
            case "^": kind = .caret
            case "_": kind = .underscore
            case "=": kind = .equals
            case ",": kind = .comma
            case "!": kind = .bang
            case "|": kind = .bar
            case "·", "⋅": kind = .cdot
            case "×": kind = .times
            case "(": kind = .open(.paren)
            case ")": kind = .close(.paren)
            case "[": kind = .open(.bracket)
            case "]": kind = .close(.bracket)
            case "{": kind = .groupOpen
            case "}": kind = .groupClose
            case "π": kind = .command("pi")
            case "θ": kind = .command("theta")
            case "∞": kind = .command("infty")
            default:
                if let greek = Greek.name(for: c) {
                    kind = .command(greek)
                } else {
                    throw MathError("Unexpected character “\(c)”", at: start..<index)
                }
            }
            tokens.append(Token(kind: kind, range: start..<index))
        }
        tokens.append(Token(kind: .end, range: chars.count..<chars.count))
        return tokens
    }

    // MARK: - Helpers

    private mutating func skipWhitespace() {
        while index < chars.count, chars[index].isWhitespace { index += 1 }
    }

    private func peekIsDigit(_ offset: Int) -> Bool {
        let i = index + offset
        return i < chars.count && chars[i].isASCII && chars[i].isNumber
    }

    private mutating func readNumber() -> String {
        var text = ""
        var seenDot = false
        while index < chars.count {
            let c = chars[index]
            if c.isASCII && c.isNumber {
                text.append(c)
            } else if c == "." && !seenDot && peekIsDigit(1) {
                seenDot = true
                text.append(c)
            } else {
                break
            }
            index += 1
        }
        return text
    }

    private func bareFunctionName(at position: Int) -> String? {
        // Only flag a name that starts a run of letters, e.g. "sin x" but not "a sin" inside "asin".
        if position > 0, chars[position - 1].isLetter || chars[position - 1] == "\\" { return nil }
        for name in Self.bareFunctionNames {
            let end = position + name.count
            guard end <= chars.count else { continue }
            if String(chars[position..<end]) == name {
                // "sinx" or "sin x" or "sin(" — all mean the function.
                return name
            }
        }
        return nil
    }

    /// Reads `\name` or a one-character control symbol. Returns nil for ignored commands.
    private mutating func readCommand() throws(MathError) -> Token? {
        let start = index
        index += 1  // backslash
        guard index < chars.count else {
            throw MathError("A command name must follow “\\”", at: start..<index)
        }
        let c = chars[index]
        if c.isASCII && c.isLetter {
            var name = ""
            while index < chars.count, chars[index].isASCII, chars[index].isLetter {
                name.append(chars[index])
                index += 1
            }
            if Self.ignoredCommands.contains(name) {
                // `\left.` / `\right.` are invisible delimiters.
                skipWhitespace()
                if (name == "left" || name == "right"), index < chars.count, chars[index] == "." {
                    index += 1
                }
                return nil
            }
            if Self.textCommands.contains(name) {
                return try readTextArgument(command: name, start: start)
            }
            let range = start..<index
            switch name {
            case "cdot": return Token(kind: .cdot, range: range)
            case "times": return Token(kind: .times, range: range)
            case "ast": return Token(kind: .star, range: range)
            case "div": return Token(kind: .slash, range: range)
            case "lbrace": return Token(kind: .open(.brace), range: range)
            case "rbrace": return Token(kind: .close(.brace), range: range)
            case "lfloor": return Token(kind: .open(.floor), range: range)
            case "rfloor": return Token(kind: .close(.floor), range: range)
            case "lceil": return Token(kind: .open(.ceil), range: range)
            case "rceil": return Token(kind: .close(.ceil), range: range)
            case "vert", "lvert", "rvert", "mid": return Token(kind: .bar, range: range)
            case "lparen": return Token(kind: .open(.paren), range: range)
            case "rparen": return Token(kind: .close(.paren), range: range)
            case "lbrack": return Token(kind: .open(.bracket), range: range)
            case "rbrack": return Token(kind: .close(.bracket), range: range)
            default: return Token(kind: .command(name), range: range)
            }
        }
        index += 1
        let range = start..<index
        switch c {
        case ",", ";", ":", "!", " ", ">", "\\":
            return nil  // spacing
        case "{": return Token(kind: .open(.brace), range: range)
        case "}": return Token(kind: .close(.brace), range: range)
        case "|": return Token(kind: .bar, range: range)
        default:
            throw MathError("Unknown command “\\\(c)”", at: range)
        }
    }

    private static let textCommands: Set<String> = ["operatorname", "mathrm", "text", "mathit", "textrm", "mathup"]

    /// `\operatorname{sgn}` → command "sgn"; `\mathrm{e}` → letter e.
    private mutating func readTextArgument(command: String, start: Int) throws(MathError) -> Token {
        skipWhitespace()
        guard index < chars.count, chars[index] == "{" else {
            throw MathError("\\\(command) needs a name in braces, e.g. \\\(command){sgn}", at: start..<index)
        }
        index += 1
        var name = ""
        while index < chars.count, chars[index] != "}" {
            if !chars[index].isWhitespace { name.append(chars[index]) }
            index += 1
        }
        guard index < chars.count else {
            throw MathError("Missing “}”", at: start..<index)
        }
        index += 1
        let range = start..<index
        if name.count == 1, let c = name.first, c.isASCII, c.isLetter {
            return Token(kind: .letter(c), range: range)
        }
        guard !name.isEmpty else { throw MathError("Empty name", at: range) }
        return Token(kind: .command(name), range: range)
    }
}

/// Greek letters: TeX names, Unicode characters and math-italic forms.
public enum Greek {
    /// TeX name → upright Unicode character.
    public static let letters: [String: Character] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ",
        "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    /// Unicode character → TeX name, for users who type Greek letters directly.
    public static func name(for character: Character) -> String? {
        letters.first(where: { $0.value == character })?.key
    }
}
