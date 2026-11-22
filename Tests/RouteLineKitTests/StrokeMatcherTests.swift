import Testing

@testable import RouteLineKit

#if canImport(MapKit)
    import MapKit
#endif

private func coordinate(_ x: Double, _ y: Double) -> Coordinate {
    Coordinate(latitude: y / 111_195, longitude: x / 111_195)
}

private func node(_ id: Int64, _ x: Double, _ y: Double) -> Node {
    Node(id: id, coordinate: coordinate(x, y))
}

@Test func joinsOnlyWaysWithSharedNodeIDs() throws {
    let nodes = [node(1, -20, 0), node(2, 0, 0), node(3, 0, 0), node(4, 20, 0)]
    let west = Way(id: 1, nodeIDs: [1, 2])
    let stroke = [coordinate(-19, 0), coordinate(0, 0), coordinate(19, 0)]

    let connected = StrokeMatcher(nodes: nodes, ways: [west, Way(id: 2, nodeIDs: [2, 4])])
    let result = try #require(connected.match(stroke))
    #expect(Set(result.distanceMetersByWayID.keys) == [1, 2])
    #expect(abs(result.distanceMeters - 38) < 0.01)
    #expect(result.coordinates.contains(coordinate(0, 0)))

    let disconnected = StrokeMatcher(nodes: nodes, ways: [west, Way(id: 2, nodeIDs: [3, 4])])
    #expect(disconnected.match(stroke) == nil)
}

@Test func followsCloserParallelWayAndBreaksExactTiesDeterministically() throws {
    let nodes = [node(1, 0, 0), node(2, 100, 0), node(3, 0, 8), node(4, 100, 8)]
    let lower = Way(id: 10, nodeIDs: [1, 2])
    let upper = Way(id: 20, nodeIDs: [3, 4])
    let matcher = StrokeMatcher(nodes: nodes, ways: [upper, lower])
    let nearLower = [coordinate(0, 1), coordinate(20, -1), coordinate(60, 2), coordinate(100, 0)]
    let result = try #require(matcher.match(nearLower))
    #expect(Set(result.distanceMetersByWayID.keys) == [10])

    let center = [coordinate(0, 4), coordinate(50, 4), coordinate(100, 4)]
    let first = try #require(matcher.match(center))
    let reordered = StrokeMatcher(nodes: nodes.reversed(), ways: [lower, upper])
    #expect(first == reordered.match(center))
}

@Test func rejectsMalformedOrDegenerateInputAndAbruptJumps() {
    let a = node(1, 0, 0)
    let b = node(2, 400, 0)
    let way = Way(id: 1, nodeIDs: [1, 2])
    let shortStroke = [coordinate(0, 0), coordinate(30, 0)]
    let matcher = StrokeMatcher(nodes: [a, b], ways: [way])

    #expect(matcher.match([]) == nil)
    #expect(matcher.match([a.coordinate, a.coordinate]) == nil)
    #expect(matcher.match([a.coordinate, Coordinate(latitude: .nan, longitude: 0)]) == nil)
    #expect(matcher.match([a.coordinate, b.coordinate]) == nil)
    #expect(StrokeMatcher(nodes: [a, a, b], ways: [way]).match(shortStroke) == nil)
    #expect(StrokeMatcher(nodes: [a, b], ways: [way, way]).match(shortStroke) == nil)

    let broken = StrokeMatcher(nodes: [a, b], ways: [Way(id: 1, nodeIDs: [1, 3, 2])])
    #expect(broken.match(shortStroke) == nil)
}

@Test func rejectsAnIndividualOutlierOnAnOtherwiseCloseStroke() {
    let matcher = StrokeMatcher(nodes: [node(1, 0, 0), node(2, 200, 0)], ways: [Way(id: 1, nodeIDs: [1, 2])])
    #expect(matcher.match([coordinate(0, 0), coordinate(100, 25), coordinate(200, 0)]) == nil)
    #expect(matcher.match([coordinate(0, 0), coordinate(100, 2), coordinate(200, 0)]) != nil)
}

