import Foundation
import XCTest

@MainActor
final class AppleWalkingRouteUITests: XCTestCase {
    func testNearbyWalkingLegsShowPartialMatchAndPreserveDrawing() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchEnvironment["ROUTELINE_UI_TEST_APPLE_GAP"] = "1"
        app.launch()

        let summary = app.staticTexts["planner.route.summary"]
        let distance = app.staticTexts["planner.distance"]
        let apple = app.buttons["planner.match.apple"]
        guard apple.waitForExistence(timeout: 10) else {
            XCTFail("The two-leg drawing did not expose the Apple walking paths action.")
            return
        }
        XCTAssertEqual(summary.label, "Drawn line")
        let drawnDistance = distance.label
        XCTAssertFalse(drawnDistance.isEmpty)
        apple.tap()

        let compare = app.buttons["planner.compare"]
        guard compare.waitForExistence(timeout: 10) else {
            let status = app.staticTexts["planner.match.status"]
            XCTFail(status.exists ? status.label : "Apple walking paths did not show a comparison.")
            return
        }
        XCTAssertEqual(summary.label, "Partial Apple Maps match")
        XCTAssertTrue(app.staticTexts["Matched path"].exists)
        XCTAssertTrue(app.staticTexts["Unmatched drawing"].exists)

        compare.tap()
        XCTAssertEqual(summary.label, "Drawn line")
        XCTAssertEqual(distance.label, drawnDistance)
        XCTAssertFalse(app.staticTexts["Unmatched drawing"].exists)
        compare.tap()
        XCTAssertEqual(summary.label, "Partial Apple Maps match")
        XCTAssertTrue(app.staticTexts["Unmatched drawing"].exists)
        #else
        throw XCTSkip("The two-leg walking directions fixture is available only on a simulator.")
        #endif
    }

    func testWalkingConnectorCompletesMatchAndCanBeCleared() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchEnvironment["ROUTELINE_UI_TEST_APPLE_CONNECTOR"] = "1"
        app.launch()

        let apple = app.buttons["planner.match.apple"]
        guard apple.waitForExistence(timeout: 10) else {
            XCTFail("The two-leg drawing did not expose the walking paths action.")
            return
        }
        XCTAssertEqual(apple.label, "Match walking paths")
        let summary = app.staticTexts["planner.route.summary"]
        let distance = app.staticTexts["planner.distance"]
        XCTAssertEqual(summary.label, "Drawn line")
        let drawnDistance = distance.label
        apple.tap()

        let compare = app.buttons["planner.compare"]
        guard compare.waitForExistence(timeout: 10) else {
            let status = app.staticTexts["planner.match.status"]
            XCTFail(status.exists ? status.label : "The repaired walking route did not show a comparison.")
            return
        }
        XCTAssertEqual(summary.label, "Apple Maps walking route")
        XCTAssertFalse(app.staticTexts["Unmatched drawing"].exists)
        XCTAssertTrue(app.staticTexts["Matched path"].exists || app.staticTexts["Approximate match"].exists)

        compare.tap()
        XCTAssertEqual(summary.label, "Drawn line")
        XCTAssertEqual(distance.label, drawnDistance)
        compare.tap()
        XCTAssertEqual(summary.label, "Apple Maps walking route")

        app.buttons["planner.clear"].tap()
        XCTAssertTrue(compare.waitForNonExistence(timeout: 5))
        XCTAssertFalse(distance.exists)
        XCTAssertTrue(app.staticTexts["planner.hint"].exists)
        #else
        throw XCTSkip("The walking connector fixture is available only on a simulator.")
        #endif
    }

    func testLiveAppleWalkingRouteFromHydeParkGesture() throws {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["ROUTELINE_LIVE_LOOKUP"] == "1"
                || environment["TEST_RUNNER_ROUTELINE_LIVE_LOOKUP"] == "1"
        )
        let app = XCUIApplication()
        app.launchEnvironment["ROUTELINE_UI_TEST_APPLE_VIEWPORT"] = "1"
        app.launch()

        let draw = app.buttons["planner.draw"]
        let map = app.descendants(matching: .any)["planner.map"].firstMatch
        guard draw.waitForExistence(timeout: 10), map.waitForExistence(timeout: 5) else {
            XCTFail("The Sydney map viewport did not open.")
            return
        }
        draw.tap()

        // Trace the path south from Archibald Fountain using the north-up test map.
        let center = map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let halfLength = map.frame.width * 0.16
        let start = center.withOffset(CGVector(dx: halfLength * 0.10, dy: -halfLength))
        let end = center.withOffset(CGVector(dx: -halfLength * 0.10, dy: halfLength))
        start.press(forDuration: 0.1, thenDragTo: end)

        let apple = app.buttons["planner.match.apple"]
        let summary = app.staticTexts["planner.route.summary"]
        let distance = app.staticTexts["planner.distance"]
        guard apple.waitForExistence(timeout: 5) else {
            XCTFail("Drawing the Hyde Park path did not expose the Apple walking paths action.")
            return
        }
        XCTAssertEqual(summary.label, "Drawn line")
        let drawnDistance = distance.label
        XCTAssertFalse(drawnDistance.isEmpty)
        apple.tap()

        let compare = app.buttons["planner.compare"]
        guard compare.waitForExistence(timeout: 45) else {
            let status = app.staticTexts["planner.match.status"]
            XCTFail(status.exists ? status.label : "Apple Maps did not match the drawn Hyde Park path.")
            return
        }
        XCTAssertEqual(summary.label, "Apple Maps walking route")
        XCTAssertTrue(app.staticTexts["Matched path"].exists || app.staticTexts["Approximate match"].exists)
        XCTAssertFalse(app.staticTexts["Unmatched drawing"].exists)
        XCTAssertFalse(distance.label.isEmpty)
        compare.tap()
        XCTAssertEqual(summary.label, "Drawn line")
        XCTAssertEqual(distance.label, drawnDistance)
        #else
        throw XCTSkip("The public Sydney test viewport is available only on a simulator.")
        #endif
    }
}
