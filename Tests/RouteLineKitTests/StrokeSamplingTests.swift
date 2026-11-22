import Testing

@testable import RouteLineKit

@Test func preservesTheSameReversalWithSparseAndDenseObservations() throws {
    let turn = Point(x: 32, y: 0)
    let sparse = [Point(x: 0, y: 0), turn, Point(x: 4, y: 0)]
    let outbound = (0...128).map { Point(x: Double($0) / 4, y: 0) }
    let inbound = (16..<128).reversed().map { Point(x: Double($0) / 4, y: 0) }
    let dense = outbound + [turn, turn] + inbound

    let sparseSamples = try #require(StrokeMatcher.resample(sparse, preservingReversals: true))
    let denseSamples = try #require(StrokeMatcher.resample(dense, preservingReversals: true))

    #expect(sparseSamples.contains(turn))
    #expect(denseSamples.contains(turn))
    #expect(denseSamples.count == sparseSamples.count)
    #expect(zip(denseSamples, sparseSamples).allSatisfy { ($0 - $1).length < 0.000_001 })
}

@Test func matcherChecksTheObservationLimit() {
    let start = Coordinate(latitude: 0, longitude: 0)
    let end = Coordinate(latitude: 0, longitude: 0.001)
    let matcher = StrokeMatcher(
        nodes: [Node(id: 1, coordinate: start), Node(id: 2, coordinate: end)],
        ways: [Way(id: 1, nodeIDs: [1, 2])])
    let atLimit = Array(repeating: start, count: StrokeMatcher.maximumObservations - 1) + [end]
    let overLimit = atLimit + [end]

    #expect(matcher.match(atLimit) != nil)
    #expect(matcher.match(overLimit) == nil)
    #expect(matcher.resolve(atLimit).snappedDistanceMeters > 0)
    #expect(matcher.resolve(overLimit) == .freehand(overLimit))
}