@Test func followsBothLegsOfAnOpenTurnWithAConnectingShortcut() throws {
    let nodes = [node(1, 0, 0), node(2, 50, 0), node(3, 50, 50)]
    let matcher = StrokeMatcher(
        nodes: nodes,
        ways: [Way(id: 10, nodeIDs: [1, 2]), Way(id: 20, nodeIDs: [2, 3]), Way(id: 30, nodeIDs: [3, 1])])
    let result = try #require(matcher.match([coordinate(0, 0), coordinate(50, 0), coordinate(50, 50)]))

    #expect(Set(result.distanceMetersByWayID.keys) == [10, 20])
    #expect(result.coordinates.contains(coordinate(50, 0)))
    #expect(result.coordinates.first == coordinate(0, 0))
    #expect(result.coordinates.last == coordinate(50, 50))
    #expect(abs(result.distanceMeters - 100) < 0.01)
}

@Test func rejectsAConnectingShortcutThatSkipsTheOnlyDrawnTurn() {
    let matcher = StrokeMatcher(
        nodes: [node(1, 0, 0), node(2, 18, 18)],
        ways: [Way(id: 1, nodeIDs: [1, 2])])
    #expect(matcher.match([coordinate(0, 0), coordinate(18, 0), coordinate(18, 18)]) == nil)

    let horizontal = stride(from: 0.0, through: 18.0, by: 2).map { coordinate($0, 0) }
    let vertical = stride(from: 2.0, through: 18.0, by: 2).map { coordinate(18, $0) }
    #expect(matcher.match(horizontal + vertical) == nil)
}

@Test func acceptsARoundedMappedCornerCloseToTheDrawnTurn() throws {
    let matcher = StrokeMatcher(
        nodes: [node(1, 0, 0), node(2, 40, 0), node(3, 50, 10), node(4, 50, 50)],
        ways: [Way(id: 1, nodeIDs: [1, 2, 3, 4])])
    let result = try #require(matcher.match([coordinate(0, 0), coordinate(50, 0), coordinate(50, 50)]))
    #expect(abs(result.distanceMeters - (80 + 2.0.squareRoot() * 10)) < 0.01)
}

@Test func acceptsSlightlyOffsetEndpointsCorroboratedByTheDrawnRoad() throws {
    let matcher = StrokeMatcher(nodes: [node(1, 0, 0), node(2, 180, 0)], ways: [Way(id: 1, nodeIDs: [1, 2])])
    let match = try #require(
        matcher.match([coordinate(0, 13), coordinate(18, 2), coordinate(162, 2), coordinate(180, 14)]))
    #expect(match.coordinates.first == coordinate(0, 0))
    #expect(match.coordinates.last == coordinate(180, 0))
    #expect(abs(match.distanceMeters - 180) < 0.01)
}

@Test func rejectsOffsetEndpointsWithoutNearbyConfirmation() {
    let matcher = StrokeMatcher(nodes: [node(1, 0, 0), node(2, 180, 0)], ways: [Way(id: 1, nodeIDs: [1, 2])])
    #expect(matcher.match([coordinate(0, 14), coordinate(40, 14), coordinate(54, 0), coordinate(180, 0)]) == nil)
    #expect(matcher.match([coordinate(0, 19), coordinate(18, 0), coordinate(180, 0)]) == nil)
}

@Test func resolvesSupportedRoadOnEitherSideOfAnUnmappedDetour() {
    let matcher = StrokeMatcher(
        nodes: [node(1, 0, 0), node(2, 120, 0), node(3, 240, 0), node(4, 360, 0)],
        ways: [Way(id: 1, nodeIDs: [1, 2]), Way(id: 2, nodeIDs: [3, 4])])
    let crest = coordinate(180, 60)
    let stroke = [coordinate(0, 0), coordinate(112, 0), crest, coordinate(248, 0), coordinate(360, 0)]
    let route = matcher.resolve(stroke)
    #expect(route.segments.map(\.kind) == [.snapped, .freehand, .snapped])
    #expect(route.segments[1].coordinates.contains(crest))
    #expect(route.segments.first?.coordinates.first == stroke.first)
    #expect(route.segments.last?.coordinates.last == stroke.last)
    for (first, second) in zip(route.segments, route.segments.dropFirst()) {
        #expect(first.coordinates.last == second.coordinates.first)
    }
}

@Test(arguments: [16.0, 20.0])
func resolvesCoherentlyOffsetParallelDrawingsAsApproximate(offset: Double) {
    let matcher = StrokeMatcher(nodes: [node(1, 0, 0), node(2, 180, 0)], ways: [Way(id: 1, nodeIDs: [1, 2])])
    let stroke = [coordinate(0, offset), coordinate(90, offset), coordinate(180, offset)]
    #expect(matcher.match(stroke) == nil)
    let route = matcher.resolve(stroke)
    #expect(route.segments.map(\.kind) == [.approximate])
    #expect(abs(route.distanceMeters - 180) < 0.01)
}

