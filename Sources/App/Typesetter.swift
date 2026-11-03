import AppKit
import CoreText

// A small TeX-style typesetter for the formulas the parser understands. It lays out
// the syntax tree (which keeps how the user wrote fractions, brackets and products)
// with TeX's atom classes, inter-atom spacing, script and fraction rules, and draws
// with CoreText in the STIX Two fonts that ship with macOS.

// MARK: - Boxes

/// A laid-out formula: drawing primitives in a y-up coordinate system whose origin
/// is the left end of the baseline.
struct MathBox {
    var width: CGFloat = 0
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    /// Extra room after an italic letter so a superscript clears its overhang.
    var italicCorrection: CGFloat = 0
    fileprivate var texts: [(line: CTLine, origin: CGPoint)] = []
    fileprivate var strokes: [(path: CGPath, width: CGFloat)] = []
    fileprivate var fills: [CGPath] = []

    var height: CGFloat { ascent + descent }

    mutating func append(_ other: MathBox, at offset: CGPoint) {
        for t in other.texts {
            texts.append((t.line, CGPoint(x: t.origin.x + offset.x, y: t.origin.y + offset.y)))
        }
        var transform = CGAffineTransform(translationX: offset.x, y: offset.y)
        for s in other.strokes {
            if let moved = s.path.copy(using: &transform) { strokes.append((moved, s.width)) }
        }
        for f in other.fills {
            if let moved = f.copy(using: &transform) { fills.append(moved) }
        }
        width = max(width, offset.x + other.width)
        ascent = max(ascent, other.ascent + offset.y)
        descent = max(descent, other.descent - offset.y)
    }

    /// Draws the box with its baseline starting at `origin` in a y-up context.
    func draw(in context: CGContext, at origin: CGPoint, color: CGColor) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.setFillColor(color)
        context.setStrokeColor(color)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.textMatrix = .identity
        for t in texts {
            context.textPosition = t.origin
            CTLineDraw(t.line, context)
        }
        for s in strokes {
            context.addPath(s.path)
            context.setLineWidth(s.width)
            context.strokePath()
        }
        for f in fills {
            context.addPath(f)
            context.fillPath()
        }
        context.restoreGState()
    }
}

// MARK: - Fonts

@MainActor
enum MathFonts {
    private static var cache: [String: CTFont] = [:]

    static func upright(_ size: CGFloat) -> CTFont {
        font(["STIXTwoText", "TimesNewRomanPSMT"], size)
    }

    static func italic(_ size: CGFloat) -> CTFont {
        font(["STIXTwoText-Italic", "TimesNewRomanPS-ItalicMT"], size)
    }

    private static func font(_ names: [String], _ size: CGFloat) -> CTFont {
        let key = "\(names[0])@\(size)"
        if let cached = cache[key] { return cached }
        var chosen: CTFont?
        for name in names {
            let candidate = CTFontCreateWithName(name as CFString, size, nil)
            if (CTFontCopyPostScriptName(candidate) as String) == name {
                chosen = candidate
                break
            }
        }
        let font = chosen ?? CTFontCreateWithName("Times New Roman" as CFString, size, nil)
        cache[key] = font
        return font
    }
}

// MARK: - Styles and atoms

/// TeX's four styles; scripts and fractions step down through them.
struct MathStyle {
    enum Level: Int { case display, text, script, scriptScript }

    let level: Level
    let base: CGFloat

    var size: CGFloat {
        switch level {
        case .display, .text: base
        case .script: base * 0.71
        case .scriptScript: base * 0.55
        }
    }

    var isTight: Bool { level.rawValue >= Level.script.rawValue }
    var script: MathStyle { MathStyle(level: level.rawValue <= 1 ? .script : .scriptScript, base: base) }

    var fractionPart: MathStyle {
        switch level {
        case .display: MathStyle(level: .text, base: base)
        case .text: MathStyle(level: .script, base: base)
        default: MathStyle(level: .scriptScript, base: base)
        }
    }

