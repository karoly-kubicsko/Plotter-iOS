import Foundation
import SwiftUI

/// Set when the UI tests (UITests/) launch the app with `-PlotterUITesting`. The app then starts
/// from the sample document instead of the saved one, and the two graphs describe their camera
/// in their accessibility value, which the tests read to check what a gesture did.
enum UITesting {
    static let isEnabled = CommandLine.arguments.contains("-PlotterUITesting")
}

/// The last gesture events, recorded in UI-test mode only and exposed in the graphs' accessibility
/// value, so a failing UI test can show what the touches actually did.
@MainActor
enum UITestLog {
    private static var lines: [String] = []

    static func add(_ line: @autoclosure () -> String) {
        guard UITesting.isEnabled else { return }
        lines.append(line())
        if lines.count > 24 { lines.removeFirst() }
    }

    /// No spaces: the graphs' accessibility value is a space-separated list of key=value pairs.
    static var text: String { lines.joined(separator: ";") }
}

/// UI-test mode only: a transparent region that does not take touches, which the tests pinch
/// instead of the whole graph. XCUITest starts a pinch in with the fingers at the edges of the
/// element it is given; on a full-screen graph one finger then lands where the system's edge swipe
/// (on an iPad: the floating function list) takes the touch. The region is the middle right of the
/// graph, away from both.
struct UITestPinchZone: View {
    let identifier: String

    var body: some View {
        if UITesting.isEnabled {
            GeometryReader { proxy in
                Color.clear
                    .frame(width: proxy.size.width * 0.5, height: proxy.size.height * 0.5)
                    .offset(x: proxy.size.width * 0.4, y: proxy.size.height * 0.25)
                    .accessibilityElement()
                    .accessibilityIdentifier(identifier)
                    .accessibilityLabel("Pinch zone")
                    .allowsHitTesting(false)
            }
        }
    }
}
