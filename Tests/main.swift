// Test runner for the math engine. build.sh compiles it together with
// Sources/Math and runs it; a non-zero exit status fails the build.
//
//   ./build.sh --test

import Foundation

/// Pass and fail counts. (Top-level variables cannot carry a global actor, so the
/// counters live in a main-actor-isolated type.)
@MainActor enum Results {
    static var passed = 0
    static var failed = 0
}

@MainActor func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        Results.passed += 1
    } else {
        Results.failed += 1
        print("FAIL  \(name)  \(detail())")
    }
}

func close(_ a: Double?, _ b: Double) -> Bool {
    guard let a else { return false }
    if b.isNaN { return a.isNaN }
    if b.isInfinite { return a == b }
    return Swift.abs(a - b) <= 1e-9 * Swift.max(1, Swift.abs(b))
}

// MARK: - Structure and precedence

let structure: [(String, String)] = [
    ("x+1", "(+ x 1)"),
    ("-x^2", "(neg (^ x 2))"),
    ("2^3^2", "(^ 2 (^ 3 2))"),
    ("\\sin x^2", "(sin (^ x 2))"),
    ("\\frac{1}{2}x", "(* (/ 1 2) x)"),
    ("2x", "(* 2 x)"),
    ("x\\sin x", "(* x (sin x))"),
    ("(x+1)(x-1)", "(* (+ x 1) (- x 1))"),
    ("\\sin^2 x", "(sin^2 x)"),
    ("\\sin(2x)", "(sin (* 2 x))"),
    ("\\sin 2x \\cos x", "(* (sin (* 2 x)) (cos x))"),
    ("e^{-x^2}", "(^ e (neg (^ x 2)))"),
    ("x^23", "(* (^ x 2) 3)"),
    ("\\sqrt[3]{x}", "(root 3 x)"),
    ("\\sqrt{x^2+1}", "(sqrt (+ (^ x 2) 1))"),
    ("\\log_{2} x", "(log_2 x)"),
    ("\\log_2(x)", "(log_2 x)"),
    ("|x|", "(abs x)"),
    ("\\left| x \\right|", "(abs x)"),
    ("|x|\\cdot|y|", "(* (abs x) (abs y))"),
    ("|x||y|", "(* (abs x) (abs y))"),
    ("||x|-1|", "(abs (- (abs x) 1))"),
    ("a_1 x", "(* a_1 x)"),
    ("a_{12}x", "(* a_12 x)"),
    ("x/2y", "(* (/ x 2) y)"),
    ("2\\cdot -3", "(* 2 (neg 3))"),
    ("\\frac12", "(/ 1 2)"),
    ("\\frac{x+1}{x-1}", "(/ (+ x 1) (- x 1))"),
    ("x^{-1}", "(^ x (neg 1))"),
    ("e^-x", "(^ e (neg x))"),
    ("\\sin(x)^2", "(^ (sin x) 2)"),
    ("\\ln|x|", "(ln (abs x))"),
    ("\\max(x, 1)", "(max x 1)"),
    ("3!", "(! 3)"),
    ("\\omega t", "(* omega t)"),
    ("a - -b", "(- a (neg b))"),
    ("\\lfloor x \\rfloor", "(floor x)"),
    ("\\sin x + 1", "(+ (sin x) 1)"),
    ("xy", "(* x y)"),
    ("\\exp(-x)", "(exp (neg x))"),
    ("1 - x - 2", "(- (- 1 x) 2)"),
    ("8/4/2", "(/ (/ 8 4) 2)"),
    ("2 \\times x", "(* 2 x)"),
    ("\\left(x+1\\right)^2", "(^ (+ x 1) 2)"),
    ("\\sin\\sqrt{x^2+y^2}", "(sin (sqrt (+ (^ x 2) (^ y 2))))"),
    ("\\operatorname{sgn} x", "(sgn x)"),
    ("\\mathrm{e}^x", "(^ e x)"),
    ("e_1", "e_1"),
    ("θ", "theta"),
    ("2π", "(* 2 pi)"),
    ("\\tan x \\, \\sec x", "(* (tan x) (sec x))"),
    ("\\sin{x} + \\mathrm{i} \\cos{x}", "(+ (sin x) (* i (cos x)))"),
    ("\\overline{z}", "(conj z)"),
    ("\\bar z", "(conj z)"),
    ("\\Re(z)", "(Re z)"),
    ("\\Im z", "(Im z)"),
    ("\\arg z", "(arg z)"),
    ("\\operatorname{conj} z", "(conj z)"),
]