    /// One math unit, 1/18 em.
    var mu: CGFloat { size / 18 }
    /// Fraction-bar and radical thickness.
    var rule: CGFloat { max(0.8, base * 0.045) }
    /// Height of the math axis (centre of fraction bars, minus signs, brackets).
    var axis: CGFloat { size * 0.25 }
}

enum AtomClass: Int {
    case ord, op, bin, rel, open, close, punct, inner
}

struct Atom {
    var box: MathBox
    /// Class seen by the neighbour on the left and on the right.
    var left: AtomClass
    var right: AtomClass

    init(_ box: MathBox, _ cls: AtomClass) {
        self.box = box
        left = cls
        right = cls
    }

    init(_ box: MathBox, left: AtomClass, right: AtomClass) {
        self.box = box
        self.left = left
        self.right = right
    }
}

/// TeX's inter-atom spacing table (TeXbook ch. 18). 1 = thin space; 2 = medium,
/// 3 = thick and 4 = thin, but only in display and text style.
private let spacingTable: [[Int]] = [
    //  ord op bin rel open close punct inner
    [0, 1, 2, 3, 0, 0, 0, 4],  // ord
    [1, 1, 0, 3, 0, 0, 0, 4],  // op
    [2, 2, 0, 0, 2, 0, 0, 2],  // bin
    [3, 3, 0, 0, 3, 0, 0, 3],  // rel
    [0, 0, 0, 0, 0, 0, 0, 0],  // open
    [0, 1, 2, 3, 0, 0, 0, 4],  // close
    [4, 4, 0, 4, 4, 4, 4, 4],  // punct
    [4, 1, 2, 3, 4, 0, 4, 4],  // inner
]

private func spacing(_ left: AtomClass, _ right: AtomClass, _ style: MathStyle) -> CGFloat {
    switch spacingTable[left.rawValue][right.rawValue] {
    case 1: return 3 * style.mu
    case 2: return style.isTight ? 0 : 4 * style.mu
    case 3: return style.isTight ? 0 : 5 * style.mu
    case 4: return style.isTight ? 0 : 3 * style.mu
    default: return 0
    }
}

private enum DelimiterShape {
    case paren, bracket, brace, floor, ceil, bar

    init(_ d: Delimiter) {
        switch d {
        case .paren: self = .paren
        case .bracket: self = .bracket
        case .brace: self = .brace
        case .floor: self = .floor
        case .ceil: self = .ceil
        }
    }

    var glyphs: (String, String) {
        switch self {
        case .paren: ("(", ")")
        case .bracket: ("[", "]")
        case .brace: ("{", "}")
        case .floor: ("⌊", "⌋")
        case .ceil: ("⌈", "⌉")
        case .bar: ("|", "|")
        }
    }
}

// MARK: - Typesetter

@MainActor
struct Typesetter {
    let size: CGFloat

    init(size: CGFloat) {
        self.size = size
    }

    /// Typesets `lhs = rhs`.
    func layout(lhs: LeftHandSide, rhs: Expr) -> MathBox {
        let style = MathStyle(level: .display, base: size)
        var atoms: [Atom] = []
        switch lhs {
        case .none:
            break
        case .variable(let s):
            atoms.append(Atom(symbol(s, style), .ord))
        case .function(let name, let args):
            atoms.append(Atom(symbol(name, style), .ord))
            var list: [Atom] = []
            for (i, a) in args.enumerated() {
                if i > 0 { list.append(Atom(text(",", MathFonts.upright(style.size)), .punct)) }
                list.append(Atom(symbol(a, style), .ord))
            }
            atoms.append(delimited(pack(list, style).box, .paren, style))
        }
        if !atoms.isEmpty {
            atoms.append(Atom(text("=", MathFonts.upright(style.size)), .rel))
        }
        atoms += self.atoms(rhs, style)
        return pack(atoms, style).box
    }

