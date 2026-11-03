import AppKit
import Observation
import SwiftUI

// MARK: - Palette

/// Curve colours: distinguishable for common forms of colour blindness (based on
/// the Okabe–Ito palette), with lighter variants for dark mode.
enum CurvePalette {
    private static let pairs: [(light: UInt32, dark: UInt32)] = [
        (0x0068C9, 0x4DA3FF),  // blue
        (0xE07B00, 0xFFA94D),  // orange
        (0x00936E, 0x3DD6A3),  // bluish green
        (0xC8324A, 0xFF7A8A),  // vermillion
        (0x7C4DDB, 0xB794FF),  // purple
        (0x0A8DB0, 0x5CD3F0),  // sky blue
        (0xA67C00, 0xF5D547),  // yellow
    ]

    static var count: Int { pairs.count }

    static func nsColor(_ index: Int) -> NSColor {
        let pair = pairs[((index % count) + count) % count]
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(dark ? pair.dark : pair.light)
        }
    }

    /// Linear components for Metal (sRGB values; the drawable is not sRGB-encoded).
    static func rgba(_ index: Int, dark: Bool) -> SIMD4<Float> {
        let pair = pairs[((index % count) + count) % count]
        let hex = dark ? pair.dark : pair.light
        return SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, 1)
    }

    static func color(_ index: Int) -> Color {
        Color(nsColor: nsColor(index))
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

// MARK: - Function

/// One row of the function list: the LaTeX source and everything derived from it.
@MainActor
@Observable
final class PlotFunction: Identifiable {
    let id = UUID()

    private(set) var source: String
    var colorIndex: Int
    var isVisible: Bool
    /// Values of free parameters, by symbol name.
    private(set) var parameterValues: [String: Double]

    /// The last equation that parsed. It stays while the source is invalid, so the
    /// plot keeps showing the last valid version.
    private(set) var equation: Equation?
    private(set) var compiled: CompiledFunction?
    private(set) var error: MathError?
    /// The typeset formula of `equation`, including its name.
    private(set) var formula: MathBox?
    /// Incremented whenever `compiled` changes; the 3D view re-meshes on change.
    private(set) var revision = 0
    /// Name shown for a formula typed without a left-hand side (f, g, h, …).
    private(set) var autoName = "f"

    init(source: String, colorIndex: Int, isVisible: Bool = true, parameters: [String: Double] = [:]) {
        self.source = source
        self.colorIndex = colorIndex
        self.isVisible = isVisible
        self.parameterValues = parameters
        reparse()
    }

    var kind: PlotKind? { equation?.kind }
    var color: Color { CurvePalette.color(colorIndex) }
    var isEmpty: Bool { source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The function name as displayed, e.g. "f" or "y".
    var displayName: String {
        switch equation?.lhs {
        case .variable(let s)?: s.displayName
        case .function(let s, _)?: s.displayName
        default: autoName
        }
    }

    /// Name explicitly written by the user (f in `f(x) = …`), if any.
    var explicitName: String? {
        if case .function(let s, _)? = equation?.lhs { return s.name }
        return nil
    }

    func setSource(_ newValue: String) {
        guard newValue != source else { return }
        source = newValue
        reparse()
    }

    func setParameter(_ name: String, to value: Double) {
        parameterValues[name] = value
        recompile()
    }

    func setAutoName(_ name: String) {
        guard name != autoName else { return }
        autoName = name
        typeset()
    }

    private func reparse() {
        if isEmpty {
            error = nil
            equation = nil
            compiled = nil
            formula = nil
            revision += 1
            return
        }
        do {
            let eq = try Parser.parseEquation(source)
            equation = eq
            error = nil
            for p in eq.parameters where parameterValues[p.name] == nil {
                parameterValues[p.name] = 1
            }
            recompile()
            typeset()
        } catch {
            self.error = error
        }
    }

    private func recompile() {
        guard let equation else { return }
        compiled = equation.compile(parameters: parameterValues)
        revision += 1
    }

    private func typeset() {
        guard let equation else {
            formula = nil
            return
        }
        let lhs: LeftHandSide
        if case .none = equation.lhs {
            lhs = .function(Symbol(autoName), equation.arguments)
        } else {
            lhs = equation.lhs
        }
        formula = Typesetter(size: 18).layout(lhs: lhs, rhs: equation.rhs)
    }

    /// The same formula typeset at another size (for the legend).
    func legendFormula(size: CGFloat) -> MathBox? {
        guard let equation else { return nil }
        let lhs: LeftHandSide
        if case .none = equation.lhs {
            lhs = .function(Symbol(autoName), equation.arguments)
        } else {
            lhs = equation.lhs
        }
        return Typesetter(size: size).layout(lhs: lhs, rhs: equation.rhs)
    }
}

// MARK: - View settings

/// The 2D camera: the centre of the view and its scale. The aspect ratio is 1:1.
struct Camera2D: Codable, Equatable, Sendable {
    var centerX: Double = 0
    var centerY: Double = 0
    /// World units per point.
    var unitsPerPoint: Double = 0.025

    func viewport(for size: CGSize) -> Viewport {
        let w = Double(size.width) * unitsPerPoint
        let h = Double(size.height) * unitsPerPoint
        return Viewport(xMin: centerX - w / 2, xMax: centerX + w / 2, yMin: centerY - h / 2, yMax: centerY + h / 2)
    }

    func screenPoint(x: Double, y: Double, size: CGSize) -> CGPoint {
        CGPoint(x: (x - centerX) / unitsPerPoint + Double(size.width) / 2,
                y: Double(size.height) / 2 - (y - centerY) / unitsPerPoint)
    }

    func worldPoint(_ p: CGPoint, size: CGSize) -> (x: Double, y: Double) {
        (centerX + (Double(p.x) - Double(size.width) / 2) * unitsPerPoint,
         centerY - (Double(p.y) - Double(size.height) / 2) * unitsPerPoint)
    }

    mutating func pan(by delta: CGSize) {
        centerX -= Double(delta.width) * unitsPerPoint
        centerY += Double(delta.height) * unitsPerPoint
    }

    /// Zooms by `factor` (> 1 zooms in) keeping the point under `anchor` fixed.
    mutating func zoom(by factor: Double, at anchor: CGPoint, size: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let world = worldPoint(anchor, size: size)
        unitsPerPoint = min(max(unitsPerPoint / factor, 1e-7), 1e7)
        centerX = world.x - (Double(anchor.x) - Double(size.width) / 2) * unitsPerPoint
        centerY = world.y + (Double(anchor.y) - Double(size.height) / 2) * unitsPerPoint
    }

    /// The default view: x from −10 to 10 across the width.
    static func standard(for size: CGSize) -> Camera2D {
        Camera2D(centerX: 0, centerY: 0, unitsPerPoint: 20 / max(Double(size.width), 100))
    }
}

enum SurfaceColoring: String, Codable, CaseIterable, Sendable, Identifiable {
    case viridis, magma, function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .viridis: "Viridis"
        case .magma: "Magma"
        case .function: "Function Colour"
        }
    }
}