for (source, expected) in structure {
    do {
        let expr = try Parser.parseExpression(source)
        check(expr.sExpression == expected, "parse \(source)", "got \(expr.sExpression), expected \(expected)")
    } catch {
        check(false, "parse \(source)", "threw \(error)")
    }
}

// MARK: - Evaluation

@MainActor func value(_ source: String, _ x: Double, _ y: Double = 0, parameters: [String: Double] = [:]) -> Double? {
    do {
        return try Parser.parseEquation(source).compile(parameters: parameters)(x, y)
    } catch {
        print("      parse error in \(source): \(error)")
        return nil
    }
}

let evaluations: [(String, Double, Double, Double)] = [
    ("\\sin x", 1, 0, Foundation.sin(1)),
    ("-x^2", 3, 0, -9),
    ("2^3^2", 0, 0, 512),
    ("\\frac{1}{2}x", 4, 0, 2),
    ("\\sqrt{x}", -1, 0, .nan),
    ("\\sqrt{x}", 9, 0, 3),
    ("\\sqrt[3]{x}", -8, 0, -2),
    ("\\sqrt[4]{x}", -16, 0, .nan),
    ("x^{1/3}", -8, 0, -2),
    ("x^{\\frac{2}{3}}", -8, 0, 4),
    ("\\ln x", 0, 0, -.infinity),
    ("\\ln x", -1, 0, .nan),
    ("1/x", 0, 0, .infinity),
    ("\\log_2 8", 0, 0, 3),
    ("\\log 1000", 0, 0, 3),
    ("|x-3|", 1, 0, 2),
    ("e^{-x^2}", 0, 0, 1),
    ("\\sin^{-1} x", 1, 0, Double.pi / 2),
    ("\\sin^2 x + \\cos^2 x", 0.7, 0, 1),
    ("3!", 0, 0, 6),
    ("\\pi", 0, 0, Double.pi),
    ("\\cosh x", 0, 0, 1),
    ("\\frac{\\sin x}{x}", 0, 0, .nan),
    ("(x+1)(x-1)", 3, 0, 8),
    ("\\max(x, 1)", 0, 0, 1),
    ("\\min(x, 1, -2)", 0, 0, -2),
    ("\\lceil x \\rceil", 1.2, 0, 2),
    ("x^2 + y^2", 3, 4, 25),
    ("z = \\sin\\sqrt{x^2+y^2}", 0, 0, 0),
    ("f(x, y) = x y", 3, 4, 12),
    ("y = 2x + 1", 3, 0, 7),
    ("f(t) = t^2", 5, 0, 25),
    ("x^{0.5}", 4, 0, 2),
    ("x^{-1}", 4, 0, 0.25),
    ("\\arcsin x", 2, 0, .nan),
    ("\\tan x", 0, 0, 0),
    ("\\sec x", 0, 0, 1),
    ("\\sin(x)^2", 2, 0, Foundation.pow(Foundation.sin(2), 2)),
    ("\\frac{1}{2}x - 1/2x", 7, 0, 0),
    ("(-2)^3", 0, 0, -8),
    ("(-2)^{0.5}", 0, 0, .nan),
]

for (source, x, y, expected) in evaluations {
    let v = value(source, x, y)
    check(close(v, expected), "eval \(source) at (\(x), \(y))", "got \(String(describing: v)), expected \(expected)")
}

check(close(value("a x^2", 3, parameters: ["a": 2]), 18), "parameter a = 2")
check(close(value("a x^2", 3), 9), "parameter default 1")
check(close(value("\\omega_0 t", 2, parameters: ["omega_0": 3]), 6), "subscripted Greek parameter")

