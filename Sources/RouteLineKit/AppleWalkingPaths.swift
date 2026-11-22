#if canImport(MapKit)
import Foundation
import MapKit

/// Describes a drawing or Apple Maps lookup that could not produce a route.
public enum WalkingRouteError: LocalizedError, Hashable {
    case unsupportedDrawing
    case serviceUnavailable
    case serviceBusy
    case noWalkingRoute
    case doesNotFollowDrawing

    public var errorDescription: String? {
        switch self {
        case .unsupportedDrawing:
            "Apple walking directions can match a continuous drawing between 15 m and 2.4 km."
        case .serviceUnavailable:
            "Apple walking directions are unavailable right now."
        case .serviceBusy:
            "Apple walking directions are busy. Wait a moment before trying again."
        case .noWalkingRoute:
            "Apple Maps couldn’t find walking directions near the drawing."
        case .doesNotFollowDrawing:
            "Apple walking directions didn’t follow your drawing closely enough."
        }
    }
}

/// Uses Apple Maps walking directions to match a continuous drawing between 15 m and 2.4 km.
/// Sections without sufficient support can remain freehand in the returned route.
/// Throws a `WalkingRouteError` for an unsuccessful lookup or `CancellationError` on cancellation.
@concurrent
public func walkingRoute(for drawing: [Coordinate]) async throws -> ResolvedStroke {
    try await AppleWalkingPaths().resolve(drawing)
}

#if DEBUG && targetEnvironment(simulator)
@_spi(Testing)
@concurrent
public func walkingRoute(
    for drawing: [Coordinate], lookup: @escaping @Sendable (Coordinate, Coordinate) async throws -> [Coordinate]
) async throws -> ResolvedStroke {
    try await AppleWalkingPaths(lookup: lookup).resolve(drawing)
}
#endif

struct AppleWalkingPaths: Sendable {
    @MainActor
    private final class DirectionsRequest {
        let directions: MKDirections
        private var isCancelled = false

        init(_ request: MKDirections.Request) {
            directions = MKDirections(request: request)
        }

        func calculate() async throws -> MKDirections.Response {
            if isCancelled { throw CancellationError() }
            return try await directions.calculate()
        }

        func cancel() {
            isCancelled = true
            directions.cancel()
        }
    }

    typealias LegLookup = @Sendable (Coordinate, Coordinate) async throws -> [Coordinate]
    private static let endpointTolerance = 0.5
    private let lookup: LegLookup

    init(lookup: @escaping LegLookup = AppleWalkingPaths.walkingLeg) {
        self.lookup = lookup
    }

    @concurrent
    func resolve(_ stroke: [Coordinate]) async throws -> ResolvedStroke {
        try Task.checkCancellation()
        let anchorIndices = try Self.anchorIndices(for: stroke)
        let anchors = anchorIndices.map { stroke[$0] }
        var legs: [[Coordinate]] = []
        var coordinateCount = 0
        for (source, destination) in zip(anchors, anchors.dropFirst()) {
            try Task.checkCancellation()
            let leg = try await lookup(source, destination)
            try Task.checkCancellation()
            guard (2...3_000).contains(leg.count), coordinateCount + leg.count <= 6_000,
                leg.allSatisfy(\.isValid), leg.dropFirst().contains(where: { $0 != leg[0] })
            else { throw WalkingRouteError.noWalkingRoute }
            legs.append(leg)
            coordinateCount += leg.count
        }

        var nodes: [Node] = []
        var ways: [Way] = []
        func append(_ leg: [Coordinate]) {
            var nodeIDs: [Int64] = []
            if let previous = nodes.last,
                Self.point(previous.coordinate).distance(to: Self.point(leg[0])) <= Self.endpointTolerance
            {
                nodeIDs.append(previous.id)
            }
            // Only successive legs share nodes, and only within the endpoint tolerance.
            for coordinate in nodeIDs.isEmpty ? leg[...] : leg.dropFirst() {
                if let previous = nodeIDs.last, nodes[Int(previous)].coordinate == coordinate { continue }
                let id = Int64(nodes.count)
                nodes.append(Node(id: id, coordinate: coordinate))
                nodeIDs.append(id)
            }
            if nodeIDs.count > 1 {
                ways.append(Way(id: Int64(ways.count), nodeIDs: nodeIDs))
            }
        }

        var remainingRepairs = 2
        let drawing = stroke.map(Self.point)
        for (index, leg) in legs.enumerated() {
            if remainingRepairs > 0, let start = nodes.last?.coordinate, let end = leg.first {
                let gap = Self.point(start).distance(to: Self.point(end))
                if (2...60).contains(gap) {
                    remainingRepairs -= 1
                    let connector: [Coordinate]?
                    do {
                        connector = try await lookup(start, end)
                    } catch WalkingRouteError.serviceBusy {
                        remainingRepairs = 0
                        connector = nil
                    } catch {
                        connector = nil
                    }
                    try Task.checkCancellation()
                    if let connector, Self.isSupportedConnector(
                        connector, from: start, to: end, gap: gap, near: anchorIndices[index], drawing: drawing)
                    {
                        var joined = connector
                        joined[0] = start
                        joined[joined.count - 1] = end
                        append(joined)
                    }
                }
            }
            append(leg)
        }

        let matcher = StrokeMatcher(nodes: nodes, ways: ways)
        let route = matcher.resolve(stroke, shouldCancel: { Task.isCancelled })
        try Task.checkCancellation()
        guard route.snappedDistanceMeters > 0 else {
            throw WalkingRouteError.doesNotFollowDrawing
        }
        return route
    }

