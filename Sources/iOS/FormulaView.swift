import SwiftUI
import UIKit

/// Displays a typeset formula. If the proposed width is smaller than the formula,
/// the formula is scaled down to fit. (The macOS counterpart is in Typesetter.swift.)
struct FormulaView: UIViewRepresentable {
    let box: MathBox
    var color: PlatformColor = .label

    func makeUIView(context: Context) -> FormulaUIView {
        FormulaUIView()
    }

    func updateUIView(_ view: FormulaUIView, context: Context) {
        view.box = box
        view.color = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FormulaUIView, context: Context) -> CGSize? {
        let natural = uiView.naturalSize
        guard let width = proposal.width, width > 0, width < natural.width else { return natural }
        let scale = max(0.35, width / natural.width)
        return CGSize(width: width, height: natural.height * scale)
    }
}

final class FormulaUIView: UIView {
    static let padding: CGFloat = 2

    var box = MathBox() {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    var color: PlatformColor = .label {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var naturalSize: CGSize {
        CGSize(width: ceil(box.width + 2 * Self.padding), height: ceil(box.height + 2 * Self.padding))
    }

    override var intrinsicContentSize: CGSize { naturalSize }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let natural = naturalSize
        let scale = natural.width > 0 ? min(1, bounds.width / natural.width) : 1
        context.saveGState()
        // UIKit's origin is at the top left; the typesetter draws with the origin at the bottom left.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        // Centre vertically, scale to fit horizontally.
        let drawnHeight = natural.height * scale
        context.translateBy(x: 0, y: (bounds.height - drawnHeight) / 2)
        context.scaleBy(x: scale, y: scale)
        box.draw(in: context, at: CGPoint(x: Self.padding, y: Self.padding + box.descent),
                 color: color.resolvedColor(with: traitCollection).cgColor)
        context.restoreGState()
    }
}
