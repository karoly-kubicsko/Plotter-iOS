import Foundation

/// A rectangular region of the plane, in world units.
public struct Viewport: Sendable, Equatable, Codable {
    public var xMin: Double
    public var xMax: Double
    public var yMin: Double
    public var yMax: Double

    public init(xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
    }

    public var width: Double { xMax - xMin }
    public var height: Double { yMax - yMin }
}

// MARK: - Adaptive curve sampling

/// Samples y = f(x) adaptively for drawing.
///
/// The visible x-range is seeded with one interval per ~4 pixels. Each interval is
/// bisected while the midpoint lies more than a quarter pixel (perpendicular, in
/// screen space) from the chord, so curved regions get more points and straight
/// ones fewer. Non-finite values (domain errors, poles) are located by bisection and
/// end the current polyline; a jump that survives bisection down to a tiny interval
/// is treated as a discontinuity (asymptote or step) and also breaks the polyline,
/// so no vertical connector lines are drawn.
public enum CurveSampler {
    public static func sample(
        _ f: CompiledFunction,
        viewport: Viewport,
        pixelWidth: Double,
        pixelHeight: Double,
        maxEvaluations: Int = 40_000
    ) -> [[SIMD2<Double>]] {
        guard viewport.width > 0, viewport.height > 0, pixelWidth >= 1, pixelHeight >= 1 else { return [] }
        var state = State(
            f: f,
            sx: pixelWidth / viewport.width,
            sy: pixelHeight / viewport.height,
            yTop: viewport.yMax,
            yBottom: viewport.yMin,
            clampMargin: viewport.height * 4,
            budget: maxEvaluations)

        let seeds = max(16, Int((pixelWidth / 4).rounded(.up)))
        let dx = viewport.width / Double(seeds)
        var a = viewport.xMin
        var fa = f(a)
        if fa.isFinite { state.emit(a, fa) }
        for i in 1...seeds {
            let b = i == seeds ? viewport.xMax : viewport.xMin + Double(i) * dx
            let fb = f(b)
            state.refine(a, fa, b, fb, depth: 0)
            a = b
            fa = fb
        }
        state.finishSegment()
        return state.segments
    }

    private struct State {
        let f: CompiledFunction
        let sx: Double
        let sy: Double
        let yTop: Double
        let yBottom: Double
        let clampMargin: Double
        var budget: Int
        var segments: [[SIMD2<Double>]] = []
        var current: [SIMD2<Double>] = []

        static let maxDepth = 14
        static let tolerance = 0.25      // pixels
        static let jumpThreshold = 2.0   // pixels, tested on intervals at maximum depth
        /// Longest vertical step accepted as a straight piece. Near a jump the chord is
        /// almost vertical, so the midpoint is close to it although the curve is not
        /// continuous there; limiting the step forces further bisection, and a jump that
        /// survives to the maximum depth breaks the polyline.
        static let maxStep = 24.0        // pixels

        mutating func emit(_ x: Double, _ y: Double) {
            let clamped = Swift.min(Swift.max(y, yBottom - clampMargin), yTop + clampMargin)
            current.append(SIMD2(x, clamped))
        }

        mutating func finishSegment() {
            if current.count >= 2 { segments.append(current) }
            current.removeAll(keepingCapacity: true)
        }

        /// Precondition: `a` has been emitted if `fa` is finite.
        /// Postcondition: `b` has been emitted if `fb` is finite.
        mutating func refine(_ a: Double, _ fa: Double, _ b: Double, _ fb: Double, depth: Int) {
            let aFinite = fa.isFinite
            let bFinite = fb.isFinite

            if !aFinite && !bFinite {
                // Look shallowly for small defined islands inside an undefined stretch.
                guard depth < 2, budget > 0 else { return }
                let m = 0.5 * (a + b)
                let fm = f(m)
                budget -= 1
                refine(a, fa, m, fm, depth: depth + 1)
                refine(m, fm, b, fb, depth: depth + 1)
                return
            }

            if depth >= Self.maxDepth || budget <= 0 {
                if aFinite && bFinite {
                    if Swift.abs(fb - fa) * sy > Self.jumpThreshold { finishSegment() }
                    emit(b, fb)
                } else if bFinite {
                    finishSegment()
                    emit(b, fb)
                } else {
                    finishSegment()
                }
                return
            }

            let m = 0.5 * (a + b)
            let fm = f(m)
            budget -= 1

            if aFinite && bFinite && fm.isFinite {
                let above = fa > yTop && fb > yTop && fm > yTop
                let below = fa < yBottom && fb < yBottom && fm < yBottom
                if above || below {
                    emit(b, fb)
                    return
                }
                if Swift.abs(fb - fa) * sy <= Self.maxStep, deviation(a, fa, m, fm, b, fb) < Self.tolerance {
                    emit(b, fb)
                    return
                }
            }
            refine(a, fa, m, fm, depth: depth + 1)
            refine(m, fm, b, fb, depth: depth + 1)
        }

