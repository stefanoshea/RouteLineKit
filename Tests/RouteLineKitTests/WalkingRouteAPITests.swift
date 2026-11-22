#if canImport(MapKit)
import RouteLineKit
import XCTest

final class WalkingRouteAPITests: XCTestCase {
    func testRejectsEmptyDrawingThroughPublicAPI() async {
        do {
            _ = try await RouteLineKit.walkingRoute(for: [])
            XCTFail("Expected an empty drawing to be rejected.")
        } catch {
            XCTAssertEqual(error as? WalkingRouteError, .unsupportedDrawing)
        }
    }
}
#endif
