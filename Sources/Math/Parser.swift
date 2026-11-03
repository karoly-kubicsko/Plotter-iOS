import Foundation

/// Recursive-descent parser for the LaTeX subset.
///
/// Grammar (lowest to highest precedence):
///
///     equation  := (lhs '=')? sum
///     sum       := signed (('+' | '-') signed)*
///     signed    := ('-' | '+') signed | product          -- -x^2 = -(x^2)
///     product   := power (('*' | \cdot | \times | '/') signedFactor | power)*
///                                                        -- juxtaposition = implicit ×
///     power     := postfix ('^' exponent)?
///     exponent  := ('-' | '+') exponent | scriptAtom ('^' exponent)?   -- right-assoc
///     postfix   := primary '!'*
///     primary   := number | letter ('_' scriptAtom)? | greek | \pi | \infty | \frac A B
///                | \sqrt ('[' sum ']')? A | '(' sum ')' | '{' sum '}' | '|' sum '|'
///                | function
///     function  := FUNC ('^' exponent | '_' scriptAtom)* ('(' sum ')' | bareArg)
///     bareArg   := '-' bareArg | power (power)*          -- stops at + - * / and at the next function
///     scriptAtom:= '{' sum '}' | '(' sum ')' | one digit | letter | greek | \frac … | \sqrt …
///
/// As in TeX, an unbraced superscript takes a single token: `x^23` is x²·3.
public struct Parser {
    private var tokens: [Token]
    private var pos = 0
    /// Number of `|…|` pairs currently open; decides whether a bar opens or closes.
    private var absDepth = 0

    private init(tokens: [Token]) {
        self.tokens = tokens
    }

    // MARK: - Public API

    /// Parses an expression without a left-hand side.
    public static func parseExpression(_ source: String) throws(MathError) -> Expr {
        var lexer = Lexer(source)
        var parser = Parser(tokens: try lexer.tokenize())
        guard parser.current.kind != .end else {
            throw MathError("Type a function, for example \\sin x", at: 0..<0)
        }
        let expr = try parser.parseSum()
        try parser.expectEnd()
        return expr
    }

    /// Parses a full input line (with optional `y =`, `z =`, `f(x) =`, `f(x,y) =`)
    /// and classifies it as a curve or a surface.
    public static func parseEquation(_ source: String) throws(MathError) -> Equation {
        var lexer = Lexer(source)
        let tokens = try lexer.tokenize()
        let equalsIndices = tokens.indices.filter { tokens[$0].kind == .equals }
        if equalsIndices.count > 1 {
            throw MathError("Only one “=” is allowed", at: tokens[equalsIndices[1]].range)
        }

        var lhs = LeftHandSide.none
        var rhsTokens = tokens
        if let eq = equalsIndices.first {
            lhs = try parseLeftHandSide(Array(tokens[..<eq]), equalsToken: tokens[eq])
            rhsTokens = Array(tokens[(eq + 1)...])
            if rhsTokens.first?.kind == .end {
                throw MathError("Type the right-hand side after “=”", at: tokens[eq].range)
            }
        } else if tokens.first?.kind == .end {
            throw MathError("Type a function, for example \\sin x", at: 0..<0)
        }

        var parser = Parser(tokens: rhsTokens)
        let rhs = try parser.parseSum()
        try parser.expectEnd()
        return try classify(lhs: lhs, rhs: rhs, source: source)
    }

    // MARK: - Left-hand side and classification