// MARK: - Classification

@MainActor func classify(_ source: String) -> Equation? {
    try? Parser.parseEquation(source)
}

check(classify("\\sin x")?.kind == .curve, "classify bare x → curve")
check(classify("y = x^2")?.kind == .curve, "classify y = … → curve")
check(classify("z = x y")?.kind == .surface, "classify z = … → surface")
check(classify("f(x, y) = x + y")?.kind == .surface, "classify f(x,y) → surface")
check(classify("x^2 + y^2")?.kind == .surface, "classify bare x, y → surface")
check(classify("f(t) = \\sin t")?.arguments == [Symbol("t")], "classify f(t) argument")
check(classify("a x^2 + b")?.parameters.map(\.name) == ["a", "b"], "parameters in order")
check(classify("\\omega t")?.arguments == [Symbol("t")], "bare t → curve in t")
check(classify("\\omega t")?.parameters.map(\.name) == ["omega"], "omega is a parameter")
check(classify("\\pi x")?.parameters.isEmpty == true, "π is not a parameter")
check(classify("e^x")?.parameters.isEmpty == true, "e is not a parameter")

// MARK: - Errors

// MARK: - Complex numbers

func closeComplex(_ a: Complex?, _ re: Double, _ im: Double) -> Bool {
    guard let a else { return false }
    return Swift.abs(a.re - re) <= 1e-12 * Swift.max(1, Swift.abs(re))
        && Swift.abs(a.im - im) <= 1e-12 * Swift.max(1, Swift.abs(im))
}

@MainActor func complexValue(_ source: String, _ x: Double, _ y: Double = 0) -> Complex? {
    do {
        return try Parser.parseEquation(source).compileComplex()(x, y)
    } catch {
        print("      parse error in \(source): \(error)")
        return nil
    }
}

// (source, x, expected real part, expected imaginary part)
let complexCases: [(String, Double, Double, Double)] = [
    ("\\sin{x} + \\mathrm{i} \\cos{x}", 0.3, Foundation.sin(0.3), Foundation.cos(0.3)),
    ("\\mathrm{i}^2", 0, -1, 0),
    ("\\imath^3", 0, 0, -1),
    ("\\mathrm i \\cdot \\mathrm i", 0, -1, 0),
    ("e^{\\mathrm{i} \\pi}", 0, -1, 0),
    ("e^{\\mathrm{i} x}", 1, Foundation.cos(1), Foundation.sin(1)),
    ("\\frac{1}{\\mathrm{i}}", 0, 0, -1),
    ("\\frac{1 + 2\\mathrm{i}}{3 - 4\\mathrm{i}}", 0, -0.2, 0.4),
    ("(1 + \\mathrm{i})^2", 0, 0, 2),
    ("x \\mathrm{i}", 2, 0, 2),
    ("\\sqrt{x} + 0\\mathrm{i}", -4, 0, 2),
    ("\\ln x + 0\\mathrm{i}", -1, 0, Double.pi),
    ("(2\\mathrm{i})^{\\frac{1}{2}}", 0, 1, 1),
    ("\\sqrt[3]{-8} + 0\\mathrm{i}", 0, 1, 3.0.squareRoot()),
    ("|3 + 4\\mathrm{i}|", 0, 5, 0),
    ("\\overline{2 + 3\\mathrm{i}}", 0, 2, -3),
    ("\\Re(e^{\\mathrm{i} x})", 1, Foundation.cos(1), 0),
    ("\\Im(e^{\\mathrm{i} x})", 1, Foundation.sin(1), 0),
    ("\\arg(\\mathrm{i})", 0, Double.pi / 2, 0),
    ("\\arg(-1 + 0\\mathrm{i})", 0, Double.pi, 0),
    ("\\sinh(\\mathrm{i} x)", 1, 0, Foundation.sin(1)),
    ("\\cos(\\mathrm{i} x)", 1, Foundation.cosh(1), 0),
    ("\\sin(\\mathrm{i})", 0, 0, Foundation.sinh(1)),
    ("\\exp(\\mathrm{i} \\frac{\\pi}{2})", 0, 0, 1),
    ("\\arctan(\\mathrm{i} \\cdot 0.5)", 0, 0, Foundation.atanh(0.5)),
]

