import Foundation

/// Set when the UI tests (UITests/) launch the app with `-PlotterUITesting`. The app then starts
/// from the sample document instead of the saved one, and the two graphs describe their camera
/// in their accessibility value, which the tests read to check what a gesture did.
enum UITesting {
    static let isEnabled = CommandLine.arguments.contains("-PlotterUITesting")
}
