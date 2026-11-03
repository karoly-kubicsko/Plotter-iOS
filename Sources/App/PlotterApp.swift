import AppKit
import SwiftUI

@main
struct PlotterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var document = PlotDocument()

    var body: some Scene {
        Window("Plotter", id: "main") {
            ContentView(document: document)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Function") {
                    document.addFunction()
                }
                .keyboardShortcut("n")
            }
            CommandGroup(before: .toolbar) {
                Button("2D Graph") { document.mode = .curve }
                    .keyboardShortcut("1")
                Button("3D Graph") { document.mode = .surface }
                    .keyboardShortcut("2")
                Divider()
                Button("Zoom In") { document.zoom(by: 1.5) }
                    .keyboardShortcut("+")
                Button("Zoom Out") { document.zoom(by: 1 / 1.5) }
                    .keyboardShortcut("-")
                Button("Reset View") { document.resetView() }
                    .keyboardShortcut("0")
                Divider()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Behave like a single-window utility: closing the window quits the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Used by the CI smoke test: write the window number so the window can be
        // captured with `screencapture -l`.
        guard let path = ProcessInfo.processInfo.environment["PLOTTER_WINDOW_ID_FILE"] else { return }
        NSApp.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                try? String(window.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