for (source, x, re, im) in complexCases {
    let v = complexValue(source, x)
    check(closeComplex(v, re, im), "complex \(source) at x = \(x)", "got \(String(describing: v)), expected \(re) + \(im)i")
}

check(classify("\\sin{x} + \\mathrm{i}\\cos{x}")?.hasImaginaryPart == true, "sin x + i cos x has an imaginary part")
check(classify("|e^{\\mathrm{i} x}|")?.isComplex == true, "|e^{ix}| is evaluated with complex arithmetic")
check(classify("|e^{\\mathrm{i} x}|")?.hasImaginaryPart == false, "|e^{ix}| is real-valued")
check(classify("\\Re(e^{\\mathrm{i} x})")?.hasImaginaryPart == false, "Re(…) is real-valued")
check(classify("\\mathrm{i} x")?.parameters.isEmpty == true, "upright i is not a parameter")
check(classify("\\imath x")?.parameters.isEmpty == true, "\\imath is not a parameter")
check(classify("i x")?.parameters.map(\.name) == ["i"], "plain italic i is a parameter")
check(classify("\\mathit{i} x")?.parameters.map(\.name) == ["i"], "\\mathit{i} is a parameter")
check(classify("i x")?.isComplex == false, "plain i does not make an expression complex")
check(close(value("\\sin{x} + \\mathrm{i}\\cos{x}", 0.3), Foundation.sin(0.3)), "real part compiles to Re f")
if let eq = classify("\\sin{x} + \\mathrm{i}\\cos{x}"), let im = eq.compileImaginaryPart() {
    check(close(im(0.3), Foundation.cos(0.3)), "imaginary part compiles to Im f")
} else {
    check(false, "imaginary part compiles")
}
check(classify("|e^{\\mathrm{i} x}|")?.compileImaginaryPart() == nil, "real-valued expression has no imaginary curve")
check(classify("z = |x + \\mathrm{i} y|")?.kind == .surface, "|x + iy| is a real surface")
check(classify("z = x + \\mathrm{i} y") == nil, "a complex-valued surface is rejected")

// Re, Im, arg and conjugation of real numbers.
check(close(value("\\Re x", -3), -3), "Re of a real number")
check(close(value("\\Im x", 2), 0), "Im of a real number is 0")
check(close(value("\\arg x", -1), Double.pi), "arg of a negative real is π")
check(close(value("\\arg x", 2), 0), "arg of a positive real is 0")
check(close(value("\\overline{x}", 2), 2), "a real number is its own conjugate")

let malformed: [(String, Range<Int>?)] = [
    ("", nil),
    ("\\frac{1}{", nil),
    ("(x+1", 0..<1),
    ("x+", nil),
    ("\\foo x", 0..<4),
    ("sin x", 0..<3),
    ("x^", 1..<2),
    ("2 3", 2..<3),
    ("|x", 0..<1),
    ("x)", 1..<2),
    ("\\sin", 0..<4),
    ("x = 1 = 2", 6..<7),
    ("\\sqrt[3 x", nil),
    ("{}", nil),
    ("y = y + 1", nil),
    ("r = r + 1", nil),
    ("r = \\mathrm{i}\\theta", nil),
    ("w = x", nil),
    ("f(x, y, z) = x", nil),
    ("x_", nil),
    ("||", nil),
    ("| |", nil),
    ("x # 2", 2..<3),
    ("\\frac{1}", nil),
    ("2 + * 3", 4..<5),
    ("()", nil),
    ("z = x + \\mathrm{i} y", nil),
    ("\\mathrm", nil),
    ("\\overline", nil),
]

for (source, expectedRange) in malformed {
    do {
        _ = try Parser.parseEquation(source)
        check(false, "error for “\(source)”", "parsed without error")
    } catch {
        check(!error.message.isEmpty, "error message for “\(source)”")
        if let expectedRange {
            check(error.range == expectedRange, "error range for “\(source)”",
                  "got \(error.range), expected \(expectedRange): \(error.message)")
        }
    }
}