    // MARK: Building blocks

    private func text(_ string: String, _ font: CTFont, italic: Bool = false) -> MathBox {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        var box = MathBox()
        box.width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        box.ascent = max(bounds.maxY, 0)
        box.descent = max(-bounds.minY, 0)
        box.texts = [(line, .zero)]
        if italic { box.italicCorrection = CTFontGetSize(font) * 0.07 }
        return box
    }

    private func pack(_ atoms: [Atom], _ style: MathStyle) -> Atom {
        var box = MathBox()
        var x: CGFloat = 0
        var previous: AtomClass?
        for atom in atoms {
            if let previous { x += spacing(previous, atom.left, style) }
            box.append(atom.box, at: CGPoint(x: x, y: 0))
            x += atom.box.width
            previous = atom.right
        }
        box.width = x
        box.italicCorrection = atoms.last?.box.italicCorrection ?? 0
        return Atom(box, left: atoms.first?.left ?? .ord, right: atoms.last?.right ?? .ord)
    }

    private func symbol(_ s: Symbol, _ style: MathStyle) -> MathBox {
        let glyph = Greek.letters[s.base].map(String.init) ?? s.base
        let uprightGreek = s.isGreek && (s.base.first?.isUppercase ?? false)
        let base = uprightGreek
            ? text(glyph, MathFonts.upright(style.size))
            : text(glyph, MathFonts.italic(style.size), italic: true)
        guard let sub = s.subscriptText else { return base }
        let ss = style.script
        let subBox: MathBox
        if let greek = Greek.letters[sub] {
            subBox = text(String(greek), MathFonts.italic(ss.size), italic: true)
        } else if sub.allSatisfy(\.isNumber) || sub.count > 1 {
            subBox = text(sub, MathFonts.upright(ss.size))
        } else {
            subBox = text(sub, MathFonts.italic(ss.size), italic: true)
        }
        return scripts(Atom(base, .ord), sup: nil, sub: subBox, style).box
    }

    private func scripts(_ base: Atom, sup: MathBox?, sub: MathBox?, _ style: MathStyle) -> Atom {
        let box = base.box
        let x = box.width
        let scriptSize = style.script.size
        var supShift: CGFloat = 0
        var subShift: CGFloat = 0
        if let sup {
            supShift = max(style.size * (style.level == .display ? 0.42 : 0.38),
                           box.ascent - scriptSize * 0.38,
                           sup.descent + style.size * 0.12)
        }
        if let sub {
            subShift = max(style.size * 0.17, box.descent + scriptSize * 0.1, sub.ascent - style.size * 0.36)
        }
        if let sup, let sub {
            let gap = (supShift - sup.descent) - (sub.ascent - subShift)
            let minimum = style.rule * 4
            if gap < minimum { subShift += minimum - gap }
        }
        var result = box
        result.italicCorrection = 0
        var end = x
        if let sup {
            result.append(sup, at: CGPoint(x: x + box.italicCorrection, y: supShift))
            end = max(end, x + box.italicCorrection + sup.width)
        }
        if let sub {
            result.append(sub, at: CGPoint(x: x, y: -subShift))
            end = max(end, x + sub.width)
        }
        result.width = end + style.size * 0.04
        return Atom(result, left: base.left, right: base.right)
    }

    private func fraction(_ numerator: Expr, _ denominator: Expr, _ style: MathStyle) -> Atom {
        let part = style.fractionPart
        let num = pack(atoms(numerator, part), part).box
        let den = pack(atoms(denominator, part), part).box
        let t = style.rule
        let axis = style.axis
        let gap = style.level == .display ? 2.4 * t : 1.4 * t
        let pad = style.size * 0.1
        let barWidth = max(num.width, den.width) + 2 * pad
        let side = style.size * 0.06

        var box = MathBox()
        box.append(num, at: CGPoint(x: side + (barWidth - num.width) / 2, y: axis + t / 2 + gap + num.descent))
        box.append(den, at: CGPoint(x: side + (barWidth - den.width) / 2, y: axis - t / 2 - gap - den.ascent))
        box.fills.append(CGPath(rect: CGRect(x: side, y: axis - t / 2, width: barWidth, height: t), transform: nil))
        box.width = barWidth + 2 * side
        return Atom(box, .inner)
    }