@Test func approximateMatchDoesNotAddPerpendicularStubsAtTheEnds() {
    let nodes = [
        node(1, 0, 0), node(2, 180, 0), node(3, 0, 22), node(4, 180, 22)
    ]
    let matcher = StrokeMatcher(
        nodes: nodes,
        ways: [
            Way(id: 1, nodeIDs: [1, 2]), Way(id: 2, nodeIDs: [1, 3]), Way(id: 3, nodeIDs: [2, 4])
        ])
    let route = matcher.resolve([coordinate(0, 16), coordinate(90, 16), coordinate(180, 16)])
    #expect(route.segments.map(\.kind) == [.approximate])
    #expect(route.segments.first?.coordinates.first == coordinate(0, 0))
    #expect(route.segments.last?.coordinates.last == coordinate(180, 0))
    #expect(abs(route.distanceMeters - 180) < 0.01)
}

@Test(arguments: [false, true])
func followsDistinctTurnsUnderACoherentTouchOffset(retrace: Bool) {
    let positions = [(0.0, 0.0), (65, 0), (65, 55), (130, 55), (130, 115)]
    let nodes = positions.enumerated().map { index, point in
        node(Int64(index + 1), point.0, point.1)
    }
    let matcher = StrokeMatcher(nodes: nodes, ways: [Way(id: 1, nodeIDs: nodes.map(\.id))])
    let path = retrace ? positions + Array(positions.dropLast().reversed()) : positions
    let input = path.map { coordinate($0.0, $0.1 + 16) }
    let original = path.map { coordinate($0.0, $0.1) }
    let resolved = matcher.resolve(input)

    #expect(resolved.segments.map(\.kind) == [.approximate])
    #expect(abs(resolved.distanceMeters - (retrace ? 490 : 245)) < 0.01)
    guard let output = resolved.segments.first?.coordinates else { return }
    var remaining = output[...]
    for vertex in original {
        guard
            let hit = remaining.firstIndex(where: { coordinate in
                abs(coordinate.latitude - vertex.latitude) < 1e-8 && abs(coordinate.longitude - vertex.longitude) < 1e-8
            })
        else {
            Issue.record("The offset correction skipped a turn or retraced vertex")
            return
        }
        remaining = remaining.dropFirst(remaining.distance(from: remaining.startIndex, to: hit) + 1)
    }
    #expect(matcher.resolve(original).segments.map(\.kind) == [.snapped])
}

@Test func leavesAPerpendicularCrossingAndAnUnmappedTurnFreehand() {
    let matcher = StrokeMatcher(
        nodes: [node(1, 20, 0), node(2, 20, 180), node(3, 0, -20), node(4, 18, -2)],
        ways: [Way(id: 1, nodeIDs: [1, 2]), Way(id: 2, nodeIDs: [3, 4])])
    let crossing = [coordinate(-30, 90), coordinate(20, 90), coordinate(70, 90)]
    let turn = [coordinate(0, -20), coordinate(18, -20), coordinate(18, -2)]
    #expect(matcher.resolve(crossing) == .freehand(crossing))
    #expect(matcher.resolve(turn) == .freehand(turn))
}

@Test func resolvesALongerStrokeInBoundedConnectedWindows() {
    let nodes = (0...32).map { node(Int64($0), Double($0 * 100), 0) }
    let matcher = StrokeMatcher(nodes: nodes, ways: [Way(id: 1, nodeIDs: nodes.map(\.id))])
    let stroke = nodes.map(\.coordinate)
    let route = matcher.resolve(stroke)
    #expect(matcher.match(stroke) == nil)
    #expect(route.segments.allSatisfy { $0.kind == .snapped })
    #expect(abs(route.distanceMeters - 3_200) < 0.01)
    #expect(route.segments.first?.coordinates.first == stroke.first)
    #expect(route.segments.last?.coordinates.last == stroke.last)
}

