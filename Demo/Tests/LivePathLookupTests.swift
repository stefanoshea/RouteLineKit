import MapKit
import RouteLineKit
import XCTest
@testable import RouteLineDemo

final class LivePathLookupTests: XCTestCase {
    /// Checks that a small finger offset still matches a public walk on current Apple Maps.
    @MainActor
    func testWalkingRouteInHydePark() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROUTELINE_LIVE_LOOKUP"] == "1")

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: -33.8710, longitude: 151.2118), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: -33.8744, longitude: 151.2101), address: nil)
        request.transportType = .walking
        let result = try await MKDirections(request: request).calculate()
        let path = try XCTUnwrap(result.routes.first)
        let line = path.polyline
        var points = Array(repeating: CLLocationCoordinate2D(), count: line.pointCount)
        line.getCoordinates(&points, range: NSRange(location: 0, length: points.count))
        let drawing = points.enumerated().map { index, point in
            Coordinate(latitude: point.latitude + sin(Double(index)) * 0.000035, longitude: point.longitude)
        }
        let resolved = try await AppleWalkingPaths().resolve(drawing)
        XCTAssertGreaterThan(resolved.snappedDistanceMeters, path.distance * 0.7)
        XCTAssertLessThan(resolved.distanceMeters, path.distance * 1.3)
    }
}
