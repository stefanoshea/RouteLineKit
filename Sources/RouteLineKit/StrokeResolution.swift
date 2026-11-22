import Foundation

public struct StrokeSegment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case snapped
        /// A wider adjustment or a nearby parallel path makes the selected geometry uncertain.
        case approximate
        case freehand
    }

    public let kind: Kind
    public let coordinates: [Coordinate]
    public let distanceMeters: Double
}

public struct ResolvedStroke: Sendable, Equatable {
    public let segments: [StrokeSegment]
    public var distanceMeters: Double { segments.reduce(0) { $0 + $1.distanceMeters } }
    public var snappedDistanceMeters: Double {
        segments.reduce(0) { $0 + ($1.kind == .freehand ? 0 : $1.distanceMeters) }
    }

    /// Combine consecutive, independently resolved parts of a single drawing.
    /// If projections at a shared boundary differ, the gap is explicitly freehand.
    public static func joining(_ pieces: [ResolvedStroke]) -> Self {
        var segments: [StrokeSegment] = []
        for piece in pieces where !piece.segments.isEmpty {
            if let end = segments.last?.coordinates.last, let start = piece.segments.first?.coordinates.first,
                let seam = StrokeResolution.freehandSegment([end, start])
            {
                segments.append(seam)
            }
            segments.append(contentsOf: piece.segments)
        }
        return Self(segments: segments)
    }

    /// Keeps a drawing available when no graph can be fetched or matched.
    public static func freehand(_ stroke: [Coordinate]) -> Self {
        let runs = stroke.split { coordinate in
            !(-90...90).contains(coordinate.latitude) || !(-180...180).contains(coordinate.longitude)
        }
        return Self(segments: runs.compactMap { StrokeResolution.freehandSegment(Array($0)) })
    }
}

struct StrokeResolution {
    private static let minimumSupportedRun = 27.0
    private static let maximumShortSupportGap = 18.0
    private static let maximumWindowLength = 2_400.0
    private static let maximumStrokeLength = 12_000.0
    private static let maximumPartialSearches = 48
    private static let maximumRepairLength = 360.0
    private static let maximumRepairAttempts = 12
    private static let maximumOpenEndRepairLength = 80.0

    let nodes: [Int64: Coordinate]
    let ways: [Way]

