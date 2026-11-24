import Foundation

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
