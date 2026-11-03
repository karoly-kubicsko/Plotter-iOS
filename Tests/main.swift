// Test runner for the math engine. build.sh compiles it together with
// Sources/Math and runs it; a non-zero exit status fails the build.
//
//   ./build.sh --test

import Foundation

@MainActor var passed = 0
@MainActor var failed = 0

@MainActor func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
    } else {
        failed += 1
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
    ("r = \\theta", nil),
    ("f(x, y, z) = x", nil),
    ("x_", nil),
    ("x # 2", 2..<3),
    ("\\frac{1}", nil),
    ("2 + * 3", 4..<5),
    ("()", nil),
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

let reciprocal = segments("\\frac{1}{x}", view)
check(reciprocal.count == 2, "1/x has 2 branches", "got \(reciprocal.count)")
check(!hasVerticalJump(reciprocal, limit: 5), "1/x has no vertical connector")

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

// MARK: - Summary

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
