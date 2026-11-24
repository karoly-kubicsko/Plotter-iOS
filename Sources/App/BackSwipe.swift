import UIKit

/// iOS 26 lets a swipe from anywhere in the content go back to the previous screen. On the
/// graphs that swipe is a drag (pan the 2D graph, rotate the 3D one), and a drag to the right
/// would leave the graph for the function list on an iPhone. While a graph is on screen this
/// switches that gesture off; the swipe from the screen's left edge and the back button still
/// go back.
@MainActor
final class BackSwipeSuppressor {
    private weak var suppressed: UIGestureRecognizer?

    /// Call when the view enters a window, and again after layout (the navigation controller
    /// may not be in place yet the first time).
    func suppress(from view: UIView) {
        guard suppressed == nil, view.window != nil,
              let gesture = Self.navigationController(of: view)?.interactiveContentPopGestureRecognizer,
              gesture.isEnabled else { return }
        gesture.isEnabled = false
        suppressed = gesture
    }

    /// Call when the view leaves the window.
    func restore() {
        suppressed?.isEnabled = true
        suppressed = nil
    }

    private static func navigationController(of view: UIView) -> UINavigationController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController {
                return navigation
            }
            responder = current.next
        }
        return nil
    }
}
