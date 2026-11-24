import SwiftUI

@main
struct PlotterIOSApp: App {
    @State private var document = PlotDocument()

    var body: some Scene {
        WindowGroup {
            ContentView(document: document)
        }
    }
}