    private static func parseLeftHandSide(_ lhs: [Token], equalsToken: Token) throws(MathError) -> LeftHandSide {
        guard let first = lhs.first else {
            throw MathError("Type y, z, f(x) or f(x, y) before “=”", at: equalsToken.range)
        }
        let whole = first.range.lowerBound..<(lhs.last?.range.upperBound ?? first.range.upperBound)
        let help = "The left side must be y, z, f(x) or f(x, y)"

        func symbol(_ token: Token) -> Symbol? {
            switch token.kind {
            case .letter(let c): return Symbol(String(c))
            case .command(let name) where Greek.letters[name] != nil: return Symbol(name)
            default: return nil
            }
        }

        if lhs.count == 1, let s = symbol(first) {
            if s.name == "r" {
                throw MathError("Polar curves r = f(θ) are not supported yet", at: whole)
            }
            return .variable(s)
        }

        // name ( arg , arg ) — the name may carry a subscript: f_1(x)
        guard var name = symbol(lhs[0]) else { throw MathError(help, at: whole) }
        var i = 1
        if i + 1 < lhs.count, lhs[i].kind == .underscore {
            switch lhs[i + 1].kind {
            case .number(let t): name = Symbol(name.base, sub: t)
            case .letter(let c): name = Symbol(name.base, sub: String(c))
            default: throw MathError(help, at: whole)
            }
            i += 2
        }
        guard i < lhs.count, lhs[i].kind == .open(.paren) else { throw MathError(help, at: whole) }
        i += 1
        var args: [Symbol] = []
        while i < lhs.count {
            guard let arg = symbol(lhs[i]) else { throw MathError(help, at: whole) }
            args.append(arg)
            i += 1
            guard i < lhs.count else { throw MathError(help, at: whole) }
            if lhs[i].kind == .comma {
                i += 1
                continue
            }
            if lhs[i].kind == .close(.paren) {
                i += 1
                break
            }
            throw MathError(help, at: whole)
        }
        guard i == lhs.count, !args.isEmpty else { throw MathError(help, at: whole) }
        if args.count > 2 {
            throw MathError("Functions of more than two variables cannot be plotted", at: whole)
        }
        if Set(args).count != args.count {
            throw MathError("The arguments of \(name.displayName) must be different", at: whole)
        }
        return .function(name, args)
    }

    private static func classify(lhs: LeftHandSide, rhs: Expr, source: String) throws(MathError) -> Equation {
        let used = rhs.symbols
        let x = Symbol("x"), y = Symbol("y"), t = Symbol("t"), theta = Symbol("theta")
        let whole = 0..<source.count

        let arguments: [Symbol]
        switch lhs {
        case .variable(let v) where v == y:
            if used.contains(y) { throw MathError("y cannot appear on both sides of “=”", at: whole) }
            arguments = [x]
        case .variable(let v) where v == Symbol("z"):
            if used.contains(Symbol("z")) { throw MathError("z cannot appear on both sides of “=”", at: whole) }
            arguments = [x, y]
        case .variable(let v):
            throw MathError("Write y = … for a curve or z = … for a surface, not \(v.displayName) = …", at: whole)
        case .function(_, let args):
            arguments = args
        case .none:
            if used.contains(y) {
                arguments = [x, y]
            } else if used.contains(x) {
                arguments = [x]
            } else if used.contains(t) {
                arguments = [t]
            } else if used.contains(theta) {
                arguments = [theta]
            } else {
                arguments = [x]
            }
        }

        let parameters = used.filter { !arguments.contains($0) }
        return Equation(
            lhs: lhs, rhs: rhs,
            kind: arguments.count == 2 ? .surface : .curve,
            arguments: arguments, parameters: parameters)
    }

    // MARK: - Token helpers

    private var current: Token { tokens[pos] }

    private mutating func advance() {
        if pos < tokens.count - 1 { pos += 1 }
    }

    private func describe(_ kind: TokenKind) -> String {
        switch kind {
        case .number(let t): return t
        case .letter(let c): return String(c)
        case .command(let n): return "\\" + n
        case .plus: return "+"
        case .minus: return "−"
        case .star: return "*"
        case .slash: return "/"
        case .caret: return "^"
        case .underscore: return "_"
        case .equals: return "="
        case .comma: return ","
        case .bang: return "!"
        case .bar: return "|"
        case .cdot: return "\\cdot"
        case .times: return "\\times"
        case .open(let d): return Self.openText(d)
        case .close(let d): return Self.closeText(d)
        case .groupOpen: return "{"
        case .groupClose: return "}"
        case .end: return "end of input"
        }
    }

    private static func openText(_ d: Delimiter) -> String {
        switch d {
        case .paren: "("
        case .bracket: "["
        case .brace: "\\{"
        case .floor: "\\lfloor"
        case .ceil: "\\lceil"
        }
    }