#if canImport(MapKit)
    @Test func appleMapsOverlayPreservesTheMatchedBendAndEndpoints() throws {
        let matcher = StrokeMatcher(
            nodes: [node(1, 0, 0), node(2, 50, 0), node(3, 50, 50)],
            ways: [Way(id: 1, nodeIDs: [1, 2, 3])])
        let match = try #require(matcher.match([coordinate(2, 1), coordinate(49, 1), coordinate(49, 48)]))
        let overlay = match.polyline
        #expect(overlay.pointCount == match.coordinates.count)
        var positions = Array(repeating: CLLocationCoordinate2D(), count: overlay.pointCount)
        overlay.getCoordinates(&positions, range: NSRange(location: 0, length: positions.count))
        for (position, expected) in zip(positions, match.coordinates) {
            let displayed = Coordinate(position)
            #expect(abs(displayed.latitude - expected.latitude) < 1e-7)
            #expect(abs(displayed.longitude - expected.longitude) < 1e-7)
        }
    }
#endif

@Test func identifiesSustainedParallelRoadsAsASuggestion() {
    let matcher = StrokeMatcher(
        nodes: [node(1, 0, 0), node(2, 100, 0), node(3, 0, 15), node(4, 100, 15)],
        ways: [Way(id: 1, nodeIDs: [1, 2]), Way(id: 2, nodeIDs: [3, 4])])
    let route = matcher.resolve([coordinate(0, 1), coordinate(50, 1), coordinate(100, 1)])
    #expect(route.segments.map(\.kind) == [.approximate])
    #expect(abs(route.snappedDistanceMeters - 100) < 0.1)
}

@Test func preservesFreehandOutsideRoutingCoverageWithoutBridgingInvalidCoordinates() {
    let polar = [Coordinate(latitude: 86, longitude: 1), Coordinate(latitude: 86, longitude: 1.01)]
    let drawn = ResolvedStroke.freehand(polar + [Coordinate(latitude: .nan, longitude: 1)] + polar.reversed())
    #expect(drawn.segments.map(\.kind) == [.freehand, .freehand])
    #expect(drawn.segments.first?.coordinates == polar)
}

@Test func keepsSeparatelyResolvedSectionsContinuousWithoutClaimingAStreetAtTheSeam() throws {
    let first = StrokeMatcher(nodes: [node(1, 0, 0), node(2, 70, 0)], ways: [Way(id: 1, nodeIDs: [1, 2])])
        .resolve([coordinate(0, 0), coordinate(70, 0)])
    let second = StrokeMatcher(nodes: [node(3, 71, 8), node(4, 150, 8)], ways: [Way(id: 2, nodeIDs: [3, 4])])
        .resolve([coordinate(71, 8), coordinate(150, 8)])
    let route = ResolvedStroke.joining([first, second])
    #expect(route.segments.map(\.kind) == [.snapped, .freehand, .snapped])
    #expect(route.segments[0].coordinates.last == route.segments[1].coordinates.first)
    #expect(route.segments[1].coordinates.last == route.segments[2].coordinates.first)
}

@Test func aLooseConnectedFitIsShownAsASuggestion() {
    let matcher = StrokeMatcher(
        nodes: [node(1, 0, 0), node(2, 120, 0)], ways: [Way(id: 1, nodeIDs: [1, 2])])
    let result = matcher.resolve([coordinate(0, 7), coordinate(60, 7), coordinate(120, 7)])
    #expect(result.segments.map(\.kind) == [.approximate])
    #expect(abs(result.snappedDistanceMeters - 120) < 0.1)
}

@Test func repairsAShortGapOnTheSameConnectedStreet() {
    let matcher = StrokeMatcher(
        nodes: [node(1, 0, 0), node(2, 180, 0), node(3, 360, 0)],
        ways: [Way(id: 1, nodeIDs: [1, 2]), Way(id: 2, nodeIDs: [2, 3])])
    let drawing = [
        coordinate(0, 0), coordinate(115, 0), coordinate(140, 0), coordinate(155, 5),
        coordinate(170, 18), coordinate(180, 25), coordinate(190, 18), coordinate(205, 5),
        coordinate(220, 0), coordinate(245, 0), coordinate(360, 0)
    ]
    #expect(matcher.match(drawing) == nil)
    let result = matcher.resolve(drawing)
    #expect(result.segments.map(\.kind).contains(.approximate))
    #expect(result.segments.allSatisfy { $0.kind != .freehand })
    #expect(result.segments.flatMap(\.coordinates).allSatisfy { abs($0.latitude) < 1e-9 })
    #expect(abs(result.distanceMeters - 360) < 0.01)
    for (before, after) in zip(result.segments, result.segments.dropFirst()) {
        #expect(before.coordinates.last == after.coordinates.first)
    }
}

