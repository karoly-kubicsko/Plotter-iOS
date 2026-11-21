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
                HStack(spacing: 12) {
                    Picker("Graph", selection: $document.mode) {
                        Text("2D").tag(PlotKind.curve)
                        Text("3D").tag(PlotKind.surface)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .help("Switch between the 2D graph (⌘1) and the 3D graph (⌘2)")
                    CoordinatePicker(document: document)
                }
                // Room between the controls and the edge of the toolbar's glass background.
                .padding(.horizontal, 10)
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

/// Chooses how inputs are read in the graph in view: Cartesian or polar in 2D,
/// Cartesian or spherical in 3D.
private struct CoordinatePicker: View {
    @Bindable var document: PlotDocument
    @State private var showsDefinitions = false

    var body: some View {
        HStack(spacing: 6) {
            picker
            if (document.mode == .curve && document.plane == .polar)
                || (document.mode == .surface && document.space == .spherical) {
                Button {
                    showsDefinitions.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 4)
                .help("What r, θ and φ mean")
                .accessibilityLabel("Coordinate definitions")
                .popover(isPresented: $showsDefinitions, arrowEdge: .bottom) {
                    CoordinateDefinitions(system: document.mode == .curve ? .polar : .spherical)
                }
            }
        }
    }

    @ViewBuilder private var picker: some View {
        switch document.mode {
        case .curve:
            Picker("Coordinates", selection: $document.plane) {
                Text("Cartesian").tag(CoordinateSystem.cartesian)
                Text("Polar").tag(CoordinateSystem.polar)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .help("Cartesian or polar grid. Polar curves are written r = f(θ) in either mode")
        case .surface:
            Picker("Coordinates", selection: $document.space) {
                Text("Cartesian").tag(CoordinateSystem.cartesian)
                Text("Spherical").tag(CoordinateSystem.spherical)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .help("Cartesian or true-scale spherical box. Spherical surfaces are written r = f(θ, φ) in either mode")
        }
    }
}

/// Defines r, θ and φ, with the conversion to x, y and z.
private struct CoordinateDefinitions: View {
    let system: CoordinateSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if system == .polar {
                Text("Polar coordinates").font(.headline)
                row("r", "radius: the distance from the origin; a negative r points the opposite way")
                row("θ", "angle from the positive x-axis, counter-clockwise, in radians")
                Text("x = r cos θ,  y = r sin θ").font(.callout.monospaced())
                Text("Write  1 + \\cos\\theta,  r = f(θ)  or  r(θ) = …").font(.callout.monospaced())
            } else {
                Text("Spherical coordinates").font(.headline)
                row("r", "radius: the distance from the origin")
                row("θ", "polar angle (colatitude) from the +z axis, 0 to π")
                row("φ", "azimuth in the xy-plane from the +x axis, 0 to 2π")
                Text("x = r sin θ cos φ\ny = r sin θ sin φ\nz = r cos θ").font(.callout.monospaced())
                Text("Write  \\sin\\theta\\cos\\varphi,  r = f(θ, φ)  or  r(θ, φ) = …").font(.callout.monospaced())
            }
            Text("A formula in θ alone is a polar curve r(θ); with φ it is a spherical surface r(θ, φ). Type the angles as \\theta and \\varphi, as theta and phi, or as θ and φ. Angles are in radians.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(symbol).font(.title3.italic()).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
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
                    f.compiled.map { SurfaceInput(id: f.id, revision: f.revision, colorIndex: f.colorIndex, function: $0,
                                     system: f.system ?? .cartesian, field: f.field) }
                },
                settings: document.surface,
                trueScale: document.space == .spherical,
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
                    LegendRow(function: function, coloring: document.surface.coloring)
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

/// One legend entry: a colour key and the typeset formula.
private struct LegendRow: View {
    let function: PlotFunction
    let coloring: SurfaceColoring

    /// Surfaces coloured by height show the colormap instead of the function colour.
    private var showsColormap: Bool {
        let isSurface: Bool = function.kind == PlotKind.surface
        let usesColormap: Bool = coloring != SurfaceColoring.function
        return isSurface && usesColormap
    }

    var body: some View {
        HStack(spacing: 10) {
            key
            if let formula = function.legendFormula(size: 17) {
                FormulaView(box: formula)
            }
        }
    }

    @ViewBuilder private var key: some View {
        if showsColormap {
            ColormapSwatch(coloring: coloring)
        } else if function.imaginary != nil {
            ComplexKey(color: function.color)
        } else {
            Capsule()
                .fill(function.color)
                .frame(width: 16, height: 4)
        }
    }
}

/// Key for a complex function: solid line = real part, dashed line = imaginary part.
private struct ComplexKey: View {
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            line(dashed: false, label: "Re")
            line(dashed: true, label: "Im")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Solid line: real part. Dashed line: imaginary part.")
    }

    private func line(dashed: Bool, label: String) -> some View {
        let pattern: [CGFloat] = dashed ? [4, 4] : []
        return HStack(spacing: 4) {
            Path { p in
                p.move(to: CGPoint(x: 1, y: 2))
                p.addLine(to: CGPoint(x: 17, y: 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: pattern))
            .frame(width: 18, height: 4)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            Section("Polar Curve") {
                Picker("θ Range", selection: $document.thetaTurns) {
                    ForEach([1, 2, 3, 4, 6, 8, 10], id: \.self) { turns in
                        Text("0 to \(2 * turns)π")
                            .tag(turns)
                    }
                }
                .help("Polar curves are drawn for θ from 0 up to this angle")
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