    static func anchors(for stroke: [Coordinate]) throws -> [Coordinate] {
        try anchorIndices(for: stroke).map { stroke[$0] }
    }

    private static func anchorIndices(for stroke: [Coordinate]) throws -> [Int] {
        guard (2...StrokeMatcher.maximumObservations).contains(stroke.count), stroke.allSatisfy(\.isValid),
            let first = stroke.first
        else { throw WalkingRouteError.unsupportedDrawing }

        let points = stroke.map(point)
        let scale = MKMetersPerMapPointAtLatitude(first.latitude)
        var lengths = [0.0]
        for (start, end) in zip(points, points.dropFirst()) {
            let length = start.distance(to: end)
            guard length <= 245, abs(end.x - start.x) * scale <= 245 else {
                throw WalkingRouteError.unsupportedDrawing
            }
            lengths.append(lengths[lengths.count - 1] + length)
        }
        guard let length = lengths.last, (15...2_400).contains(length) else {
            throw WalkingRouteError.unsupportedDrawing
        }

        // Insert the strongest remaining corner until it is straight enough or four requests are needed.
        var indices = [0, stroke.count - 1]
        while indices.count < 5 {
            var strongest: (index: Int, deviation: Double)?
            for (start, end) in zip(indices, indices.dropFirst()) {
                for candidate in (start + 1)..<end {
                    guard lengths[candidate] - lengths[start] >= 18, lengths[end] - lengths[candidate] >= 18 else {
                        continue
                    }
                    let deviation = chordDeviation(points[candidate], from: points[start], to: points[end]) * scale
                    if deviation > (strongest?.deviation ?? 12) {
                        strongest = (candidate, deviation)
                    }
                }
            }
            guard let strongest else { break }
            indices.append(strongest.index)
            indices.sort()
        }

        let anchors = indices.map { stroke[$0] }
        guard zip(anchors, anchors.dropFirst()).allSatisfy({ point($0).distance(to: point($1)) >= 8 }) else {
            throw WalkingRouteError.unsupportedDrawing
        }
        return indices
    }

    private static func isSupportedConnector(
        _ connector: [Coordinate], from start: Coordinate, to end: Coordinate, gap: Double,
        near anchor: Int, drawing: [MKMapPoint]
    ) -> Bool {
        guard (2...128).contains(connector.count), connector.allSatisfy(\.isValid),
            let first = connector.first, let last = connector.last,
            point(start).distance(to: point(first)) <= endpointTolerance,
            point(end).distance(to: point(last)) <= endpointTolerance
        else { return false }

        var lower = anchor
        var upper = anchor
        var length = 0.0
        while lower > 0 && length < 90 {
            length += drawing[lower].distance(to: drawing[lower - 1])
            lower -= 1
        }
        length = 0
        while upper + 1 < drawing.count && length < 90 {
            length += drawing[upper].distance(to: drawing[upper + 1])
            upper += 1
        }
        let localEdges = Array(zip(drawing[lower..<upper], drawing[(lower + 1)...upper]))
        let scale = MKMetersPerMapPointAtLatitude(start.latitude)
        let points = connector.map(point)
        length = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let distance = a.distance(to: b)
            length += distance
            guard length <= min(110, max(25, gap * 2.5)) else { return false }
            let samples = max(1, Int(ceil(distance / 8)))
            for sample in 0...samples {
                let fraction = Double(sample) / Double(samples)
                let probe = MKMapPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
                guard localEdges.contains(where: { chordDeviation(probe, from: $0.0, to: $0.1) * scale <= 25 })
                else { return false }
            }
        }
        return true
    }

    @MainActor
    private static func walkingLeg(from start: Coordinate, to end: Coordinate) async throws -> [Coordinate] {
        let request = MKDirections.Request()
        request.source = mapItem(start)
        request.destination = mapItem(end)
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        let directions = DirectionsRequest(request)
        do {
            let response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await directions.calculate()
            } onCancel: {
                Task { await directions.cancel() }
            }
            try Task.checkCancellation()
            guard let line = response.routes.first?.polyline, (2...3_000).contains(line.pointCount) else {
                throw WalkingRouteError.noWalkingRoute
            }
            var coordinates = Array(repeating: CLLocationCoordinate2D(), count: line.pointCount)
            line.getCoordinates(&coordinates, range: NSRange(location: 0, length: line.pointCount))
            return coordinates.map(Coordinate.init)
        } catch {
            try Task.checkCancellation()
            switch error {
            case let lookupError as WalkingRouteError: throw lookupError
            case let mapError as MKError where mapError.code == .loadingThrottled: throw WalkingRouteError.serviceBusy
            case let mapError as MKError where mapError.code == .directionsNotFound: throw WalkingRouteError.noWalkingRoute
            default: throw WalkingRouteError.serviceUnavailable
            }
        }
    }

    private static func mapItem(_ coordinate: Coordinate) -> MKMapItem {
        MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
    }

    private static func point(_ coordinate: Coordinate) -> MKMapPoint {
        MKMapPoint(coordinate.mapCoordinate)
    }

    private static func chordDeviation(_ point: MKMapPoint, from start: MKMapPoint, to end: MKMapPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let progress = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let fraction = min(1, max(0, progress))
        return hypot(point.x - (start.x + fraction * dx), point.y - (start.y + fraction * dy))
    }
}
#endif