// MARK: - Curve sampling

let view = Viewport(xMin: -5, xMax: 5, yMin: -5, yMax: 5)

@MainActor func segments(_ source: String, _ viewport: Viewport) -> [[SIMD2<Double>]] {
    guard let eq = try? Parser.parseEquation(source) else {
        check(false, "sampler parse \(source)")
        return []
    }
    return CurveSampler.sample(eq.compile(), viewport: viewport, pixelWidth: 800, pixelHeight: 800)
}

/// True if two consecutive points are more than half the view apart vertically and the
/// line between them passes through the view (a connector across a pole would).
func hasLongStep(_ segs: [[SIMD2<Double>]], viewport: Viewport) -> Bool {
    for s in segs {
        for (p, q) in zip(s, s.dropFirst()) {
            let overlapsView = Swift.min(p.y, q.y) < viewport.yMax && Swift.max(p.y, q.y) > viewport.yMin
            if overlapsView && Swift.abs(q.y - p.y) > viewport.height / 2 { return true }
        }
    }
    return false
}

func hasVerticalJump(_ segs: [[SIMD2<Double>]], limit: Double) -> Bool {
    for s in segs {
        for (p, q) in zip(s, s.dropFirst()) where Swift.abs(q.y - p.y) > limit && Swift.abs(q.x - p.x) < 1e-3 {
            return true
        }
    }
    return false
}

let tanSegments = segments("\\tan x", view)
check(tanSegments.count == 5, "tan x has 5 branches in [−5, 5]", "got \(tanSegments.count)")
check(!hasVerticalJump(tanSegments, limit: 5), "tan x has no vertical connectors")
check(!hasLongStep(tanSegments, viewport: view), "tan x has no connector across a pole")

let reciprocal = segments("\\frac{1}{x}", view)
check(reciprocal.count == 2, "1/x has 2 branches", "got \(reciprocal.count)")
check(!hasVerticalJump(reciprocal, limit: 5), "1/x has no vertical connector")
check(!hasLongStep(reciprocal, viewport: view), "1/x has no connector across the pole")

let rootSegments = segments("\\sqrt{x}", view)
check(rootSegments.count == 1, "√x is one branch", "got \(rootSegments.count)")
check((rootSegments.first?.first?.x ?? 1) < 0.001, "√x starts at x ≈ 0", "starts at \(rootSegments.first?.first?.x ?? .nan)")

let sine = segments("\\sin x", view)
check(sine.count == 1, "sin x is one branch")
let sineError = sine.flatMap { $0 }.map { Swift.abs($0.y - Foundation.sin($0.x)) }.max() ?? 1
check(sineError < 1e-9, "sin x points lie on the curve")
check((sine.first?.count ?? 0) < 2000, "sin x uses a modest number of points", "\(sine.first?.count ?? 0)")

let floorSegments = segments("\\lfloor x \\rfloor", Viewport(xMin: -2.5, xMax: 2.5, yMin: -5, yMax: 5))
check(floorSegments.count == 6, "floor has 6 steps in [−2.5, 2.5]", "got \(floorSegments.count)")
check(segments("x^3", view).count == 1, "steep but continuous x³ stays one piece")
check(segments("\\sqrt[3]{x}", view).count == 1, "∛x (vertical tangent at 0) stays one piece")

if let eq = try? Parser.parseEquation("\\sin{x} + \\mathrm{i}\\cos{x}"), let im = eq.compileImaginaryPart() {
    let imag = CurveSampler.sample(im, viewport: view, pixelWidth: 800, pixelHeight: 800)
    let error = imag.flatMap { $0 }.map { Swift.abs($0.y - Foundation.cos($0.x)) }.max() ?? 1
    check(imag.count == 1 && error < 1e-9, "Im of sin x + i cos x samples as cos x")
}

let wild = segments("\\sin\\frac{1}{x}", view)
check(!wild.isEmpty && wild.flatMap { $0 }.count <= 45_000, "sin(1/x) stays within budget")

