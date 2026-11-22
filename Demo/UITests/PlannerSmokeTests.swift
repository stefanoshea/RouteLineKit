import XCTest

@MainActor
final class PlannerSmokeTests: XCTestCase {
    func testDrawAndClearWithoutPathMatching() {
        let app = XCUIApplication()
        app.launch()

        let draw = app.buttons["planner.draw"]
        guard draw.waitForExistence(timeout: 10) else {
            XCTFail("The planner did not open.")
            return
        }
        draw.tap()
        XCTAssertEqual(app.staticTexts["planner.hint"].label, "Trace your route on the map.")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.53))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.43))
        start.press(forDuration: 0.1, thenDragTo: end)

        let match = app.buttons["planner.match.apple"]
        let clear = app.buttons["planner.clear"]
        guard clear.waitForExistence(timeout: 5) else {
            XCTFail("Drawing on the map did not expose Clear.")
            return
        }
        XCTAssertTrue(match.isEnabled)
        XCTAssertEqual(match.label, "Match walking paths")
        XCTAssertTrue(app.staticTexts["planner.distance"].exists)
        clear.tap()

        XCTAssertTrue(match.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["planner.distance"].exists)
        XCTAssertTrue(app.staticTexts["planner.hint"].exists)
    }

    func testDenyingLocationKeepsThePlannerAvailable() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        defer {
            app.terminate()
            app.resetAuthorizationStatus(for: .location)
        }
        app.launch()

        let location = app.buttons["planner.location"]
        guard location.waitForExistence(timeout: 10) else {
            XCTFail("The location control did not appear.")
            return
        }
        location.tap()

        let deny = locationPromptButton(labels: ["Don’t Allow", "Don't Allow"])
        if deny.waitForExistence(timeout: 5) {
            deny.tap()
        }

        let status = app.staticTexts["planner.location.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Location access is unavailable. You can move the map to your starting point.")
        let draw = app.buttons["planner.draw"]
        XCTAssertTrue(draw.isEnabled)
        draw.tap()
        XCTAssertEqual(app.staticTexts["planner.hint"].label, "Trace your route on the map.")
    }

    func testAllowedLocationRecentersOnAnAppScopedSimulatedPosition() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        defer {
            app.terminate()
            app.resetAuthorizationStatus(for: .location)
        }
        app.launchEnvironment["ROUTELINE_UI_TEST_LOCATION"] = "1"
        app.launch()

        let location = app.buttons["planner.location"]
        guard location.waitForExistence(timeout: 10) else {
            XCTFail("The location control did not appear.")
            return
        }
        location.tap()

        let allow = locationPromptButton(labels: ["Allow While Using App"])
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
        let positioned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Location available on map"),
            object: location
        )
        wait(for: [positioned], timeout: 10)
        XCTAssertFalse(app.staticTexts["planner.location.status"].exists)
        #else
        throw XCTSkip("The app-scoped location simulation is available only on a simulator.")
        #endif
    }

    private func locationPromptButton(labels: [String]) -> XCUIElement {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .alerts.buttons.matching(NSPredicate(format: "label IN %@", labels))
            .firstMatch
    }
}