    private func radical(_ radicand: Expr, index: Expr?, _ style: MathStyle) -> Atom {
        let content = pack(atoms(radicand, style), style).box
        let t = style.rule
        let gap = style.size * (style.level == .display ? 0.13 : 0.09)
        let top = max(content.ascent, style.size * 0.5) + gap
        let bottom = -(max(content.descent, 0) + style.size * 0.06)
        let signWidth = style.size * 0.58

        var indexShift: CGFloat = 0
        var indexBox: MathBox?
        if let index {
            let ss = MathStyle(level: .scriptScript, base: style.base)
            let b = pack(atoms(index, ss), ss).box
            indexShift = max(0, b.width - signWidth * 0.5)
            indexBox = b
        }

        var box = MathBox()
        let x0 = indexShift
        let tickY = bottom + (top - bottom) * 0.42
        let hook = CGMutablePath()
        hook.move(to: CGPoint(x: x0 + signWidth * 0.06, y: tickY - style.size * 0.03))
        hook.addLine(to: CGPoint(x: x0 + signWidth * 0.24, y: tickY + style.size * 0.05))
        box.strokes.append((hook as CGPath, t * 1.1))
        let down = CGMutablePath()
        down.move(to: CGPoint(x: x0 + signWidth * 0.24, y: tickY + style.size * 0.05))
        down.addLine(to: CGPoint(x: x0 + signWidth * 0.5, y: bottom))
        box.strokes.append((down as CGPath, t * 2.1))
        let rise = CGMutablePath()
        rise.move(to: CGPoint(x: x0 + signWidth * 0.5, y: bottom))
        rise.addLine(to: CGPoint(x: x0 + signWidth, y: top))
        rise.addLine(to: CGPoint(x: x0 + signWidth + content.width + style.size * 0.08, y: top))
        box.strokes.append((rise as CGPath, t))

        if let indexBox {
            box.append(indexBox, at: CGPoint(x: x0 + signWidth * 0.5 - indexBox.width,
                                             y: tickY + style.size * 0.12 + indexBox.descent))
        }
        box.append(content, at: CGPoint(x: x0 + signWidth + style.size * 0.04, y: 0))
        box.ascent = max(box.ascent, top + t)
        box.descent = max(box.descent, -bottom + t)
        box.width = x0 + signWidth + content.width + style.size * 0.14
        return Atom(box, .ord)
    }

    private func delimited(_ content: MathBox, _ shape: DelimiterShape, _ style: MathStyle) -> Atom {
        let axis = style.axis
        let half = max(content.ascent - axis, content.descent + axis) + style.size * 0.06
        let gap = style.size * 0.03
        var box = MathBox()

        if 2 * half <= style.size * 1.2 {
            let font = MathFonts.upright(style.size)
            let (open, close) = shape.glyphs
            let l = text(open, font)
            let r = text(close, font)
            box.append(l, at: .zero)
            box.append(content, at: CGPoint(x: l.width + gap, y: 0))
            box.append(r, at: CGPoint(x: l.width + content.width + 2 * gap, y: 0))
            box.width = l.width + content.width + 2 * gap + r.width
            return Atom(box, left: .open, right: .close)
        }

        let top = axis + half
        let bottom = axis - half
        let width = style.size * (shape == .bar ? 0.2 : 0.3) + half * 0.06
        let l = delimiterBox(shape, isLeft: true, top: top, bottom: bottom, width: width, style)
        let r = delimiterBox(shape, isLeft: false, top: top, bottom: bottom, width: width, style)
        box.append(l, at: .zero)
        box.append(content, at: CGPoint(x: width + gap, y: 0))
        box.append(r, at: CGPoint(x: width + content.width + 2 * gap, y: 0))
        box.width = 2 * width + content.width + 2 * gap
        return Atom(box, left: .open, right: .close)
    }