@Test func leavesAShortDrawnGapBetweenDisconnectedCoincidentWays() {
    let matcher = StrokeMatcher(
        nodes: [node(1, 0, 0), node(2, 180, 0), node(3, 180, 0), node(4, 360, 0)],
        ways: [Way(id: 1, nodeIDs: [1, 2]), Way(id: 2, nodeIDs: [3, 4])])
    let drawing = [
        coordinate(0, 0), coordinate(115, 0), coordinate(140, 0), coordinate(155, 5),
        coordinate(170, 18), coordinate(180, 25), coordinate(190, 18), coordinate(205, 5),
        coordinate(220, 0), coordinate(245, 0), coordinate(360, 0)
    ]
    let result = matcher.resolve(drawing)
    #expect(result.segments.contains { $0.kind == .freehand && $0.coordinates.contains(coordinate(180, 25)) })
}

@Test func leavesAShortIntentionalTurnInTheGap() {
    let matcher = StrokeMatcher(
        nodes: [node(1, 0, 0), node(2, 190, 0), node(3, 320, 0)],
        ways: [Way(id: 1, nodeIDs: [1, 2]), Way(id: 2, nodeIDs: [2, 3])])
    let apex = coordinate(180, 27)
    let drawing = [
        coordinate(0, 0), coordinate(155, 0), coordinate(180, 0), apex,
        coordinate(205, 27), coordinate(205, 0), coordinate(320, 0)
    ]
    let result = matcher.resolve(drawing)
    #expect(result.segments.contains { $0.kind == .freehand && $0.coordinates.contains(apex) })
}

@Test func keepsAnAnchoredMappedCurveWhenTheTouchCutsInsideIt() throws {
    let nodes = [node(1, 0, 0), node(2, 44, -48), node(3, 95, 0)]
    let ways = [Way(id: 1, nodeIDs: [1, 2, 3])]
    let projection = LocalProjection(origin: nodes[0].coordinate)
    let drawing = [coordinate(0, 0), coordinate(13, 9), coordinate(40, -16), coordinate(95, 0)]
        .map(projection.project)
    let graph = LocalGraph(
        nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.coordinate) }), ways: ways,
        projection: projection, stroke: drawing)
    let first = LocalGraph.Anchor(way: 1, a: 1, b: 2, fraction: 0, point: drawing[0])
    let last = LocalGraph.Anchor(way: 1, a: 2, b: 3, fraction: 1, point: drawing[3])
    let gap = try #require(graph.connect(from: first, to: last, following: drawing))
    #expect(gap.points == nodes.map { projection.project($0.coordinate) })
    #expect(abs(gap.length - 135.15) < 0.01)
}

@Test func leavesTheSketchWhenTheOnlyConnectorCutsAcrossItsTurn() {
    let nodes = [node(1, 0, 0), node(2, 80, 0)]
    let ways = [Way(id: 1, nodeIDs: [1, 2])]
    let projection = LocalProjection(origin: nodes[0].coordinate)
    let drawing = [coordinate(0, 0), coordinate(40, 35), coordinate(80, 0)].map(projection.project)
    let graph = LocalGraph(
        nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.coordinate) }), ways: ways,
        projection: projection, stroke: drawing)
    let first = LocalGraph.Anchor(way: 1, a: 1, b: 2, fraction: 0, point: drawing[0])
    let last = LocalGraph.Anchor(way: 1, a: 1, b: 2, fraction: 1, point: drawing[2])
    #expect(graph.connect(from: first, to: last, following: drawing) == nil)
}

@Test func leavesTheSketchWhenDistinctLooseConnectorsBothFit() {
    let nodes = [
        node(1, -20, 0), node(2, 0, 0), node(3, 50, 25), node(4, 50, 47), node(5, 100, 0), node(6, 120, 0)
    ]
    let ways = [
        Way(id: 1, nodeIDs: [1, 2]), Way(id: 2, nodeIDs: [2, 3, 5]),
        Way(id: 3, nodeIDs: [2, 4, 5]), Way(id: 4, nodeIDs: [5, 6])
    ]
    let projection = LocalProjection(origin: nodes[1].coordinate)
    let drawing = [coordinate(0, 0), coordinate(50, 60), coordinate(100, 0)].map(projection.project)
    let graph = LocalGraph(
        nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.coordinate) }), ways: ways,
        projection: projection, stroke: drawing)
    let first = LocalGraph.Anchor(way: 1, a: 1, b: 2, fraction: 1, point: drawing[0])
    let last = LocalGraph.Anchor(way: 4, a: 5, b: 6, fraction: 0, point: drawing[2])
    #expect(graph.connect(from: first, to: last, following: drawing) == nil)
}