    private static func closeText(_ d: Delimiter) -> String {
        switch d {
        case .paren: ")"
        case .bracket: "]"
        case .brace: "\\}"
        case .floor: "\\rfloor"
        case .ceil: "\\rceil"
        }
    }

    private func unexpected() -> MathError {
        switch current.kind {
        case .end:
            let r = pos > 0 ? tokens[pos - 1].range : current.range
            return MathError("The expression is incomplete", at: r)
        case .close(let d):
            return MathError("Unmatched “\(Self.closeText(d))”", at: current.range)
        case .groupClose:
            return MathError("Unmatched “}”", at: current.range)
        default:
            return MathError("Unexpected “\(describe(current.kind))”", at: current.range)
        }
    }

    private mutating func expectEnd() throws(MathError) {
        guard current.kind == .end else { throw unexpected() }
    }

    private mutating func expectGroupClose(opening: Token) throws(MathError) {
        guard current.kind == .groupClose else {
            if current.kind == .end { throw MathError("Missing “}”", at: opening.range) }
            throw unexpected()
        }
        advance()
    }

    /// Can the current token begin a factor of an implicit product?
    private func startsFactor() -> Bool {
        switch current.kind {
        case .number, .letter, .open, .groupOpen, .command: return true
        case .bar: return absDepth == 0
        default: return false
        }
    }

    private func isFunctionCommand() -> Bool {
        if case .command(let name) = current.kind { return MathFunction(command: name) != nil }
        return false
    }

    // MARK: - Grammar

    private mutating func parseSum() throws(MathError) -> Expr {
        var lhs = try parseSigned()
        while true {
            switch current.kind {
            case .plus:
                advance()
                lhs = .binary(.add, lhs, try parseSigned())
            case .minus:
                advance()
                lhs = .binary(.subtract, lhs, try parseSigned())
            default:
                return lhs
            }
        }
    }

    private mutating func parseSigned() throws(MathError) -> Expr {
        switch current.kind {
        case .minus:
            advance()
            return .negate(try parseSigned())
        case .plus:
            advance()
            return try parseSigned()
        default:
            return try parseProduct()
        }
    }

    private mutating func parseProduct() throws(MathError) -> Expr {
        var lhs = try parsePower()
        while true {
            switch current.kind {
            case .star:
                advance()
                lhs = .binary(.multiply(.star), lhs, try parseSignedFactor())
            case .cdot:
                advance()
                lhs = .binary(.multiply(.cdot), lhs, try parseSignedFactor())
            case .times:
                advance()
                lhs = .binary(.multiply(.times), lhs, try parseSignedFactor())
            case .slash:
                advance()
                lhs = .binary(.divide(.slash), lhs, try parseSignedFactor())
            default:
                guard startsFactor() else { return lhs }
                if case .number = current.kind, pos > 0, case .number = tokens[pos - 1].kind {
                    throw MathError("Two numbers in a row; use \\cdot to multiply them", at: current.range)
                }
                lhs = .binary(.multiply(.implicit), lhs, try parsePower())
            }
        }
    }

    /// A factor after an explicit operator may carry a sign: `2 \cdot -x`.
    private mutating func parseSignedFactor() throws(MathError) -> Expr {
        switch current.kind {
        case .minus:
            advance()
            return .negate(try parseSignedFactor())
        case .plus:
            advance()
            return try parseSignedFactor()
        default:
            return try parsePower()
        }
    }

    private mutating func parsePower() throws(MathError) -> Expr {
        let base = try parsePostfix()
        if current.kind == .caret {
            let caret = current
            advance()
            return .binary(.power, base, try parseExponent(after: caret))
        }
        if current.kind == .underscore {
            throw MathError("A subscript can only follow a letter, e.g. a_1", at: current.range)
        }
        return base
    }

    private mutating func parseExponent(after caret: Token) throws(MathError) -> Expr {
        switch current.kind {
        case .minus:
            advance()
            return .negate(try parseExponent(after: caret))
        case .plus:
            advance()
            return try parseExponent(after: caret)
        default:
            let atom = try parseScriptAtom(after: caret, role: "exponent")
            if current.kind == .caret {
                let next = current
                advance()
                return .binary(.power, atom, try parseExponent(after: next))
            }
            return atom
        }
    }