        /// Perpendicular distance in pixels of the midpoint from the chord.
        func deviation(_ a: Double, _ fa: Double, _ m: Double, _ fm: Double, _ b: Double, _ fb: Double) -> Double {
            let ax = a * sx, ay = fa * sy
            let bx = b * sx - ax, by = fb * sy - ay
            let mx = m * sx - ax, my = fm * sy - ay
            let length = (bx * bx + by * by).squareRoot()
            guard length > 0, length.isFinite else { return 0 }
            return Swift.abs(bx * my - by * mx) / length
        }
    }
}

// MARK: - Polar and spherical coordinates

/// Conversions from polar and spherical coordinates to Cartesian ones.
public enum Coordinates {
    /// (r, θ) to (x, y). A negative r points to the opposite side.
    public static func polar(r: Double, theta: Double) -> SIMD2<Double> {
        SIMD2(r * Foundation.cos(theta), r * Foundation.sin(theta))
    }

    /// (r, θ, φ) to (x, y, z), with θ the polar angle from the +z axis and φ the azimuth.
    public static func spherical(r: Double, theta: Double, phi: Double) -> SIMD3<Double> {
        let s = r * Foundation.sin(theta)
        return SIMD3(s * Foundation.cos(phi), s * Foundation.sin(phi), r * Foundation.cos(theta))
    }
}

/// Samples the polar curve r = f(θ) adaptively for drawing, in the same way as
/// `CurveSampler`: intervals of θ are bisected while the midpoint of the arc lies
/// more than a quarter pixel from its chord. Undefined or enormous radii (poles)
/// and jumps end the current polyline.
public enum PolarSampler {
    public static func sample(
        _ f: CompiledFunction,
        thetaRange: ClosedRange<Double>,
        viewport: Viewport,
        pixelWidth: Double,
        pixelHeight: Double,
        maxEvaluations: Int = 60_000
    ) -> [[SIMD2<Double>]] {
        guard viewport.width > 0, viewport.height > 0, pixelWidth >= 1, pixelHeight >= 1,
              thetaRange.upperBound > thetaRange.lowerBound else { return [] }
        let reach = Swift.max(Swift.abs(viewport.xMin), Swift.abs(viewport.xMax),
                              Swift.abs(viewport.yMin), Swift.abs(viewport.yMax))
        var state = State(
            f: f, viewport: viewport, sx: pixelWidth / viewport.width, sy: pixelHeight / viewport.height,
            limit: 1e3 * (reach + viewport.width + viewport.height), budget: maxEvaluations)

        let span = thetaRange.upperBound - thetaRange.lowerBound
        let seeds = Swift.max(64, Int((360 * span / (2 * Double.pi)).rounded(.up)))
        var a = thetaRange.lowerBound
        var pa = state.point(a)
        if let pa { state.emit(pa) }
        for i in 1...seeds {
            let b = i == seeds ? thetaRange.upperBound : thetaRange.lowerBound + span * Double(i) / Double(seeds)
            let pb = state.point(b)
            state.refine(a, pa, b, pb, depth: 0)
            a = b
            pa = pb
        }
        state.finishSegment()
        return state.segments
    }

    private struct State {
        let f: CompiledFunction
        let viewport: Viewport
        let sx: Double
        let sy: Double
        let limit: Double
        var budget: Int
        var segments: [[SIMD2<Double>]] = []
        var current: [SIMD2<Double>] = []

        static let maxDepth = 14
        static let tolerance = 0.25     // pixels
        static let jumpThreshold = 2.0  // pixels, tested on intervals at maximum depth
        static let maxStep = 24.0       // pixels; longer chords are bisected further