struct SurfaceSettings: Codable, Equatable, Sendable {
    /// The surface is drawn over [−halfWidth, halfWidth]² in x and y.
    var halfWidth: Double = 5
    /// Samples per side.
    var resolution: Int = 150
    var coloring: SurfaceColoring = .viridis
    var showsMesh: Bool = true
}

struct ZoomRequest: Equatable {
    var token = 0
    var factor = 1.0
}

// MARK: - Document

/// The app's state: the function list and the view settings. It is saved to the
/// user defaults on every change and restored at launch.
@MainActor
@Observable
final class PlotDocument {
    private(set) var functions: [PlotFunction] = []
    var mode: PlotKind = .curve {
        didSet { save() }
    }
    var camera2D: Camera2D?
    var surface = SurfaceSettings() {
        didSet { save() }
    }
    /// The row whose LaTeX field has focus.
    var selection: PlotFunction.ID?
    /// Bumped to ask the plot views to return to their default view.
    private(set) var resetToken = 0
    /// Bumped to ask the 3D view to zoom.
    private(set) var zoomRequest = ZoomRequest()

    private static let storageKey = "PlotterDocument.v1"

    init() {
        if !load() {
            loadSample()
        }
        if let start = UserDefaults.standard.string(forKey: "PlotterStartMode"), let kind = PlotKind(rawValue: start) {
            mode = kind
        }
        updateNames()
    }