    private mutating func parsePostfix() throws(MathError) -> Expr {
        var e = try parsePrimary()
        while current.kind == .bang {
            advance()
            e = .factorial(e)
        }
        return e
    }

    /// The argument of a script or a `\frac`/`\sqrt` without braces: a braced group
    /// or a single token (one digit of a number).
    private mutating func parseScriptAtom(after owner: Token, role: String) throws(MathError) -> Expr {
        let token = current
        switch token.kind {
        case .groupOpen:
            advance()
            if current.kind == .groupClose {
                throw MathError("Empty \(role) “{}”", at: token.range.lowerBound..<current.range.upperBound)
            }
            let e = try parseSum()
            try expectGroupClose(opening: token)
            return e
        case .open:
            return try parsePrimary()
        case .number(let text):
            if text.count > 1, let first = text.first, first != "." {
                // Split "23" into "2" (the script) and "3" (left for the caller).
                let lo = token.range.lowerBound
                tokens[pos] = Token(kind: .number(String(text.dropFirst())), range: (lo + 1)..<token.range.upperBound)
                let digit = String(first)
                return .number(Double(digit) ?? 0, digit)
            }
            advance()
            return .number(Double(text) ?? .nan, text)
        case .letter(let c):
            advance()
            return c == "e" ? .constant(.e) : .variable(Symbol(String(c)))
        case .command(let name):
            if MathFunction(command: name) != nil {
                throw MathError("Put a function in a \(role) inside braces: {\\\(name) …}", at: token.range)
            }
            return try parsePrimary()
        case .end:
            throw MathError("Missing \(role) after “\(describe(owner.kind))”", at: owner.range)
        default:
            throw MathError("Missing \(role) after “\(describe(owner.kind))”", at: owner.range)
        }
    }

    private mutating func parseSubscriptText(after underscore: Token) throws(MathError) -> String {
        let token = current
        switch token.kind {
        case .number(let text):
            if text.count > 1, let first = text.first, first != "." {
                tokens[pos] = Token(kind: .number(String(text.dropFirst())),
                                    range: (token.range.lowerBound + 1)..<token.range.upperBound)
                return String(first)
            }
            advance()
            return text
        case .letter(let c):
            advance()
            return String(c)
        case .groupOpen:
            advance()
            var text = ""
            while true {
                switch current.kind {
                case .number(let t): text += t
                case .letter(let c): text.append(c)
                case .command(let n) where Greek.letters[n] != nil: text += n
                case .groupClose:
                    advance()
                    if text.isEmpty { throw MathError("Empty subscript", at: token.range) }
                    return text
                case .end:
                    throw MathError("Missing “}”", at: token.range)
                default:
                    throw MathError("A subscript may contain only letters and digits", at: current.range)
                }
                advance()
            }
        default:
            throw MathError("Missing subscript after “_”", at: underscore.range)
        }
    }

    private mutating func parseSymbol(base: String) throws(MathError) -> Symbol {
        guard current.kind == .underscore else { return Symbol(base) }
        let underscore = current
        advance()
        return Symbol(base, sub: try parseSubscriptText(after: underscore))
    }

    private mutating func parsePrimary() throws(MathError) -> Expr {
        let token = current
        switch token.kind {
        case .number(let text):
            advance()
            return .number(Double(text) ?? .nan, text)

        case .letter(let c):
            advance()
            let symbol = try parseSymbol(base: String(c))
            if symbol == Symbol("e") { return .constant(.e) }
            return .variable(symbol)

        case .command(let name):
            return try parseCommand(name, token: token)

        case .open(let d):
            advance()
            let savedAbs = absDepth
            absDepth = 0
            if current.kind == .close(d) {
                throw MathError("Empty “\(Self.openText(d)) \(Self.closeText(d))”", at: token.range.lowerBound..<current.range.upperBound)
            }
            let e = try parseSum()
            absDepth = savedAbs
            guard current.kind == .close(d) else {
                if current.kind == .end { throw MathError("Missing “\(Self.closeText(d))”", at: token.range) }
                throw unexpected()
            }
            advance()
            return .group(e, d)

        case .groupOpen:
            advance()
            let savedAbs = absDepth
            absDepth = 0
            if current.kind == .groupClose {
                throw MathError("Empty group “{}”", at: token.range.lowerBound..<current.range.upperBound)
            }
            let e = try parseSum()
            absDepth = savedAbs
            try expectGroupClose(opening: token)
            return e

        case .bar:
            advance()
            absDepth += 1
            if current.kind == .bar {
                throw MathError("Empty “| |”", at: token.range.lowerBound..<current.range.upperBound)
            }
            let e = try parseSum()
            guard current.kind == .bar else {
                if current.kind == .end { throw MathError("Missing closing “|”", at: token.range) }
                throw unexpected()
            }
            absDepth -= 1
            advance()
            return .abs(e)

        default:
            throw unexpected()
        }
    }

