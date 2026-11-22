import Foundation

/// An ordered polyline on the supplied graph and the evidence supporting the match.
public struct Match: Sendable, Equatable {
    /// Projected endpoints and intermediate points along the traversed edges.
    public let coordinates: [Coordinate]
    /// Estimated distance in the local projection.
    public let distanceMeters: Double
    /// Traversed distance per source way ID, including repeated traversal.
    public let distanceMetersByWayID: [Int64: Double]
    /// Root-mean-square distance between resampled stroke points and selected graph projections.
    public let rmsOffsetMeters: Double
}

/// Matches one local stroke to caller-supplied, bidirectional graph geometry.
/// Supply only ways eligible for the activity. The matcher has no access or turn rules.
public struct StrokeMatcher: Sendable {
    private let nodes: [Int64: Coordinate]
    private let ways: [Way]

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
        self.nodes = coordinates
        self.ways = Set(ways.map(\.id)).count == ways.count ? ways.sorted { $0.id < $1.id } : []
    }

    /// Returns a connected match or nil for an invalid or weakly supported stroke.
    /// The current heuristic accepts local strokes from 8 m to 2.5 km, with no input gap over 250 m.
    /// Confidence thresholds describe geometric agreement and do not identify the user's intended way.
    public func match(_ stroke: [Coordinate]) -> Match? {
        guard !ways.isEmpty, let origin = stroke.first, stroke.allSatisfy(\.isValid) else { return nil }
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
    public func resolve(_ stroke: [Coordinate]) -> ResolvedStroke {
        StrokeResolution(nodes: nodes, ways: ways).resolve(stroke)
    }

    static func resample(_ points: [Point], preservingReversals: Bool = false) -> [Point]? {
        guard let first = points.first, let last = points.last else { return nil }
        let lengths = zip(points, points.dropFirst()).map { ($1 - $0).length }
        let length = lengths.reduce(0, +)
        guard (8...2_500).contains(length), lengths.allSatisfy({ $0 <= 250 }) else { return nil }

        let intervals = Int(ceil(length / 9))
        var targets = (1..<intervals).map { length * Double($0) / Double(intervals) }
        if preservingReversals {
            var distance = 0.0
            for index in points.indices.dropFirst().dropLast() {
                distance += lengths[index - 1]
                let incoming = points[index] - points[index - 1]
                let outgoing = points[index + 1] - points[index]
                guard min(incoming.length, outgoing.length) >= 4,
                    incoming.dot(outgoing) < -0.8 * incoming.length * outgoing.length
                else { continue }
                targets.removeAll { abs($0 - distance) < 2 }
                targets.append(distance)
            }
            targets.sort()
        }
        var output = [first]
        var segment = 0
        var traversed = 0.0
        for target in targets {
            while traversed + lengths[segment] < target {
                traversed += lengths[segment]
                segment += 1
            }
            let portion = (target - traversed) / lengths[segment]
            output.append(points[segment] + (points[segment + 1] - points[segment]) * portion)
        }
        output.append(last)
        return output
    }
}
