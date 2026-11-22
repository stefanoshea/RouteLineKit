#if canImport(MapKit)
import MapKit
#endif
import RouteLineKit
import Testing

#if canImport(MapKit)
@Test func rejectsEmptyDrawingThroughPublicAPI() async {
    await #expect(throws: WalkingRouteError.unsupportedDrawing) {
        _ = try await RouteLineKit.walkingRoute(for: [])
    }
}
#endif

@Test func publicValueTypesSupportDirectConstructionAndHashing() {
    let start = Coordinate(latitude: -33.8697, longitude: 151.2069)
    let end = Coordinate(latitude: -33.8700, longitude: 151.2072)
    let nodes = [Node(id: 1, coordinate: start), Node(id: 2, coordinate: end)]
    let ways = [Way(id: 10, nodeIDs: [1, 2])]

    let match = Match(
        coordinates: [start, end],
        distanceMeters: 42,
        distanceMetersByWayID: [10: 42],
        rmsOffsetMeters: 0.5)
    let segment = StrokeSegment(kind: .snapped, coordinates: [start, end], distanceMeters: 42)
    let resolved = ResolvedStroke(segments: [segment])

    #expect(Set(nodes).count == 2)
    #expect(Set(ways).count == 1)
    #expect(Set([match]).count == 1)
    #expect(Set([segment]).count == 1)
    #expect(Set([StrokeSegment.Kind.snapped, .approximate, .freehand]).count == 3)
    #expect(Set([resolved]).count == 1)
    #expect(resolved.distanceMeters == 42)

    let validMatcher = StrokeMatcher(nodes: nodes, ways: ways)
    #expect(!validMatcher.isEmpty)
    #expect(StrokeMatcher(nodes: [nodes[0], nodes[0]], ways: ways).isEmpty)
    #expect(StrokeMatcher(nodes: nodes, ways: [ways[0], ways[0]]).isEmpty)

    #if canImport(MapKit)
    let errors: Set<WalkingRouteError> = [
        .unsupportedDrawing, .serviceUnavailable, .serviceBusy, .noWalkingRoute, .doesNotFollowDrawing,
    ]
    #expect(errors.count == 5)

    let polyline = segment.polyline
    #expect(polyline.pointCount == 2)
    var positions = Array(repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
    polyline.getCoordinates(&positions, range: NSRange(location: 0, length: positions.count))
    #expect(abs(positions[0].latitude - start.latitude) < 1e-7)
    #expect(abs(positions[1].longitude - end.longitude) < 1e-7)
    #endif
}