check(segments("\\ln x", Viewport(xMin: -5, xMax: -1, yMin: -5, yMax: 5)).isEmpty, "ln x on x < 0 draws nothing")

// MARK: - Surface sampling

if let pole = try? Parser.parseEquation("\\frac{1}{x^2+y^2}") {
    let grid = SurfaceGrid.sample(pole.compile(), xRange: -2...2, yRange: -2...2, resolution: 41)
    check(grid.values.count == 41 * 41, "surface grid size")
    check(grid.values[20 * 41 + 20].isNaN, "pole at the origin is NaN")
    check(grid.zRange.upperBound < 100, "pole does not dominate the z-range", "\(grid.zRange)")
}
if let bowl = try? Parser.parseEquation("x^2 + y^2") {
    let grid = SurfaceGrid.sample(bowl.compile(), xRange: -1...1, yRange: -1...1, resolution: 21)
    check(close(grid.zRange.lowerBound, 0) && close(grid.zRange.upperBound, 2), "bowl z-range is [0, 2]", "\(grid.zRange)")
}

// MARK: - Ticks and labels

check(NiceNumbers.step(span: 10, targetCount: 10) == 1, "step 1")
check(close(NiceNumbers.step(span: 2, targetCount: 10), 0.2), "step 0.2")
check(NiceNumbers.step(span: 1000, targetCount: 4) == 200, "step 200")
check(NiceNumbers.label(0.1 + 0.2, step: 0.1) == "0.3", "label 0.3", NiceNumbers.label(0.1 + 0.2, step: 0.1))
check(NiceNumbers.label(-2, step: 1) == "−2", "label −2")
check(NiceNumbers.label(1e-17, step: 0.1) == "0", "label 0")
check(NiceNumbers.label(2_000_000, step: 1_000_000) == "2×10⁶", "label 2×10⁶", NiceNumbers.label(2_000_000, step: 1_000_000))
check(NiceNumbers.ticks(in: -1...1, step: 0.5) == [-1, -0.5, 0, 0.5, 1], "ticks −1…1")
check(close(NiceNumbers.minorStep(for: 2), 0.5), "minor step of 2")

// MARK: - Polar and spherical coordinates

@MainActor func parsed(_ source: String) -> Equation? {
    guard let eq = try? Parser.parseEquation(source) else {
        check(false, "parse \(source)")
        return nil
    }
    return eq
}

@MainActor func rejected(_ source: String) {
    check((try? Parser.parseEquation(source)) == nil, "“\(source)” is rejected")
}

if let eq = parsed("r = \\theta") {
    check(eq.system == .polar && eq.kind == .curve && eq.arguments.map(\.name) == ["theta"], "r = θ is a polar curve")
    check(close(eq.compile()(2.5), 2.5), "r = θ evaluates")
}
if let eq = parsed("r = 2") {
    check(eq.system == .polar && eq.kind == .curve, "r = 2 is a circle")
}
if let eq = parsed("r(\\theta) = 1 + \\cos\\theta") {
    check(eq.system == .polar && eq.lhs == .function(Symbol("r"), [Symbol("theta")]), "r(θ) = … is a polar curve")
}
if let eq = parsed("r = \\sin\\theta\\cos\\varphi") {
    check(eq.system == .spherical && eq.kind == .surface, "r = f(θ, φ) is a spherical surface")
    check(eq.arguments.map(\.name) == ["theta", "varphi"], "spherical arguments are θ, φ", "\(eq.arguments.map(\.name))")
    check(close(eq.compile()(Double.pi / 2, 0), 1), "r(π/2, 0) = 1")
}
if let eq = parsed("r(\\theta, \\phi) = 2") {
    check(eq.system == .spherical && eq.kind == .surface, "r(θ, φ) = 2 is a sphere")
}
if let eq = parsed("r = a\\sin\\theta\\sin\\phi") {
    check(eq.system == .spherical && eq.parameters.map(\.name) == ["a"], "parameters stay parameters in spherical")
}
check(parsed("\\sin x")?.system == .cartesian, "bare input is Cartesian")
check(parsed("\\theta")?.system == .cartesian, "a bare θ is not polar")
check(parsed("f(\\theta) = \\theta")?.system == .cartesian, "f(θ) is not polar")
check(parsed("g(\\theta, \\phi) = 1")?.system == .cartesian, "g(θ, φ) is not spherical")
check(parsed("\\sin\\theta\\cos\\phi")?.system == .cartesian, "φ is a parameter without r =")
rejected("r = t")
rejected("r = x")
rejected("r(t) = t")
rejected("r(\\theta, \\phi, x) = 1")
rejected("r(\\phi) = 1")
rejected("r(\\theta) = \\phi")

