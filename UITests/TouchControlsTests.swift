import UIKit
import XCTest

/// Drives the app with real touches (drag, pinch, tap, double tap) and checks what they did.
/// The graphs describe their camera in their accessibility value when the app is launched with
/// `-PlotterUITesting` (see Sources/App/UITesting.swift); the tests read it back.
///
/// On an iPad the function list floats over the left third of the graph, so every gesture is
/// made in the right half of the graph.
@MainActor
final class TouchControlsTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: 2D graph

    func testStartsWithTenUnitsEitherSideOfTheOrigin2D() {
        let app = launch(mode: "curve")
        let plot = graph(app, "plot2d")
        // The default view spans x from -10 to 10 across the graph's width, whatever the device.
        XCTAssertTrue(wait {
            let s = state(plot)
            return abs(s["upp", default: 0] * Double(plot.frame.width) - 20) < 2
                && abs(s["cx", default: 1]) < 0.01 && abs(s["cy", default: 1]) < 0.01
        }, "the default view should be 20 units wide and centred on the origin; \(state(plot)), width \(plot.frame.width)")
    }

    func testDraggingPansTheGraph2D() {
        let app = launch(mode: "curve")
        let plot = graph(app, "plot2d")
        let before = state(plot)

        // Dragging right moves the content right, so the view's centre moves left in the world.
        drag(plot, from: CGVector(dx: 0.6, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.5))
        let movedX = 0.3 * Double(plot.frame.width) * before["upp", default: 1]
        XCTAssertTrue(wait { state(plot)["cx", default: 0] < before["cx", default: 0] - 0.4 * movedX },
                      "dragging right should move the view's centre left by about \(movedX); \(state(plot))")

        // Dragging down moves the content down, so the centre moves up (y grows).
        let mid = settled(plot)
        drag(plot, from: CGVector(dx: 0.8, dy: 0.3), to: CGVector(dx: 0.8, dy: 0.6))
        let movedY = 0.3 * Double(plot.frame.height) * before["upp", default: 1]
        XCTAssertTrue(wait { state(plot)["cy", default: 0] > mid["cy", default: 0] + 0.4 * movedY },
                      "dragging down should move the view's centre up by about \(movedY); \(state(plot))")
    }

    func testPinchingZoomsTheGraph2D() {
        let app = launch(mode: "curve")
        let plot = graph(app, "plot2d")
        let before = state(plot)["upp", default: 1]

        plot.pinch(withScale: 2, velocity: 2)
        XCTAssertTrue(wait { state(plot)["upp", default: 1] < 0.75 * before },
                      "pinching out should zoom in (fewer world units per point); \(state(plot))")

        // XCUITest starts a pinch in with the fingers far apart; on an iPad one of them lands on
        // the function list that floats over the left third of the graph, so it is tried on an
        // iPhone only.
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let zoomedIn = settled(plot)["upp", default: 1]
        plot.pinch(withScale: 0.5, velocity: -1)
        XCTAssertTrue(wait { state(plot)["upp", default: 1] > 1.1 * zoomedIn },
                      "pinching in should zoom out; \(state(plot))")
    }

    func testDoubleTapResetsTheGraph2D() {
        let app = launch(mode: "curve")
        let plot = graph(app, "plot2d")
        let before = state(plot)

        drag(plot, from: CGVector(dx: 0.6, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.4))
        plot.pinch(withScale: 2, velocity: 2)
        XCTAssertTrue(wait { state(plot)["upp", default: 1] < 0.75 * before["upp", default: 1] },
                      "the view should have changed before the reset; \(state(plot))")

        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).doubleTap()
        XCTAssertTrue(wait {
            let s = state(plot)
            return abs(s["upp", default: 0] - before["upp", default: 1]) < 0.02 * before["upp", default: 1]
                && abs(s["cx", default: 1] - before["cx", default: 0]) < 0.05
                && abs(s["cy", default: 1] - before["cy", default: 0]) < 0.05
        }, "a double tap should return to the starting view \(before); now \(state(plot))")
    }

    func testTapReadsAValueAndDraggingClearsIt() {
        let app = launch(mode: "curve")
        let plot = graph(app, "plot2d")
        XCTAssertEqual(state(plot)["hover", default: -1], 0, "no read-out before a tap")

        // The middle of the graph is on the curve y = sin x (it passes through the origin).
        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(wait { state(plot)["hover", default: 0] == 1 }, "a tap on a curve should show its value")

        drag(plot, from: CGVector(dx: 0.6, dy: 0.7), to: CGVector(dx: 0.8, dy: 0.7))
        XCTAssertTrue(wait { state(plot)["hover", default: 1] == 0 }, "starting a drag should hide the read-out")
    }

    // MARK: 3D graph

    func testDraggingRotatesTheGraph3D() {
        let app = launch(mode: "surface")
        let plot = graph(app, "plot3d")
        let before = state(plot)

        // The azimuth turns against a horizontal drag.
        drag(plot, from: CGVector(dx: 0.6, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.5))
        XCTAssertTrue(wait { state(plot)["az", default: 0] < before["az", default: 0] - 0.1 },
                      "dragging right should turn the azimuth down; \(state(plot))")

        // The elevation rises with a drag downwards.
        let mid = settled(plot)
        drag(plot, from: CGVector(dx: 0.8, dy: 0.3), to: CGVector(dx: 0.8, dy: 0.6))
        XCTAssertTrue(wait { state(plot)["el", default: 0] > mid["el", default: 0] + 0.2 },
                      "dragging down should raise the elevation; \(state(plot))")
    }

    func testPinchingZoomsTheGraph3D() {
        let app = launch(mode: "surface")
        let plot = graph(app, "plot3d")
        let before = state(plot)["dist", default: 5.2]

        plot.pinch(withScale: 2, velocity: 2)
        XCTAssertTrue(wait { state(plot)["dist", default: 99] < 0.8 * before },
                      "pinching out should bring the camera closer; \(state(plot))")

        // Pinching in is tried on an iPhone only (see testPinchingZoomsTheGraph2D).
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let closer = settled(plot)["dist", default: 5.2]
        plot.pinch(withScale: 0.5, velocity: -1)
        XCTAssertTrue(wait { state(plot)["dist", default: 0] > 1.1 * closer },
                      "pinching in should move the camera away; \(state(plot))")
    }

    func testDoubleTapResetsTheGraph3D() {
        let app = launch(mode: "surface")
        let plot = graph(app, "plot3d")
        let before = state(plot)

        drag(plot, from: CGVector(dx: 0.6, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.4))
        plot.pinch(withScale: 2, velocity: 2)
        XCTAssertTrue(wait { state(plot)["dist", default: 99] < 0.8 * before["dist", default: 5.2] },
                      "the view should have changed before the reset; \(state(plot))")

        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).doubleTap()
        XCTAssertTrue(wait(timeout: 15) {
            let s = state(plot)
            // The reset turns the short way round, so the azimuth may differ by whole turns.
            let turn = (s["az", default: 9] - before["az", default: 0]).remainder(dividingBy: 2 * .pi)
            return abs(turn) < 0.05
                && abs(s["el", default: 9] - before["el", default: 0]) < 0.05
                && abs(s["dist", default: 99] - before["dist", default: 5.2]) < 0.05
        }, "a double tap should animate back to the starting view \(before); now \(state(plot))")
    }

    // MARK: Navigation

    func testBackButtonShowsTheFunctionListOnAnIPhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the list is always visible on an iPad")
        let app = launch(mode: "curve")
        XCTAssertTrue(graph(app, "plot2d").exists, "an iPhone opens on the graph")

        let back = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'back' OR identifier CONTAINS[c] 'back'"))
            .firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the graph has a back button")
        back.tap()
        XCTAssertTrue(app.buttons["Add Function"].firstMatch.waitForExistence(timeout: 10),
                      "the back button shows the function list")
    }

    // MARK: Helpers

    private func launch(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PlotterUITesting", "-PlotterStartMode", mode]
        app.launch()
        return app
    }

    private func graph(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(identifier) did not appear")
        // The graphs report their size and camera only after the first layout.
        XCTAssertTrue(wait { !(self.state(element).isEmpty) }, "\(identifier) reports no state")
        return element
    }

    /// The `key=value` pairs of the graph's accessibility value.
    private func state(_ element: XCUIElement) -> [String: Double] {
        var result: [String: Double] = [:]
        for part in ((element.value as? String) ?? "").split(separator: " ") {
            let pair = part.split(separator: "=")
            if pair.count == 2, let number = Double(pair[1]) { result[String(pair[0])] = number }
        }
        return result
    }

    /// The state once it has stopped changing (a gesture's effect, or the camera's inertia, can
    /// still be under way when the gesture call returns).
    private func settled(_ element: XCUIElement) -> [String: Double] {
        var last = state(element)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            let now = state(element)
            if now == last { return now }
            last = now
        }
        return last
    }

    /// A one-finger drag between two points given as fractions of the graph's size.
    private func drag(_ element: XCUIElement, from: CGVector, to: CGVector) {
        element.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: to))
        // A drag must not take the user away from the graph (the system's swipe back did on an iPhone).
        if !element.waitForExistence(timeout: 5) {
            let screen = String(XCUIApplication().debugDescription.prefix(2500))
            XCTFail("the graph is gone after a drag; the screen shows:\n\(screen)")
        }
    }

    @discardableResult
    private func wait(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