@Test func extendsAnOpenGapOnlyTowardANearbyAlignedEdge() throws {
    let nodes = [node(1, 0, 0), node(2, 100, 0), node(3, 100, 30)]
    let ways = [Way(id: 1, nodeIDs: [1, 2]), Way(id: 2, nodeIDs: [2, 3])]
    let projection = LocalProjection(origin: nodes[0].coordinate)
    let road = nodes.map { projection.project($0.coordinate) }
    let drawing = [coordinate(72, 2), coordinate(82, 4), coordinate(97, 5)].map(projection.project)
    let graph = LocalGraph(
        nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.coordinate) }), ways: ways,
        projection: projection, stroke: drawing)
    let along = road[0] + (road[1] - road[0]) * 0.72
    let fixed = LocalGraph.Anchor(way: 1, a: 1, b: 2, fraction: 0.72, point: along)
    let gap = try #require(graph.extend(from: fixed, following: drawing, atStart: false))
    #expect(gap.points.first == along)
    #expect(abs(gap.length - 25) < 0.01)
    let backwards = try #require(graph.extend(from: fixed, following: drawing.reversed(), atStart: true))
    #expect(backwards.points.last == along)
    #expect(abs(backwards.length - gap.length) < 0.01)

    let offroad = [coordinate(72, 0), coordinate(82, 4), coordinate(87, 20)].map(projection.project)
    #expect(graph.extend(from: fixed, following: offroad, atStart: false) == nil)
}

@Test func recoversALongCorridorWithSmallMisalignedDriftAtItsEntrance() throws {
    let nodes = [
        node(1, -30, 10), node(2, 0, 0), node(3, 55, -20), node(4, 130, 0), node(5, 175, 12)
    ]
    let ways = [Way(id: 1, nodeIDs: [1, 2, 3, 4, 5])]
    let projection = LocalProjection(origin: nodes[1].coordinate)
    let road = nodes.map { projection.project($0.coordinate) }
    let graph = LocalGraph(
        nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.coordinate) }), ways: ways,
        projection: projection, stroke: road)
    let start = LocalGraph.Anchor(way: 1, a: 2, b: 3, fraction: 0, point: road[1])
    let end = LocalGraph.Anchor(way: 1, a: 3, b: 4, fraction: 1, point: road[3])
    let tapDrift = [coordinate(0, 0), coordinate(21, 20), coordinate(130, 0)].map(projection.project)
    let entry = road[1] - road[0]
    let exit = road[4] - road[3]
    let gap = try #require(graph.connect(from: start, to: end, following: tapDrift, entry: entry, exit: exit))
    #expect(gap.points == [road[1], road[2], road[3]])
    let shiftedBoundary = [coordinate(18, 12), coordinate(21, 20), coordinate(130, 0)].map(projection.project)
    let adjustedGap = try #require(
        graph.connect(from: start, to: end, following: shiftedBoundary, entry: entry, exit: exit))
    #expect(adjustedGap.points == gap.points)

    // A deliberate bend midblock or an incompatible approach does not identify that corridor.
    let intentionalTurn = [coordinate(0, 0), coordinate(67, 22), coordinate(130, 0)].map(projection.project)
    #expect(graph.connect(from: start, to: end, following: intentionalTurn, entry: entry, exit: exit) == nil)
    #expect(graph.connect(from: start, to: end, following: tapDrift, entry: entry * -1, exit: exit) == nil)
}

@Test func ignoresLiftJitterWithoutTrimmingAnIntentionalFinish() {
    let anchor = Point(x: 0, y: 0)
    let jitter = [
        anchor, .init(x: 2, y: 1), .init(x: 4, y: 2), .init(x: 5, y: 2),
        .init(x: 3, y: 1), .init(x: 1, y: 1), .init(x: 2, y: 2)
    ]
    #expect(StrokeResolution.isLiftJitter(jitter[...], around: anchor))

    let finish = (0...6).map { Point(x: Double($0), y: 0) }
    #expect(!StrokeResolution.isLiftJitter(finish[...], around: anchor))
    let deliberateTurn = jitter + [.init(x: 5, y: 7), .init(x: 2, y: 3)]
    #expect(!StrokeResolution.isLiftJitter(deliberateTurn[...], around: anchor))
}