    /// A stretchy delimiter drawn as a path.
    private func delimiterBox(_ shape: DelimiterShape, isLeft: Bool, top: CGFloat, bottom: CGFloat,
                              width: CGFloat, _ style: MathStyle) -> MathBox {
        let t = style.rule
        func x(_ v: CGFloat) -> CGFloat { isLeft ? v : width - v }
        let inner = width * 0.82   // the end of the delimiter nearer the content
        let outer = width * 0.22
        let mid = (top + bottom) / 2
        var box = MathBox()
        box.width = width
        box.ascent = top
        box.descent = -bottom

        switch shape {
        case .paren:
            let thickness = max(t * 1.8, style.size * 0.055)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x(inner), y: top))
            p.addQuadCurve(to: CGPoint(x: x(inner), y: bottom), control: CGPoint(x: x(outer - width * 0.25), y: mid))
            p.addQuadCurve(to: CGPoint(x: x(inner), y: top),
                           control: CGPoint(x: x(outer - width * 0.25 + 2 * thickness), y: mid))
            p.closeSubpath()
            box.fills.append(p)
        case .bracket, .floor, .ceil:
            let p = CGMutablePath()
            let hasTop = shape != .floor
            let hasBottom = shape != .ceil
            if hasTop {
                p.move(to: CGPoint(x: x(inner), y: top))
                p.addLine(to: CGPoint(x: x(outer), y: top))
            } else {
                p.move(to: CGPoint(x: x(outer), y: top))
            }
            p.addLine(to: CGPoint(x: x(outer), y: bottom))
            if hasBottom { p.addLine(to: CGPoint(x: x(inner), y: bottom)) }
            box.strokes.append((p as CGPath, t * 1.3))
        case .bar:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: width / 2, y: top))
            p.addLine(to: CGPoint(x: width / 2, y: bottom))
            box.strokes.append((p as CGPath, t * 1.3))
        case .brace:
            let q = min((top - bottom) * 0.12, width)
            let xm = x((inner + outer) / 2)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x(inner), y: top))
            p.addQuadCurve(to: CGPoint(x: xm, y: top - q), control: CGPoint(x: xm, y: top))
            p.addLine(to: CGPoint(x: xm, y: mid + q))
            p.addQuadCurve(to: CGPoint(x: x(outer * 0.3), y: mid), control: CGPoint(x: xm, y: mid))
            p.addQuadCurve(to: CGPoint(x: xm, y: mid - q), control: CGPoint(x: xm, y: mid))
            p.addLine(to: CGPoint(x: xm, y: bottom + q))
            p.addQuadCurve(to: CGPoint(x: x(inner), y: bottom), control: CGPoint(x: xm, y: bottom))
            box.strokes.append((p as CGPath, t * 1.3))
        }
        return box
    }

    // MARK: Expressions

    private func atoms(_ expr: Expr, _ style: MathStyle) -> [Atom] {
        let upright = MathFonts.upright(style.size)
        switch expr {
        case .number(_, let text):
            return [Atom(self.text(text, upright), .ord)]

        case .constant(let c):
            switch c {
            case .e: return [Atom(text("e", MathFonts.italic(style.size), italic: true), .ord)]
            case .pi: return [Atom(text("π", MathFonts.italic(style.size), italic: true), .ord)]
            case .infinity: return [Atom(text("∞", upright), .ord)]
            }

        case .variable(let s):
            return [Atom(symbol(s, style), .ord)]

        case .negate(let x):
            return [Atom(text("−", upright), .ord)] + atoms(x, style)

        case .binary(let op, let l, let r):
            switch op {
            case .add:
                return atoms(l, style) + [Atom(text("+", upright), .bin)] + atoms(r, style)
            case .subtract:
                return atoms(l, style) + [Atom(text("−", upright), .bin)] + atoms(r, style)
            case .multiply(let m):
                let symbol: String
                switch m {
                case .implicit: return atoms(l, style) + atoms(r, style)
                case .cdot: symbol = "⋅"
                case .times: symbol = "×"
                case .star: symbol = "∗"
                }
                return atoms(l, style) + [Atom(text(symbol, upright), .bin)] + atoms(r, style)
            case .divide(.slash):
                return atoms(l, style) + [Atom(text("/", upright), .ord)] + atoms(r, style)
            case .divide(.fraction):
                return [fraction(l, r, style)]
            case .power:
                let base = pack(atoms(l, style), style)
                let script = style.script
                let sup = pack(atoms(r, script), script).box
                return [scripts(base, sup: sup, sub: nil, style)]
            }

        case .call(let f, let args, let power, let base):
            var name = Atom(text(f.rawValue, upright), .op)
            if power != nil || base != nil {
                let script = style.script
                name = scripts(name,
                               sup: power.map { pack(atoms($0, script), script).box },
                               sub: base.map { pack(atoms($0, script), script).box },
                               style)
            }
            if f.takesArgumentList {
                var list: [Atom] = []
                for (i, a) in args.enumerated() {
                    if i > 0 { list.append(Atom(text(",", upright), .punct)) }
                    list += atoms(a, style)
                }
                return [name, delimited(pack(list, style).box, .paren, style)]
            }
            return [name] + atoms(args[0], style)

        case .root(let x, let index):
            return [radical(x, index: index, style)]

        case .abs(let x):
            return [delimited(pack(atoms(x, style), style).box, .bar, style)]

        case .group(let x, let d):
            return [delimited(pack(atoms(x, style), style).box, DelimiterShape(d), style)]

        case .factorial(let x):
            return atoms(x, style) + [Atom(text("!", upright), .close)]
        }
    }
}

