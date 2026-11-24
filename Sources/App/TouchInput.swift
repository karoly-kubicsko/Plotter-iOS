import SwiftUI
import UIKit

/// Transparent UIKit layer that turns touches into pan, zoom and read-out callbacks for
/// the 2D graph: a one- or two-finger drag pans, pinching zooms around the fingers,
/// a double tap resets the view and a tap reads the value of the nearest curve.
struct PlotInteractionView: UIViewRepresentable {
    var onPan: (CGSize) -> Void
    var onZoom: (Double, CGPoint) -> Void
    var onHover: (CGPoint?) -> Void
    var onDoubleClick: () -> Void
    var onGestureEnd: () -> Void

    func makeUIView(context: Context) -> InteractionUIView {
        InteractionUIView()
    }

    func updateUIView(_ view: InteractionUIView, context: Context) {
        view.onPan = onPan
        view.onZoom = onZoom
        view.onHover = onHover
        view.onDoubleClick = onDoubleClick
        view.onGestureEnd = onGestureEnd
    }
}

final class InteractionUIView: UIView, UIGestureRecognizerDelegate {
    var onPan: (CGSize) -> Void = { _ in }
    var onZoom: (Double, CGPoint) -> Void = { _, _ in }
    var onHover: (CGPoint?) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onGestureEnd: () -> Void = {}
    private let backSwipe = BackSwipeSuppressor()
    /// How many fingers the pan had at its last update. When a finger lands or lifts (the end of a
    /// pinch, say) the centre of the touches jumps; that jump is not a drag and is skipped.
    private var panTouches = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { backSwipe.restore() } else { backSwipe.suppress(from: self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backSwipe.suppress(from: self)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        for recognizer in [pan, pinch, doubleTap, tap] { addGestureRecognizer(recognizer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onHover(nil)
            panTouches = recognizer.numberOfTouches
            UITestLog.add("panBegin,n\(panTouches)")
        case .changed:
            let t = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            guard recognizer.numberOfTouches == panTouches else {
                UITestLog.add("panSkip,n\(panTouches)>\(recognizer.numberOfTouches),\(Int(t.x)),\(Int(t.y))")
                panTouches = recognizer.numberOfTouches
                return
            }
            UITestLog.add("pan,\(Int(t.x)),\(Int(t.y)),n\(panTouches)")
            onPan(CGSize(width: t.x, height: t.y))
        case .ended, .cancelled:
            UITestLog.add("panEnd,n\(recognizer.numberOfTouches)")
            onGestureEnd()
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            let at = recognizer.location(in: self)
            UITestLog.add("zoom,\(String(format: "%.3f", recognizer.scale)),at\(Int(at.x))/\(Int(at.y)),n\(recognizer.numberOfTouches)")
            onZoom(Double(recognizer.scale), at)
            recognizer.scale = 1
        case .ended, .cancelled:
            UITestLog.add("pinchEnd")
            onGestureEnd()
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        onHover(nil)
        onDoubleClick()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        onHover(recognizer.location(in: self))
    }
}