        func point(_ theta: Double) -> SIMD2<Double>? {
            let r = f(theta)
            guard r.isFinite, Swift.abs(r) < limit else { return nil }
            return Coordinates.polar(r: r, theta: theta)
        }

        mutating func emit(_ p: SIMD2<Double>) {
            // Far-away points are clamped so the path stays within sensible numbers.
            let mx = viewport.width * 4, my = viewport.height * 4
            current.append(SIMD2(Swift.min(Swift.max(p.x, viewport.xMin - mx), viewport.xMax + mx),
                                 Swift.min(Swift.max(p.y, viewport.yMin - my), viewport.yMax + my)))
        }

        mutating func finishSegment() {
            if current.count >= 2 { segments.append(current) }
            current.removeAll(keepingCapacity: true)
        }

        func screenDistance(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double {
            let dx = (q.x - p.x) * sx, dy = (q.y - p.y) * sy
            return (dx * dx + dy * dy).squareRoot()
        }

        func isOffscreen(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ m: SIMD2<Double>) -> Bool {
            (p.x < viewport.xMin && q.x < viewport.xMin && m.x < viewport.xMin)
                || (p.x > viewport.xMax && q.x > viewport.xMax && m.x > viewport.xMax)
                || (p.y < viewport.yMin && q.y < viewport.yMin && m.y < viewport.yMin)
                || (p.y > viewport.yMax && q.y > viewport.yMax && m.y > viewport.yMax)
        }

        /// Perpendicular distance in pixels of `m` from the chord `a`–`b`.
        func deviation(_ a: SIMD2<Double>, _ m: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            let bx = (b.x - a.x) * sx, by = (b.y - a.y) * sy
            let mx = (m.x - a.x) * sx, my = (m.y - a.y) * sy
            let length = (bx * bx + by * by).squareRoot()
            guard length > 0, length.isFinite else { return (mx * mx + my * my).squareRoot() }
            return Swift.abs(bx * my - by * mx) / length
        }

        /// Precondition: `a` has been emitted if `pa` is defined.
        /// Postcondition: `b` has been emitted if `pb` is defined.
        mutating func refine(_ a: Double, _ pa: SIMD2<Double>?, _ b: Double, _ pb: SIMD2<Double>?, depth: Int) {
            if pa == nil && pb == nil {
                guard depth < 2, budget > 0 else { return }
                let m = 0.5 * (a + b)
                let pm = point(m)
                budget -= 1
                refine(a, pa, m, pm, depth: depth + 1)
                refine(m, pm, b, pb, depth: depth + 1)
                return
            }

            if depth >= Self.maxDepth || budget <= 0 {
                if let pa, let pb {
                    if screenDistance(pa, pb) > Self.jumpThreshold { finishSegment() }
                    emit(pb)
                } else if let pb {
                    finishSegment()
                    emit(pb)
                } else {
                    finishSegment()
                }
                return
            }

            let m = 0.5 * (a + b)
            let pm = point(m)
            budget -= 1

            if let pa, let pb, let pm {
                if isOffscreen(pa, pb, pm) {
                    emit(pb)
                    return
                }
                if screenDistance(pa, pb) <= Self.maxStep, deviation(pa, pm, pb) < Self.tolerance {
                    emit(pb)
                    return
                }
            }
            refine(a, pa, m, pm, depth: depth + 1)
            refine(m, pm, b, pb, depth: depth + 1)
        }
    }
}

// MARK: - Surface sampling

/// z = f(x, y) sampled on a regular grid.
public struct SurfaceGrid: Sendable {
    /// Samples per side.
    public let resolution: Int
    public let xRange: ClosedRange<Double>
    public let yRange: ClosedRange<Double>
    /// Row-major values, index `j * resolution + i` for x_i, y_j. NaN where undefined.
    public let values: [Float]
    /// A z-range that ignores extreme outliers (poles), for scaling the plot.
    public let zRange: ClosedRange<Double>

