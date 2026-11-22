import Foundation

/// An ordered polyline on the supplied graph and the evidence supporting the match.
public struct Match: Sendable, Hashable {
    /// Projected endpoints and intermediate points along the traversed edges.
    public let coordinates: [Coordinate]
    /// Estimated distance in the local projection.
    public let distanceMeters: Double
    /// Traversed distance per source way ID, including repeated traversal.
    public let distanceMetersByWayID: [Int64: Double]
    /// Root-mean-square distance between resampled stroke points and selected graph projections.
    public let rmsOffsetMeters: Double

    public init(
        coordinates: [Coordinate],
        distanceMeters: Double,
        distanceMetersByWayID: [Int64: Double],
        rmsOffsetMeters: Double
    ) {
        self.coordinates = coordinates
        self.distanceMeters = distanceMeters
        self.distanceMetersByWayID = distanceMetersByWayID
        self.rmsOffsetMeters = rmsOffsetMeters
    }
}

/// Matches one local stroke to caller-supplied, bidirectional graph geometry.
/// Supply only ways eligible for the activity. The matcher has no access or turn rules.
public struct StrokeMatcher: Sendable {
    static let maximumObservations = 12_000

    private let nodes: [Int64: Coordinate]
    private let ways: [Way]

    /// Indicates whether the matcher contains no valid ways (including when duplicate IDs invalidated input).
    public var isEmpty: Bool { ways.isEmpty }

    /// Duplicate node or way IDs invalidate this matcher. Missing and invalid node coordinates
    /// leave gaps in their ways. Those gaps cannot be traversed.
    public init(nodes: [Node], ways: [Way]) {
        var coordinates: [Int64: Coordinate] = [:]
        for node in nodes {
            guard coordinates.updateValue(node.coordinate, forKey: node.id) == nil else {
                self.nodes = [:]
                self.ways = []
                return
            }
        }
        guard Set(ways.map(\.id)).count == ways.count else {
            self.nodes = [:]
            self.ways = []
            return
        }
        self.nodes = coordinates
        self.ways = ways.sorted { $0.id < $1.id }
    }

    /// Returns a connected match or nil for an invalid or weakly supported stroke.
    /// The current heuristic accepts local strokes from 8 m to 2.5 km, with no input gap over 250 m.
    /// Strokes may contain up to 12,000 observations.
    /// Confidence thresholds describe geometric agreement and do not identify the user's intended way.
    public func match(_ stroke: [Coordinate]) -> Match? {
        guard !ways.isEmpty, stroke.count <= Self.maximumObservations,
            let origin = stroke.first, stroke.allSatisfy(\.isValid)
        else { return nil }
        let projection = LocalProjection(origin: origin)
        let observed = stroke.map(projection.project)
        guard let sampled = Self.resample(observed) else { return nil }
        let graph = LocalGraph(nodes: nodes, ways: ways, projection: projection, stroke: sampled)
        guard let route = graph.match(sampled, observations: observed) else { return nil }
        return Match(
            coordinates: route.points.map(projection.unproject),
            distanceMeters: route.distance,
            distanceMetersByWayID: route.distanceByWayID,
            rmsOffsetMeters: route.rmsOffset)
    }

    /// Resolves one drawing into ordered road-aligned and freehand portions.
    /// Road matching accepts drawings from 8 m to 12 km, with up to 12,000 observations and
    /// latitudes within ±85°. Drawings outside these limits fall back to freehand portions.
    public func resolve(_ stroke: [Coordinate]) -> ResolvedStroke {
        resolve(stroke, shouldCancel: { false })
    }

    func resolve(_ stroke: [Coordinate], shouldCancel: () -> Bool) -> ResolvedStroke {
        StrokeResolution(nodes: nodes, ways: ways).resolve(stroke, shouldCancel: shouldCancel)
    }

    static func resample(_ points: [Point], preservingReversals: Bool = false) -> [Point]? {
        guard let first = points.first, let last = points.last else { return nil }
        var distances = [0.0]
        distances.reserveCapacity(points.count)
        var length = 0.0
        for (previous, next) in zip(points, points.dropFirst()) {
            let gap = (next - previous).length
            guard gap <= 250 else { return nil }
            length += gap
            distances.append(length)
        }
        guard (8...2_500).contains(length) else { return nil }

        let intervals = Int(ceil(length / 9))
        let reversals = preservingReversals ? reversalDistances(points, distances: distances, length: length) : []
        var output = [first]
        var segment = 0
        var reversalIndex = 0
        for interval in 1..<intervals {
            let target = length * Double(interval) / Double(intervals)
            while reversalIndex < reversals.count, reversals[reversalIndex] <= target {
                output.append(point(at: reversals[reversalIndex], in: points, distances: distances, segment: &segment))
                reversalIndex += 1
            }
            if reversalIndex > 0, target - reversals[reversalIndex - 1] < 2 { continue }
            if reversalIndex < reversals.count, reversals[reversalIndex] - target < 2 { continue }
            output.append(point(at: target, in: points, distances: distances, segment: &segment))
        }
        for reversal in reversals[reversalIndex...] {
            output.append(point(at: reversal, in: points, distances: distances, segment: &segment))
        }
        output.append(last)
        return output
    }

    private static func reversalDistances(_ points: [Point], distances: [Double], length: Double) -> [Double] {
        let chordSpan = 4.0
        var beforeSegment = 0
        var afterSegment = 0
        var reversals: [Double] = []
        var lastCandidate = -Double.infinity
        var bestSupport = 0.0
        for (index, distance) in distances.enumerated() {
            guard distance >= chordSpan, distance <= length - chordSpan else { continue }
            let before = point(at: distance - chordSpan, in: points, distances: distances, segment: &beforeSegment)
            let after = point(at: distance + chordSpan, in: points, distances: distances, segment: &afterSegment)
            let incoming = points[index] - before
            let outgoing = after - points[index]
            let support = min(incoming.length, outgoing.length)
            guard support >= chordSpan / 2,
                incoming.dot(outgoing) < -0.8 * incoming.length * outgoing.length
            else { continue }

            // Nearby vertices can describe the same reversal in a densely sampled stroke.
            if distance - lastCandidate >= 2 {
                reversals.append(distance)
                bestSupport = support
            } else if support > bestSupport {
                reversals[reversals.count - 1] = distance
                bestSupport = support
            }
            lastCandidate = distance
        }
        return reversals
    }

    private static func point(at target: Double, in points: [Point], distances: [Double], segment: inout Int) -> Point {
        while segment + 1 < points.count - 1, distances[segment + 1] < target {
            segment += 1
        }
        if target <= distances[segment] { return points[segment] }
        if target >= distances[segment + 1] { return points[segment + 1] }
        let portion = (target - distances[segment]) / (distances[segment + 1] - distances[segment])
        return points[segment] + (points[segment + 1] - points[segment]) * portion
    }
}
