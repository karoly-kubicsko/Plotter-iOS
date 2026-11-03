import SwiftUI

/// The main window: function list on the left, the graph on the right.
struct ContentView: View {
    @Bindable var document: PlotDocument
    @State private var showsOptions = false

    var body: some View {
        NavigationSplitView {
            FunctionListView(document: document)
                .navigationSplitViewColumnWidth(min: 290, ideal: 340, max: 480)
        } detail: {
            PlotArea(document: document)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Graph", selection: $document.mode) {
                    Text("2D").tag(PlotKind.curve)
                    Text("3D").tag(PlotKind.surface)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .help("Switch between the 2D graph (⌘1) and the 3D graph (⌘2)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsOptions.toggle()
                } label: {
                    Label("View Options", systemImage: "slider.horizontal.3")
                }
                .help("View options")
                .popover(isPresented: $showsOptions, arrowEdge: .bottom) {
                    ViewOptions(document: document)
                }
            }
        }
    }
}

/// The graph with its glass overlays: legend (top left) and view controls (bottom right).
private struct PlotArea: View {
    let document: PlotDocument

    var body: some View {
        ZStack {
            plot
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    LegendView(document: document)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    ViewControls(document: document)
                }
            }
            .padding(16)
        }
        .background(Plot2DView.background)
    }

    @ViewBuilder private var plot: some View {
        switch document.mode {
        case .curve:
            Plot2DView(document: document)
                .transition(.opacity)
        case .surface:
            Plot3DView(
                surfaces: document.visibleFunctions.compactMap { f in
                    f.compiled.map { SurfaceInput(id: f.id, revision: f.revision, colorIndex: f.colorIndex, function: $0) }
                },
                settings: document.surface,
                resetToken: document.resetToken,
                zoomRequest: document.zoomRequest)
            .transition(.opacity)
        }
    }
}

/// The typeset formulas of the visible functions, on a glass card.
private struct LegendView: View {
    let document: PlotDocument

    var body: some View {
        let functions = document.visibleFunctions
        if !functions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(functions) { function in
                    HStack(spacing: 10) {
                        if function.kind == .surface && document.surface.coloring != .function {
                            ColormapSwatch(coloring: document.surface.coloring)
                        } else {
                            Capsule()
                                .fill(function.color)
                                .frame(width: 16, height: 4)
                        }
                        if let formula = function.legendFormula(size: 17) {
                            FormulaView(box: formula)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Legend: " + functions.map(\.source).joined(separator: "; "))
        }
    }
}

private struct ColormapSwatch: View {
    let coloring: SurfaceColoring

    var body: some View {
        let stops: [Color] = switch coloring {
        case .viridis: [Color(red: 0.27, green: 0.0, blue: 0.33), Color(red: 0.13, green: 0.57, blue: 0.55),
                        Color(red: 0.99, green: 0.91, blue: 0.14)]
        case .magma: [Color(red: 0.0, green: 0.0, blue: 0.02), Color(red: 0.72, green: 0.21, blue: 0.47),
                      Color(red: 0.99, green: 0.99, blue: 0.75)]
        case .function: [.gray]
        }
        Capsule()
            .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
            .frame(width: 16, height: 6)
    }
}

/// Zoom and reset buttons on glass.
private struct ViewControls: View {
    let document: PlotDocument

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    document.zoom(by: 1 / 1.5)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 18, height: 18)
                }
                .help("Zoom out")
                .accessibilityLabel("Zoom out")

                Button {
                    document.zoom(by: 1.5)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
                .help("Zoom in")
                .accessibilityLabel("Zoom in")

                Button {
                    document.resetView()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 18, height: 18)
                }
                .help("Reset view (⌘0, or double-click the graph)")
                .accessibilityLabel("Reset view")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }
}

/// Settings for the 3D surface.
private struct ViewOptions: View {
    @Bindable var document: PlotDocument

    var body: some View {
        Form {
            Section("3D Surface") {
                LabeledContent("Domain") {
                    HStack {
                        Slider(value: $document.surface.halfWidth, in: 1...20, step: 0.5)
                            .frame(width: 140)
                        Text("±\(document.surface.halfWidth, specifier: "%g")")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Resolution", selection: $document.surface.resolution) {
                    ForEach([50, 100, 150, 200, 300, 400], id: \.self) { n in
                        Text("\(n) × \(n)").tag(n)
                    }
                }
                Picker("Colours", selection: $document.surface.coloring) {
                    ForEach(SurfaceColoring.allCases) { coloring in
                        Text(coloring.title).tag(coloring)
                    }
                }
                Toggle("Mesh Lines", isOn: $document.surface.showsMesh)
            }
            Section {
                Button("Reset View") { document.resetView() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}