    public static func sample(
        _ f: CompiledFunction,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        resolution: Int
    ) -> SurfaceGrid {
        let n = max(2, resolution)
        var values = [Float](repeating: .nan, count: n * n)
        let dx = (xRange.upperBound - xRange.lowerBound) / Double(n - 1)
        let dy = (yRange.upperBound - yRange.lowerBound) / Double(n - 1)
        var finite: [Double] = []
        finite.reserveCapacity(n * n)
        for j in 0..<n {
            let y = yRange.lowerBound + Double(j) * dy
            for i in 0..<n {
                let x = xRange.lowerBound + Double(i) * dx
                let z = f(x, y)
                if z.isFinite, Swift.abs(z) < 1e30 {
                    values[j * n + i] = Float(z)
                    finite.append(z)
                }
            }
        }
        return SurfaceGrid(resolution: n, xRange: xRange, yRange: yRange, values: values,
                           zRange: robustRange(&finite))
    }

    /// Uses the full range unless a few extreme values (e.g. near a pole) would squash
    /// everything else; then it uses the 1st–99th percentile range, widened by 10 %.
    static func robustRange(_ values: inout [Double]) -> ClosedRange<Double> {
        guard !values.isEmpty else { return -1...1 }
        values.sort()
        let lo = values[0], hi = values[values.count - 1]
        let q1 = values[Int(Double(values.count - 1) * 0.01)]
        let q99 = values[Int(Double(values.count - 1) * 0.99)]
        var range: ClosedRange<Double>
        if hi - lo <= 1.5 * (q99 - q1) || q99 == q1 {
            range = lo...hi
        } else {
            let pad = 0.1 * (q99 - q1)
            range = (q1 - pad)...(q99 + pad)
        }
        if range.upperBound - range.lowerBound < 1e-9 {
            let c = range.lowerBound
            range = (c - 1)...(c + 1)
        }
        return range
    }
}

// MARK: - Axis ticks

/// "Nice" tick steps (1, 2, 5 × 10ⁿ) and clean labels.
public enum NiceNumbers {
    /// A step from the 1-2-5 sequence giving roughly `targetCount` intervals over `span`.
    public static func step(span: Double, targetCount: Double) -> Double {
        guard span > 0, span.isFinite, targetCount > 0 else { return 1 }
        let raw = span / targetCount
        let exponent = Foundation.floor(Foundation.log10(raw))
        let magnitude = Foundation.pow(10, exponent)
        let fraction = raw / magnitude
        let nice: Double
        if fraction < 1.5 { nice = 1 } else if fraction < 3 { nice = 2 } else if fraction < 7 { nice = 5 } else { nice = 10 }
        return nice * magnitude
    }

    /// The minor step that subdivides a major step: 1 → 0.2, 2 → 0.5, 5 → 1.
    public static func minorStep(for step: Double) -> Double {
        let magnitude = Foundation.pow(10, Foundation.floor(Foundation.log10(step) + 1e-9))
        let mantissa = (step / magnitude).rounded()
        return mantissa == 2 ? step / 4 : step / 5
    }

    /// Multiples of `step` inside the range.
    public static func ticks(in range: ClosedRange<Double>, step: Double) -> [Double] {
        guard step > 0, step.isFinite else { return [] }
        let first = Foundation.ceil(range.lowerBound / step)
        let last = Foundation.floor(range.upperBound / step)
        guard last >= first, last - first < 10_000 else { return [] }
        return stride(from: first, through: last, by: 1).map { $0 * step }
    }

    /// A label with exactly as many decimals as the step needs: never "0.30000000000000004".
    public static func label(_ value: Double, step: Double) -> String {
        if Swift.abs(value) < step * 1e-6 { return "0" }
        let stepExponent = Int(Foundation.floor(Foundation.log10(step) + 1e-9))
        let valueExponent = Int(Foundation.floor(Foundation.log10(Swift.abs(value)) + 1e-9))
        let text: String
        if valueExponent >= 6 || stepExponent <= -5 {
            let mantissa = value / Foundation.pow(10, Double(valueExponent))
            let decimals = Swift.max(0, valueExponent - stepExponent)
            let m = String(format: "%.\(Swift.min(decimals, 6))f", mantissa)
            text = "\(m)×10" + superscript(valueExponent)
        } else {
            text = String(format: "%.\(Swift.max(0, -stepExponent))f", value)
        }
        return text.replacingOccurrences(of: "-", with: "−")
    }

    static func superscript(_ n: Int) -> String {
        let digits: [Character] = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
        let body = String(Swift.abs(n)).compactMap { c in c.wholeNumberValue.map { digits[$0] } }
        return (n < 0 ? "⁻" : "") + String(body)
    }
}