let ptPolar = Coordinates.polar(r: 2, theta: Double.pi / 2)
check(close(ptPolar.x, 0) && close(ptPolar.y, 2), "polar (2, π/2) is (0, 2)", "\(ptPolar)")
let ptNegative = Coordinates.polar(r: -1, theta: 0)
check(close(ptNegative.x, -1) && close(ptNegative.y, 0), "negative r points the other way")
let ptEquator = Coordinates.spherical(r: 1, theta: Double.pi / 2, phi: Double.pi / 2)
check(close(ptEquator.x, 0) && close(ptEquator.y, 1) && close(ptEquator.z, 0), "spherical (1, π/2, π/2) is (0, 1, 0)")
let ptPole = Coordinates.spherical(r: 3, theta: 0, phi: 1)
check(close(ptPole.x, 0) && close(ptPole.y, 0) && close(ptPole.z, 3), "spherical θ = 0 is the +z axis")

@MainActor func polarSegments(_ source: String, turns: Double = 1, _ viewport: Viewport = Viewport(xMin: -5, xMax: 5, yMin: -5, yMax: 5)) -> [[SIMD2<Double>]] {
    guard let eq = try? Parser.parseEquation(source) else {
        check(false, "polar sampler parse \(source)")
        return []
    }
    return PolarSampler.sample(eq.compile(), thetaRange: 0...(2 * Double.pi * turns), viewport: viewport,
                               pixelWidth: 800, pixelHeight: 800)
}

let circle = polarSegments("r = 2")
let circleError = circle.flatMap { $0 }.map { Swift.abs(hypot($0.x, $0.y) - 2) }.max() ?? 1
check(circle.count == 1 && circleError < 1e-9, "r = 2 samples a circle of radius 2")
check((circle.first?.count ?? 0) < 1500, "a circle uses a modest number of points", "\(circle.first?.count ?? 0)")

let cardioid = polarSegments("r = 1 + \\cos\\theta")
let cardioidError = cardioid.flatMap { $0 }.map { Swift.abs(hypot($0.x, $0.y) - (1 + Foundation.cos(atan2($0.y, $0.x)))) }.max() ?? 1
check(cardioid.count == 1 && cardioidError < 1e-6, "the cardioid points lie on the curve", "\(cardioidError)")

let lemniscate = polarSegments("r = \\sqrt{\\cos 2\\theta}")
check(lemniscate.count == 3, "√(cos 2θ) is drawn in three pieces over one turn", "got \(lemniscate.count)")
check(polarSegments("r = \\ln\\theta", turns: 1, Viewport(xMin: -5, xMax: 5, yMin: -5, yMax: 5)).count == 1,
      "ln θ (undefined only at θ = 0) is one piece")
let spiral = polarSegments("r = \\theta", turns: 2)
check(spiral.count == 1 && (spiral.first?.count ?? 0) < 4000, "the spiral is one piece", "\(spiral.count)")
check(polarSegments("r = 100", turns: 1).flatMap { $0 }.allSatisfy { Swift.abs($0.x) < 1e5 && Swift.abs($0.y) < 1e5 },
      "points far outside the view stay finite")
check(!polarSegments("r = \\frac{1}{\\cos\\theta}").contains { seg in
    zip(seg, seg.dropFirst()).contains { p, q in
        (p.y > 20 && q.y < -20) || (p.y < -20 && q.y > 20) } }, "no connector across the pole of sec θ")

// MARK: - Summary

print("\(Results.passed) passed, \(Results.failed) failed")
exit(Results.failed == 0 ? 0 : 1)