    func resolve(_ stroke: [Coordinate]) -> ResolvedStroke {
        guard let origin = stroke.first, stroke.count >= 2, stroke.count <= StrokeMatcher.maximumObservations,
            !ways.isEmpty, stroke.allSatisfy(\.isValid)
        else { return .freehand(stroke) }
        let projection = LocalProjection(origin: origin)
        let observed = stroke.map(projection.project)
        let lengths = zip(observed, observed.dropFirst()).map { ($1 - $0).length }
        let length = lengths.reduce(0, +)
        guard (8...Self.maximumStrokeLength).contains(length) else { return .freehand(stroke) }

        if let sampled = StrokeMatcher.resample(observed) {
            let graph = LocalGraph(nodes: nodes, ways: ways, projection: projection, stroke: sampled)
            let route = graph.match(sampled, observations: observed)
            if let alternative = graph.matchCoherentlyShifted(sampled, observations: observed, baseline: route) {
                return ResolvedStroke(segments: [
                    Self.snappedSegment(alternative, projection: projection, kind: .approximate)
                ])
            }
            if let route {
                return ResolvedStroke(segments: [Self.snappedSegment(route, projection: projection)])
            }
        }

        // Subdivide sparse events for the support check while retaining all original vertices.
        // An abrupt input jump is left as a single unsupported interval.
        var probes = [observed[0]]
        var arcs = [0.0]
        for (index, gap) in lengths.enumerated() where gap > 0 {
            let subdivisions = gap <= 250 ? Int(ceil(gap / 9)) : 1
            let start = observed[index]
            let end = observed[index + 1]
            let distance = arcs[arcs.count - 1]
            for step in 1...subdivisions {
                let fraction = Double(step) / Double(subdivisions)
                probes.append(step == subdivisions ? end : start + (end - start) * fraction)
                arcs.append(distance + gap * fraction)
            }
        }

        var accepted: [(ClosedRange<Int>, LocalGraph.Route, StrokeSegment.Kind)] = []
        var remainingSearches = Self.maximumPartialSearches
        var windowStart = 0
        while windowStart < probes.count - 1 && remainingSearches > 0 {
            var windowEnd = windowStart + 1
            while windowEnd < probes.count - 1 && arcs[windowEnd + 1] - arcs[windowStart] <= Self.maximumWindowLength {
                windowEnd += 1
            }
            let last = probes.count - 1
            // The normal window leaves room below the resampling limit for a short final remainder.
            if arcs[last] - arcs[windowEnd] < Self.minimumSupportedRun,
                arcs[last] - arcs[windowStart] <= Self.maximumWindowLength + Self.minimumSupportedRun
            {
                windowEnd = last
            }
            let window = windowStart...windowEnd
            let graph = LocalGraph(nodes: nodes, ways: ways, projection: projection, stroke: Array(probes[window]))

            func matchSupportedRun(_ run: ClosedRange<Int>) {
                let length = arcs[run.upperBound] - arcs[run.lowerBound]
                guard length >= Self.minimumSupportedRun, remainingSearches > 0,
                    let sampled = StrokeMatcher.resample(Array(probes[run]))
                else { return }
                remainingSearches -= 1
                let observations = Array(probes[run])
                if let route = graph.match(sampled, observations: observations) {
                    accepted.append((run, route, .snapped))
                } else if let route = graph.match(sampled, observations: observations, allowsApproximation: true) {
                    accepted.append((run, route, .approximate))
                } else if length >= Self.minimumSupportedRun * 2 + 9 {
                    // Keep one unverified interval freehand rather than silently joining two roads.
                    let midpoint = arcs[run.lowerBound] + length / 2
                    let right = run.first { arcs[$0] >= midpoint } ?? run.upperBound
                    matchSupportedRun(run.lowerBound...(right - 1))
                    matchSupportedRun(right...run.upperBound)
                }
            }

            var runStart: Int?
            var lastSupported = windowStart
            for index in windowStart..<windowEnd {
                let length = arcs[index + 1] - arcs[index]
                // Use a short local tangent to ignore jitter in densely delivered touch points.
                let before = max(windowStart, index - 2)
                let after = min(windowEnd, index + 3)
                let begin = arcs[index] - arcs[before] <= 9 ? probes[before] : probes[index]
                let end = arcs[after] - arcs[index + 1] <= 9 ? probes[after] : probes[index + 1]
                if length <= 250, graph.supportsTravel(from: begin, to: end) {
                    if runStart == nil { runStart = index }
                    lastSupported = index + 1
                } else if let start = runStart,
                    arcs[index + 1] - arcs[lastSupported] > Self.maximumShortSupportGap
                {
                    matchSupportedRun(start...lastSupported)
                    runStart = nil
                }
            }
            if let start = runStart { matchSupportedRun(start...lastSupported) }
            windowStart = windowEnd
        }

        guard !accepted.isEmpty else { return .freehand(stroke) }
        var segments: [StrokeSegment] = []
        var cursor = 0
        var priorEnd: Coordinate?
        var priorRoute: LocalGraph.Route?
        var repairAttempts = 0

        func repairOpenEnd(_ observed: ArraySlice<Point>, anchoredAt anchor: LocalGraph.Anchor, atStart: Bool)
            -> StrokeSegment?
        {
            let points = Array(observed)
            guard
                zip(points, points.dropFirst()).reduce(0.0, { $0 + ($1.1 - $1.0).length })
                    <= Self.maximumOpenEndRepairLength
            else { return nil }
            let graph = LocalGraph(nodes: nodes, ways: ways, projection: projection, stroke: points + [anchor.point])
            guard let connector = graph.extend(from: anchor, following: points, atStart: atStart) else { return nil }
            return StrokeSegment(
                kind: .approximate, coordinates: connector.points.map(projection.unproject),
                distanceMeters: connector.length)
        }

        for (indices, route, kind) in accepted {
            let snapped = Self.snappedSegment(route, projection: projection, kind: kind)
            var freehand: [Coordinate] = []
            if indices.lowerBound > cursor {
                freehand = probes[cursor...indices.lowerBound].map(projection.unproject)
                if let priorEnd { freehand[0] = priorEnd }
                if let start = snapped.coordinates.first { freehand[freehand.count - 1] = start }
            } else {
                if let priorEnd { freehand.append(priorEnd) }
                if let start = snapped.coordinates.first { freehand.append(start) }
            }
            if let gap = Self.freehandSegment(freehand) {
                var repaired: StrokeSegment?
                if let priorRoute, arcs[indices.lowerBound] - arcs[cursor] <= Self.maximumRepairLength,
                    repairAttempts < Self.maximumRepairAttempts
                {
                    repairAttempts += 1
                    let drawn = Array(probes[cursor...indices.lowerBound])
                    let graph = LocalGraph(
                        nodes: nodes, ways: ways, projection: projection,
                        stroke: [priorRoute.end.point, route.start.point] + drawn)
                    // Even a same-sample seam can separate independently selected edges.
                    if let connector = graph.connect(
                        from: priorRoute.end, to: route.start, following: drawn.count == 1 ? drawn + drawn : drawn,
                        entry: Self.heading(of: priorRoute.points, atStart: false),
                        exit: Self.heading(of: route.points, atStart: true))
                    {
                        repaired = StrokeSegment(
                            kind: .approximate, coordinates: connector.points.map(projection.unproject),
                            distanceMeters: connector.length)
                    }
                } else if priorRoute == nil {
                    repaired = repairOpenEnd(
                        probes[cursor...indices.lowerBound], anchoredAt: route.start, atStart: true)
                }
                segments.append(repaired ?? gap)
            }
            segments.append(snapped)
            cursor = indices.upperBound
            priorEnd = snapped.coordinates.last
            priorRoute = route
        }
        if cursor < probes.count - 1 {
            let points = probes[cursor...]
            if let priorRoute,
                let repaired = repairOpenEnd(points, anchoredAt: priorRoute.end, atStart: false)
            {
                segments.append(repaired)
            } else if let fixedEnd = priorRoute?.end.point, !Self.isLiftJitter(points, around: fixedEnd) {
                var tail = points.map(projection.unproject)
                if let priorEnd { tail[0] = priorEnd }
                if let gap = Self.freehandSegment(tail) { segments.append(gap) }
            }
        }
        return ResolvedStroke(segments: segments)
    }

