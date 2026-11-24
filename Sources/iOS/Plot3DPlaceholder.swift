import SwiftUI

// The Metal 3D graph (Plot3DView.swift) is macOS-only for now. This stand-in keeps the shared
// window code unchanged: it takes the same inputs and says that 3D is not available yet.

struct SurfaceInput {
    let id: UUID
    let revision: Int
    let colorIndex: Int
    let function: CompiledFunction
    let system: CoordinateSystem
    var field: ScalarField?
}

struct Plot3DView: View {
    let surfaces: [SurfaceInput]
    let settings: SurfaceSettings
    var trueScale = false
    let resetToken: Int
    let zoomRequest: ZoomRequest

    var body: some View {
        ContentUnavailableView {
            Label("3D graphs are not available on iOS yet", systemImage: "cube.transparent")
        } description: {
            Text("Switch to the 2D graph. \(surfaces.count) surface(s) are waiting for the 3D view.")
        }
    }
}
