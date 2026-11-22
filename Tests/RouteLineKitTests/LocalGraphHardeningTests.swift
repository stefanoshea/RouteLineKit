import Testing

@testable import RouteLineKit

private func coordinate(_ x: Double, _ y: Double) -> Coordinate {
    Coordinate(latitude: y / 111_195, longitude: x / 111_195)
}

private func node(_ id: Int64, _ x: Double, _ y: Double) -> Node {
    Node(id: id, coordinate: coordinate(x, y))
}

@Test func matchesRouteOnDenseGridWithDistantOutOfBoundsNodes() throws {
    let gridSize = 25
    let spacing = 40.0
    var nodes: [Node] = []
    var ways: [Way] = []

    for row in 0..<gridSize {
        for col in 0..<gridSize {
            let id = Int64(row * gridSize + col + 1)
            nodes.append(node(id, Double(col) * spacing, Double(row) * spacing))
        }
    }

    var nextWayID: Int64 = 1
    for row in 0..<gridSize {
        for col in 0..<(gridSize - 1) {
            let a = Int64(row * gridSize + col + 1)
            let b = Int64(row * gridSize + col + 2)
            ways.append(Way(id: nextWayID, nodeIDs: [a, b]))
            nextWayID += 1
        }
    }
    for row in 0..<(gridSize - 1) {
        for col in 0..<gridSize {
            let a = Int64(row * gridSize + col + 1)
            let b = Int64((row + 1) * gridSize + col + 1)
            ways.append(Way(id: nextWayID, nodeIDs: [a, b]))
            nextWayID += 1
        }
    }

    // Add 2,000 distant nodes well outside the stroke bounding box.
    for index in 0..<2_000 {
        let id = Int64(10_000 + index)
        nodes.append(node(id, 5_000 + Double(index % 100) * 20, 5_000 + Double(index / 100) * 20))
        if index > 0 && index % 100 != 0 {
            ways.append(Way(id: nextWayID, nodeIDs: [id - 1, id]))
            nextWayID += 1
        }
    }

    let matcher = StrokeMatcher(nodes: nodes, ways: ways)
    let horizontal = (0...12).map { coordinate(Double($0) * spacing, 0) }
    let vertical = (1...12).map { coordinate(480, Double($0) * spacing) }
    let stroke = horizontal + vertical

    let match = try #require(matcher.match(stroke))
    #expect(abs(match.distanceMeters - 960) < 0.01)
    #expect(match.coordinates.first == stroke.first)
    #expect(match.coordinates.last == stroke.last)

    let resolved = matcher.resolve(stroke)
    #expect(resolved.segments.map(\.kind) == [.snapped])
    #expect(abs(resolved.distanceMeters - 960) < 0.01)
}

@Test func matchesShortStrokeAlongDenselySampledWay() throws {
    let nodes = (0...5_000).map { node(Int64($0 + 1), Double($0) * 0.0101, 0) }
    let matcher = StrokeMatcher(nodes: nodes, ways: [Way(id: 1, nodeIDs: nodes.map(\.id))])
    let start = coordinate(12, 0)
    let end = coordinate(29.8, 0)

    let result = matcher.match([start, end])
    let match = try #require(result)
    #expect(abs(match.distanceMeters - 17.8) < 0.01)

    let projection = LocalProjection(origin: start)
    let matchedStart = try #require(match.coordinates.first)
    let matchedEnd = try #require(match.coordinates.last)
    #expect((projection.project(matchedStart) - projection.project(start)).length < 0.01)
    #expect((projection.project(matchedEnd) - projection.project(end)).length < 0.01)
}

@Test func spatialGridFallbackMatchesLongSegmentsBeyondCellSpanLimit() throws {
    // A segment spanning > 64 grid cells (or > 64 cells area) is stored in `longSegments`.
    let nodes = [
        node(1, 0, 0),
        node(2, 300, 300),
        node(3, 600, 300),
        node(4, 2_800, 300),
    ]
    let matcher = StrokeMatcher(
        nodes: nodes,
        ways: [Way(id: 1, nodeIDs: [1, 2, 3]), Way(id: 2, nodeIDs: [3, 4])])

    let diagonalStroke = [
        coordinate(0, 0), coordinate(150, 150), coordinate(300, 300), coordinate(450, 300), coordinate(600, 300),
    ]
    let match = try #require(matcher.match(diagonalStroke))
    let expectedDiagonal = 300 * 2.0.squareRoot() + 300
    #expect(abs(match.distanceMeters - expectedDiagonal) < 0.01)

    let longStroke = stride(from: 600, through: 2_800, by: 200).map { coordinate(Double($0), 300) }
    let longMatch = try #require(matcher.match(longStroke))
    #expect(abs(longMatch.distanceMeters - 2_200) < 0.01)
    #expect(matcher.resolve(longStroke).segments.map(\.kind) == [.snapped])
}

@Test func recoversCoherentlyShiftedRouteAlongSameSingleWayID() throws {
    let branchA: [(Double, Double)] = [(0, 0), (70, 0), (70, 55), (140, 55)]
    let branchB: [(Double, Double)] = [(155, 70), (85, 70), (85, 15), (15, 15)]
    let positions = branchA + branchB
    let nodes = positions.enumerated().map { index, point in
        node(Int64(index + 1), point.0, point.1)
    }
    let matcher = StrokeMatcher(nodes: nodes, ways: [Way(id: 1, nodeIDs: nodes.map(\.id))])

    // Slightly closer to branch A (7 m offset) than branch B (8 m offset), so unshifted
    // matching picks branch A with > 5 m RMS, while a (+8, +8) shift hits branch B exactly.
    let drawn = branchA.map { coordinate($0.0 + 7, $0.1 + 7) }
    let resolved = matcher.resolve(drawn)
    #expect(resolved.segments.map(\.kind) == [.approximate])

    let output = try #require(resolved.segments.first?.coordinates)
    let shiftedStart = coordinate(15, 15)
    let shiftedEnd = coordinate(155, 70)
    #expect(abs((output.first?.latitude ?? 99) - shiftedStart.latitude) < 1e-8)
    #expect(abs((output.first?.longitude ?? 99) - shiftedStart.longitude) < 1e-8)
    #expect(abs((output.last?.latitude ?? 99) - shiftedEnd.latitude) < 1e-8)
    #expect(abs((output.last?.longitude ?? 99) - shiftedEnd.longitude) < 1e-8)
}

@Test func cooperativeCancellationAbortsMultiWindowResolveEarly() {
    let positions = Array(stride(from: 0, through: 4_800, by: 100))
    let nodes = positions.map { node(Int64($0), Double($0), 0) }
    let matcher = StrokeMatcher(nodes: nodes, ways: [Way(id: 1, nodeIDs: nodes.map(\.id))])
    let stroke = nodes.map(\.coordinate)

    var checks = 0
    let result = matcher.resolve(stroke) {
        checks += 1
        return checks >= 2
    }
    #expect(result == .freehand(stroke))
}