    static func isLiftJitter(_ samples: ArraySlice<Point>, around anchor: Point) -> Bool {
        guard samples.count >= 6,
            let last = samples.last,
            (last - anchor).length <= 3.5,
            zip(samples, samples.dropFirst()).reduce(0.0, { $0 + ($1.1 - $1.0).length }) <= 18
        else { return false }
        let offsets = samples.map { ($0 - anchor).length }
        guard let maximum = offsets.indices.max(by: { offsets[$0] < offsets[$1] }),
            (4...6).contains(offsets[maximum])
        else { return false }
        return offsets[(maximum + 1)...].contains { $0 <= 2 }
    }

    private static func heading(of points: [Point], atStart: Bool) -> Point? {
        if atStart, let first = points.first,
            let inner = points.first(where: { ($0 - first).length >= 8 })
        {
            return inner - first
        }
        if !atStart, let last = points.last,
            let inner = points.reversed().first(where: { (last - $0).length >= 8 })
        {
            return last - inner
        }
        return nil
    }

    fileprivate static func freehandSegment(_ coordinates: [Coordinate]) -> StrokeSegment? {
        guard coordinates.count >= 2 else { return nil }
        let length = zip(coordinates, coordinates.dropFirst()).reduce(0.0) { distance, pair in
            distance + greatCircleDistance(from: pair.0, to: pair.1)
        }
        guard length > 1e-6 else { return nil }
        return StrokeSegment(kind: .freehand, coordinates: coordinates, distanceMeters: length)
    }

    private static func greatCircleDistance(from start: Coordinate, to end: Coordinate) -> Double {
        let radiansPerDegree = Double.pi / 180
        let latitudeDifference = (end.latitude - start.latitude) * radiansPerDegree
        let longitudeDifference = abs(end.longitude - start.longitude)
        let wrappedLongitude = min(longitudeDifference, 360 - longitudeDifference)
        let latitudeTerm = sin(latitudeDifference / 2)
        let longitudeTerm = sin(wrappedLongitude * radiansPerDegree / 2)
        let latitudeScales = cos(start.latitude * radiansPerDegree) * cos(end.latitude * radiansPerDegree)
        let haversine = min(1, max(0, latitudeTerm * latitudeTerm + latitudeScales * longitudeTerm * longitudeTerm))
        let earthRadiusMeters = 6_371_000.0
        return 2 * earthRadiusMeters * atan2(sqrt(haversine), sqrt(1 - haversine))
    }

    private static func snappedSegment(
        _ route: LocalGraph.Route, projection: LocalProjection, kind: StrokeSegment.Kind = .snapped
    ) -> StrokeSegment {
        StrokeSegment(
            // The shape search reconsiders fits above 5 m RMS. Show that same uncertainty
            // to the runner even when no better connected path can be established.
            kind: route.hasParallelAlternative || route.rmsOffset > 5 ? .approximate : kind,
            coordinates: route.points.map(projection.unproject), distanceMeters: route.distance)
    }
}