    private mutating func parseCommand(_ name: String, token: Token) throws(MathError) -> Expr {
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            advance()
            let numerator = try parseScriptAtom(after: token, role: "numerator")
            let denominator = try parseScriptAtom(after: token, role: "denominator")
            return .binary(.divide(.fraction), numerator, denominator)

        case "sqrt":
            advance()
            var index: Expr?
            if current.kind == .open(.bracket) {
                let open = current
                advance()
                index = try parseSum()
                guard current.kind == .close(.bracket) else {
                    throw MathError("Missing “]” after the root index", at: open.range)
                }
                advance()
            }
            let radicand = try parseScriptAtom(after: token, role: "radicand")
            return .root(radicand, index: index)

        case "pi":
            advance()
            return .constant(.pi)

        case "infty", "infin":
            advance()
            return .constant(.infinity)

        default:
            if Greek.letters[name] != nil {
                advance()
                return .variable(try parseSymbol(base: name))
            }
            if let function = MathFunction(command: name) {
                return try parseFunction(function, token: token)
            }
            throw MathError("Unknown command “\\\(name)”", at: token.range)
        }
    }

    private mutating func parseFunction(_ function: MathFunction, token: Token) throws(MathError) -> Expr {
        advance()
        var power: Expr?
        var base: Expr?
        while true {
            if current.kind == .caret, power == nil {
                let caret = current
                advance()
                power = try parseExponent(after: caret)
            } else if current.kind == .underscore, base == nil {
                guard function == .log else {
                    throw MathError("Only \\log takes a base, e.g. \\log_{2} x", at: current.range)
                }
                let underscore = current
                advance()
                base = try parseScriptAtom(after: underscore, role: "base")
            } else {
                break
            }
        }

        let name = "\\" + function.rawValue
        if function.takesArgumentList {
            guard current.kind == .open(.paren) else {
                throw MathError("\(name) needs a list in parentheses, e.g. \(name)(x, 1)", at: token.range)
            }
            let open = current
            advance()
            let savedAbs = absDepth
            absDepth = 0
            var args = [try parseSum()]
            while current.kind == .comma {
                advance()
                args.append(try parseSum())
            }
            absDepth = savedAbs
            guard current.kind == .close(.paren) else {
                if current.kind == .end { throw MathError("Missing “)”", at: open.range) }
                throw unexpected()
            }
            advance()
            return .call(function, args, power: power, base: base)
        }

        if case .open = current.kind {
            let argument = try parsePrimary()
            return .call(function, [argument], power: power, base: base)
        }
        let argument = try parseBareArgument(function: name, token: token)
        return .call(function, [argument], power: power, base: base)
    }

    /// `\sin 2x` → sin(2x). The argument ends at + − · / or at the next function.
    private mutating func parseBareArgument(function name: String, token: Token) throws(MathError) -> Expr {
        if current.kind == .minus {
            advance()
            return .negate(try parseBareArgument(function: name, token: token))
        }
        guard startsFactor() else {
            throw MathError("\(name) needs an argument, e.g. \(name) x", at: token.range)
        }
        var e = try parsePower()
        while startsFactor(), !isFunctionCommand() {
            if case .number = current.kind, case .number = tokens[pos - 1].kind {
                throw MathError("Two numbers in a row; use \\cdot to multiply them", at: current.range)
            }
            e = .binary(.multiply(.implicit), e, try parsePower())
        }
        return e
    }
}