    // MARK: Editing

    func addFunction(source: String = "") {
        let used = Set(functions.map(\.colorIndex))
        let color = (0..<CurvePalette.count).first { !used.contains($0) } ?? functions.count
        let function = PlotFunction(source: source, colorIndex: color)
        functions.append(function)
        selection = function.id
        updateNames()
        save()
    }

    func duplicate(_ function: PlotFunction) {
        guard let index = functions.firstIndex(where: { $0.id == function.id }) else { return }
        let copy = PlotFunction(source: function.source, colorIndex: function.colorIndex + 1,
                                isVisible: function.isVisible, parameters: function.parameterValues)
        functions.insert(copy, at: index + 1)
        updateNames()
        save()
    }

    func remove(_ function: PlotFunction) {
        functions.removeAll { $0.id == function.id }
        if selection == function.id { selection = nil }
        updateNames()
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        functions.move(fromOffsets: source, toOffset: destination)
        updateNames()
        save()
    }

    func setSource(_ function: PlotFunction, _ text: String) {
        let previousKind = function.kind
        function.setSource(text)
        // Follow the user to the 3D view when they type a surface, and back.
        if let kind = function.kind, kind != previousKind, kind != mode {
            mode = kind
        }
        updateNames()
        save()
    }

    func setParameter(_ function: PlotFunction, _ name: String, _ value: Double) {
        function.setParameter(name, to: value)
        save()
    }

    func setVisible(_ function: PlotFunction, _ visible: Bool) {
        function.isVisible = visible
        save()
    }

    func setColor(_ function: PlotFunction, _ index: Int) {
        function.colorIndex = index
        save()
    }

    func resetView() {
        resetToken += 1
    }

    /// Zooms the current view in (factor > 1) or out around its centre.
    func zoom(by factor: Double) {
        switch mode {
        case .curve:
            guard var camera = camera2D else { return }
            camera.unitsPerPoint = min(max(camera.unitsPerPoint / factor, 1e-7), 1e7)
            camera2D = camera
            save()
        case .surface:
            zoomRequest = ZoomRequest(token: zoomRequest.token + 1, factor: factor)
        }
    }

    /// Functions drawn in the current mode.
    var visibleFunctions: [PlotFunction] {
        functions.filter { $0.isVisible && $0.kind == mode && $0.compiled != nil }
    }

    /// Gives each formula without a left-hand side a free name: f, g, h, …
    private func updateNames() {
        let taken = Set(functions.compactMap(\.explicitName))
        var candidates = ["f", "g", "h", "p", "q", "u", "v", "w"].filter { !taken.contains($0) }.makeIterator()
        var counter = 1
        for function in functions where function.explicitName == nil {
            if let next = candidates.next() {
                function.setAutoName(next)
            } else {
                function.setAutoName("f_\(counter)")
                counter += 1
            }
        }
    }

    // MARK: Persistence

    private struct Stored: Codable {
        struct Function: Codable {
            var source: String
            var colorIndex: Int
            var isVisible: Bool
            var parameters: [String: Double]
        }

        var functions: [Function]
        var mode: PlotKind
        var camera2D: Camera2D?
        var surface: SurfaceSettings
    }

    func save() {
        let stored = Stored(
            functions: functions.map {
                .init(source: $0.source, colorIndex: $0.colorIndex, isVisible: $0.isVisible, parameters: $0.parameterValues)
            },
            mode: mode, camera2D: camera2D, surface: surface)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func load() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
        functions = stored.functions.map {
            PlotFunction(source: $0.source, colorIndex: $0.colorIndex, isVisible: $0.isVisible, parameters: $0.parameters)
        }
        mode = stored.mode
        camera2D = stored.camera2D
        surface = stored.surface
        return true
    }

    private func loadSample() {
        functions = [
            PlotFunction(source: "\\sin x", colorIndex: 0),
            PlotFunction(source: "e^{-x^2}", colorIndex: 1),
            PlotFunction(source: "\\frac{1}{x}", colorIndex: 2),
            PlotFunction(source: "z = \\sin\\sqrt{x^2+y^2}", colorIndex: 4),
        ]
    }
}