// MARK: - SwiftUI view

/// Displays a typeset formula. If the proposed width is smaller than the formula,
/// the formula is scaled down to fit.
struct FormulaView: NSViewRepresentable {
    let box: MathBox
    var color: NSColor = .labelColor

    func makeNSView(context: Context) -> FormulaNSView {
        FormulaNSView()
    }

    func updateNSView(_ view: FormulaNSView, context: Context) {
        view.box = box
        view.color = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FormulaNSView, context: Context) -> CGSize? {
        let natural = nsView.naturalSize
        guard let width = proposal.width, width > 0, width < natural.width else { return natural }
        let scale = max(0.35, width / natural.width)
        return CGSize(width: width, height: natural.height * scale)
    }
}

final class FormulaNSView: NSView {
    static let padding: CGFloat = 2

    var box = MathBox() {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var color: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    var naturalSize: CGSize {
        CGSize(width: ceil(box.width + 2 * Self.padding), height: ceil(box.height + 2 * Self.padding))
    }

    override var intrinsicContentSize: NSSize { naturalSize }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let natural = naturalSize
        let scale = natural.width > 0 ? min(1, bounds.width / natural.width) : 1
        context.saveGState()
        // Centre vertically, scale to fit horizontally.
        let drawnHeight = natural.height * scale
        context.translateBy(x: 0, y: (bounds.height - drawnHeight) / 2)
        context.scaleBy(x: scale, y: scale)
        // AppKit makes the view's appearance current while drawing, so dynamic
        // colours such as labelColor resolve for light or dark mode here.
        box.draw(in: context, at: CGPoint(x: Self.padding, y: Self.padding + box.descent), color: color.cgColor)
        context.restoreGState()
    }
}
