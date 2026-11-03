import AppKit
import SwiftUI

/// The sidebar: one row per function, each with a typeset preview and a LaTeX field.
struct FunctionListView: View {
    let document: PlotDocument

    var body: some View {
        List {
            ForEach(document.functions) { function in
                FunctionRow(function: function, document: document)
                    .listRowSeparator(.hidden)
            }
            .onMove { document.move(from: $0, to: $1) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                withAnimation(.smooth) { document.addFunction() }
            } label: {
                Label("Add Function", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(12)
            .help("Add a function (⌘N)")
        }
        .toolbar {
            ToolbarItem {
                Button {
                    withAnimation(.smooth) { document.addFunction() }
                } label: {
                    Label("Add Function", systemImage: "plus")
                }
                .help("Add a function (⌘N)")
            }
        }
    }
}

struct FunctionRow: View {
    let function: PlotFunction
    let document: PlotDocument
    @FocusState private var isEditing: Bool
    @State private var showsColors = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            sourceField
            if let error = function.error {
                ErrorMessage(source: function.source, error: error)
                    .transition(.opacity)
            }
            if let parameters = function.equation?.parameters, !parameters.isEmpty, function.error == nil {
                VStack(spacing: 4) {
                    ForEach(parameters, id: \.self) { parameter in
                        ParameterSlider(symbol: parameter, function: function, document: document)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .opacity(function.isVisible ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.2), value: function.error)
        .contextMenu {
            Button("Duplicate") { document.duplicate(function) }
            Button("Copy LaTeX") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(function.source, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) {
                withAnimation(.smooth) { document.remove(function) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                showsColors.toggle()
            } label: {
                Circle()
                    .fill(function.color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .help("Colour")
            .accessibilityLabel("Colour of \(function.displayName)")
            .popover(isPresented: $showsColors, arrowEdge: .bottom) {
                ColorSwatches(selected: function.colorIndex) { index in
                    document.setColor(function, index)
                    showsColors = false
                }
            }

            preview
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { isEditing = true }

            if let kind = function.kind {
                Text(kind == .curve ? "2D" : "3D")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .help(kind == .curve ? "Curve y = f(x), shown in the 2D graph" : "Surface z = f(x, y), shown in the 3D graph")
            }

            Button {
                document.setVisible(function, !function.isVisible)
            } label: {
                Image(systemName: function.isVisible ? "eye" : "eye.slash")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(function.isVisible ? "Hide" : "Show")
            .accessibilityLabel(function.isVisible ? "Hide \(function.displayName)" : "Show \(function.displayName)")

            Button {
                withAnimation(.smooth) { document.remove(function) }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .opacity(isHovering ? 1 : 0)
            .help("Delete")
            .accessibilityLabel("Delete \(function.displayName)")
        }
    }

    @ViewBuilder private var preview: some View {
        if let formula = function.formula {
            FormulaView(box: formula)
                .allowsHitTesting(false)
                .opacity(function.error == nil ? 1 : 0.4)
                .accessibilityLabel(function.source)
        } else {
            Text("Type a function below")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private var sourceField: some View {
        TextField("LaTeX, e.g. \\frac{1}{x}", text: Binding(
            get: { function.source },
            set: { document.setSource(function, $0) }
        ), axis: .vertical)
        .font(.system(size: 12.5, design: .monospaced))
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .focused($isEditing)
        .lineLimit(1...6)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isEditing || function.error != nil ? 1.5 : 1)
        )
        .accessibilityLabel("LaTeX source of \(function.displayName)")
    }

    private var borderColor: Color {
        if function.error != nil { return .red.opacity(0.75) }
        if isEditing { return .accentColor.opacity(0.85) }
        return .primary.opacity(0.1)
    }
}

/// The error message plus the source with the offending characters marked.
private struct ErrorMessage: View {
    let source: String
    let error: MathError

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            if !source.isEmpty {
                Text(marked)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 2)
        .accessibilityElement(children: .combine)
    }

    private var marked: AttributedString {
        var result = AttributedString()
        let range = error.range
        for (i, character) in source.enumerated() {
            var piece = AttributedString(String(character))
            if range.contains(i) {
                piece.foregroundColor = .red
                piece.backgroundColor = .red.opacity(0.15)
                piece.underlineStyle = Text.LineStyle(pattern: .solid, color: .red)
            }
            result += piece
        }
        if range.isEmpty || range.lowerBound >= source.count {
            var caret = AttributedString(" ‸")
            caret.foregroundColor = .red
            result += caret
        }
        return result
    }
}

private struct ParameterSlider: View {
    let symbol: Symbol
    let function: PlotFunction
    let document: PlotDocument

    var body: some View {
        let value = function.parameterValues[symbol.name] ?? 1
        let limit = max(5, (abs(value)).rounded(.up))
        let binding = Binding<Double>(
            get: { function.parameterValues[symbol.name] ?? 1 },
            set: { document.setParameter(function, symbol.name, $0) }
        )
        HStack(spacing: 8) {
            Text(symbol.displayName)
                .font(.custom("STIXTwoText-Italic", size: 15))
                .frame(minWidth: 18, alignment: .leading)
            Slider(value: binding, in: -limit...limit)
                .controlSize(.small)
            TextField("", value: binding, format: .number.precision(.fractionLength(0...3)))
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 58)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Parameter \(symbol.displayName)")
    }
}

private struct ColorSwatches: View {
    let selected: Int
    let choose: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<CurvePalette.count, id: \.self) { index in
                Button {
                    choose(index)
                } label: {
                    Circle()
                        .fill(CurvePalette.color(index))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(.primary.opacity(index == selected ? 0.8 : 0.1), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(index + 1)")
            }
        }
        .padding(12)
    }
}
