import SwiftUI

@main
struct PlotterApp: App {
    @State private var document = PlotDocument()

    var body: some Scene {
        WindowGroup {
            ContentView(document: document)
        }
    }
}
