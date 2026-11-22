import Foundation

struct LocalGraph {
    private static let maximumOffset = 24.0
    private static let maximumEndpointOffset = 12.0
    private static let maximumCorroboratedEndpointOffset = 18.0
    private static let maximumTurnOffset = 10.0

    private struct Segment {
        let way: Int64
        let a: Int64
        let b: Int64
        let start: Point
        let end: Point
        let length: Double
    }
    private struct Candidate {
        let segment: Int
        let fraction: Double
        let point: Point
        let distance: Double
        let emission: Double
    }
    private struct Walk {
        let length: Double
        let steps: [Step]
    }
    private struct Step {
        let segment: Int
        let way: Int64
        let end: Point
        let length: Double
    }
    struct Anchor {
        let way: Int64
        let a: Int64
        let b: Int64
        let fraction: Double
        let point: Point
    }
    struct Route {
        let points: [Point]
        let distance: Double
        let distanceByWayID: [Int64: Double]
        let rmsOffset: Double
        let hasParallelAlternative: Bool
        let start: Anchor
        let end: Anchor
    }

    struct Gap {
        let points: [Point]
        let length: Double
    }

    private let nodes: [Int64: Point]
    private let segments: [Segment]
    private let adjacency: [Int64: [Int]]

    init(nodes: [Int64: Coordinate], ways: [Way], projection: LocalProjection, stroke: [Point]) {
        let minX = (stroke.map(\.x).min() ?? 0) - 64
        let maxX = (stroke.map(\.x).max() ?? 0) + 64
        let minY = (stroke.map(\.y).min() ?? 0) - 64
        let maxY = (stroke.map(\.y).max() ?? 0) + 64
        let positions = nodes.filter { $0.value.isValid }.mapValues(projection.project)
        var segments: [Segment] = []
        var adjacency: [Int64: [Int]] = [:]
        for way in ways {
            for (a, b) in zip(way.nodeIDs, way.nodeIDs.dropFirst()) {
                guard let start = positions[a], let end = positions[b],
                    max(start.x, end.x) >= minX, min(start.x, end.x) <= maxX,
                    max(start.y, end.y) >= minY, min(start.y, end.y) <= maxY
                else { continue }
                let length = (end - start).length
                guard (0.01...10_000).contains(length) else { continue }
                adjacency[a, default: []].append(segments.count)
                adjacency[b, default: []].append(segments.count)
                segments.append(.init(way: way.id, a: a, b: b, start: start, end: end, length: length))
            }
        }
        self.nodes = positions
        self.segments = segments
        self.adjacency = adjacency
    }

    // The partial matcher uses this only to locate stretches worth testing with the full graph search.
    func supportsTravel(from start: Point, to end: Point) -> Bool {
        let motion = end - start
        let length = motion.length
        guard length > 0 else { return false }
        let midpoint = (start + end) * 0.5
        return segments.contains { segment in
            let direction = segment.end - segment.start
            guard abs(motion.dot(direction)) >= 0.8 * length * segment.length else { return false }
            let projected = midpoint.projection(from: segment.start, to: segment.end).point
            guard (midpoint - projected).length <= Self.maximumOffset else { return false }
            let a = start.projection(from: segment.start, to: segment.end).point
            let b = end.projection(from: segment.start, to: segment.end).point
            return (b - a).length >= length * 0.45
        }
    }

    func match(_ stroke: [Point], observations: [Point], allowsApproximation: Bool = false) -> Route? {
        match(stroke, observations: observations, allowsApproximation: allowsApproximation, anchors: nil)
    }

    private func match(
        _ stroke: [Point], observations: [Point], allowsApproximation: Bool, anchors: (Candidate, Candidate)?
    ) -> Route? {
        let layers = stroke.indices.map { index in
            if let anchors {
                if index == 0 { return [anchors.0] }
                if index == stroke.count - 1 { return [anchors.1] }
            }
            let tangent = stroke[min(index + 1, stroke.count - 1)] - stroke[max(index - 1, 0)]
            let isEndpoint = index == 0 || index == stroke.count - 1
            let radius =
                anchors != nil
                ? 30 : isEndpoint && !allowsApproximation ? Self.maximumEndpointOffset : Self.maximumOffset
            let nearby = candidates(
                near: stroke[index], tangent: tangent, radius: radius,
                minimumAlignment: isEndpoint && allowsApproximation ? 0.8 : 0)
            // A longer stroke can establish the intended road just after touchdown or before lift.
            guard isEndpoint, nearby.isEmpty, stroke.count >= 5 else { return nearby }
            return candidates(
                near: stroke[index], tangent: tangent, radius: Self.maximumCorroboratedEndpointOffset)
        }
        guard layers.allSatisfy({ !$0.isEmpty }) else { return nil }

        // Track the lowest scoring connected history for each projection of each sample.
        var scores = layers[0].map(\.emission)
        var trace: [[(index: Int, walk: Walk)?]] = [[]]
        for index in stroke.indices.dropFirst() {
            let gap = (stroke[index] - stroke[index - 1]).length
            let previous = layers[index - 1]
            var nextScores: [Double] = []
            var links: [(index: Int, walk: Walk)?] = []
            let limit = max(38, gap * 3)
            let endpoints = Set(previous.flatMap { [segments[$0.segment].a, segments[$0.segment].b] })
            let paths = Dictionary(uniqueKeysWithValues: endpoints.map { ($0, walks(from: $0, limit: limit)) })
            for candidate in layers[index] {
                var bestScore = Double.infinity
                var best: (Int, Walk)?
                for (source, prior) in previous.enumerated() where scores[source].isFinite {
                    guard let walk = transition(from: prior, to: candidate, paths: paths),
                        walk.length <= limit
                    else { continue }
                    let stretch = abs(walk.length - gap) / 7
                    let score = scores[source] + candidate.emission + stretch * stretch
                    if score < bestScore {
                        bestScore = score
                        best = (source, walk)
                    }
                }
                nextScores.append(bestScore)
                links.append(best)
            }
            scores = nextScores
            trace.append(links)
        }

        guard var selected = scores.indices.min(by: { scores[$0] < scores[$1] }),
            scores[selected].isFinite
        else { return nil }
        var chosen = [layers[stroke.count - 1][selected]]
        var walks: [Walk] = []
        for index in stroke.indices.dropFirst().reversed() {
            guard let link = trace[index][selected] else { return nil }
            walks.append(link.walk)
            selected = link.index
            chosen.append(layers[index - 1][selected])
        }

        let rms = sqrt(chosen.reduce(0) { $0 + $1.distance * $1.distance } / Double(chosen.count))
        guard let start = chosen.last else { return nil }
        if anchors != nil {
            guard rms <= 20 else { return nil }
        } else if allowsApproximation {
            guard rms <= 22, chosen.count >= 4, isAligned(stroke, with: chosen.reversed()) else { return nil }
        } else {
            guard rms <= 15, Self.supportsEndpoint(chosen.prefix(4)),
                Self.supportsEndpoint(chosen.reversed().prefix(4))
            else { return nil }
        }
        var points = [start.point]
        var metersByWay: [Int64: Double] = [:]
        for walk in walks.reversed() {
            for step in walk.steps where step.length > 0 {
                points.append(step.end)
                metersByWay[step.way, default: 0] += step.length
            }
        }
        let length = metersByWay.keys.sorted().reduce(0) { $0 + metersByWay[$1, default: 0] }
        let strokeLength = zip(stroke, stroke.dropFirst()).reduce(0.0) { $0 + ($1.1 - $1.0).length }
        guard points.count > 1, length >= strokeLength * 0.70, length <= strokeLength * 1.50
        else { return nil }

        // Resampling can hide a sharp spike, so check every original observation too.
        let routeEdges = Array(zip(points, points.dropFirst()))
        func follows(_ point: Point, within radius: Double) -> Bool {
            routeEdges.contains { start, end in
                (point - point.projection(from: start, to: end).point).length <= radius
            }
        }
        guard observations.allSatisfy({ follows($0, within: anchors == nil ? Self.maximumOffset : 30) }) else {
            return nil
        }

        // Compare a turn over about four sample intervals to ignore minor finger jitter.
        // A straight shortcut can pass the general offset check while missing the corner.
        if stroke.count >= 5 {
            for index in 2..<(stroke.count - 2) {
                let sample = stroke[index]
                let chord = sample.projection(from: stroke[index - 2], to: stroke[index + 2]).point
                if (sample - chord).length > Self.maximumTurnOffset, !follows(sample, within: Self.maximumTurnOffset) {
                    return nil
                }
            }
        }

        // A different sidewalk or carriageway can also follow the finger for a full block.
        // Keep the chosen geometry, but let the presentation flag this ambiguity.
        var parallelLength = 0.0
        var hasParallelAlternative = false
        for (index, selected) in chosen.reversed().enumerated() where index > 0 {
            let direction = stroke[index] - stroke[index - 1]
            let closeParallel = layers[index].contains { other in
                let edge = segments[other.segment]
                let separation = (other.point - selected.point).length
                guard (5...22).contains(separation), other.distance <= 21 else { return false }
                let lateral = other.point - selected.point
                let span = direction.length
                return span > 0 && abs(lateral.dot(direction)) <= 0.45 * separation * span
                    && abs((edge.end - edge.start).dot(direction)) >= 0.9 * edge.length * span
                    && abs((segments[selected.segment].end - segments[selected.segment].start).dot(direction))
                        >= 0.9 * segments[selected.segment].length * span
            }
            parallelLength = closeParallel ? parallelLength + direction.length : 0
            if parallelLength >= 32 {
                hasParallelAlternative = true
                break
            }
        }
        return Route(
            points: points, distance: length, distanceByWayID: metersByWay, rmsOffset: rms,
            hasParallelAlternative: hasParallelAlternative, start: anchor(of: start), end: anchor(of: chosen[0]))
    }

    private func anchor(of candidate: Candidate) -> Anchor {
        let edge = segments[candidate.segment]
        return Anchor(way: edge.way, a: edge.a, b: edge.b, fraction: candidate.fraction, point: candidate.point)
    }

    /// Extends a supported route only when the loose end already points along a nearby mapped edge.
    /// The exposed endpoint cannot corroborate a wider search with a second accepted road.
    func extend(from fixed: Anchor, following drawing: [Point], atStart: Bool) -> Gap? {
        let outward = atStart ? Array(drawing.reversed()) : drawing
        guard let endpoint = outward.last, Self.pathLength(outward) >= 5,
            let approach = outward.dropLast().reversed().first(where: { (endpoint - $0).length >= 4 })
        else { return nil }
        let matches = candidates(
            near: endpoint, tangent: endpoint - approach, radius: Self.maximumEndpointOffset, minimumAlignment: 0.8)
        var selected: Gap?
        for candidate in matches.prefix(4) {
            let loose = anchor(of: candidate)
            let start = atStart ? loose : fixed
            let end = atStart ? fixed : loose
            guard let route = connect(from: start, to: end, following: drawing, allowsWideSearch: false) else {
                continue
            }
            if let selected {
                if Self.divergesMaterially(route.points, from: selected.points) { return nil }
            } else {
                selected = route
            }
        }
        return selected
    }

    func connect(
        from start: Anchor, to end: Anchor, following drawn: [Point], allowsWideSearch: Bool = true,
        entry: Point? = nil, exit: Point? = nil
    ) -> Gap? {
        guard let first = anchoredCandidate(start), let last = anchoredCandidate(end), drawn.count >= 2 else {
            return nil
        }
        // Stable when the two matches came from separate graph windows.
        let sketch = [start.point] + drawn.dropFirst().dropLast() + [end.point]
        let observedLength = Self.pathLength(drawn)
        let anchoredLength = Self.pathLength(sketch)
        let limit = max(18, min(460, observedLength * 1.25 + 8))
        let allowedLength = max(0.1, observedLength * 0.76 - 4)...limit
        let edge = segments[first.segment]
        let endpoints = Set([edge.a, edge.b])
        func paths(excluding segment: Int? = nil) -> [Int64: [Int64: Walk]] {
            Dictionary(
                uniqueKeysWithValues: endpoints.map {
                    ($0, walks(from: $0, limit: limit, nodeLimit: 1_500, excluding: segment))
                })
        }
        guard let walk = transition(from: first, to: last, paths: paths()) else { return nil }
        func checked(_ points: [Point], length: Double) -> Gap? {
            guard points.count >= 2, allowedLength.contains(length) else { return nil }
            var route = points
            route[route.count - 1] = end.point
            // Align the lines in travel order. This permits a corner to move slightly
            // earlier or later without treating travel along the same corridor as a detour.
            let count = max(4, Int(ceil(max(length, anchoredLength) / 4)))
            let actual = Self.samplePath(route, steps: count)
            let reference = Self.samplePath(sketch, steps: count)
            guard Self.alignsInOrder(actual, with: reference),
                Self.keepsTurns(in: reference, along: route)
            else { return nil }
            return Gap(points: route, length: length)
        }
        let shortest = [start.point] + walk.steps.filter { $0.length > 0.000_001 }.map(\.end)
        // Prefer the geometry-aware route to the shortest connector when the stroke
        // turns and both options actually reach the exact accepted graph anchors.
        if let sampled = StrokeMatcher.resample(sketch, preservingReversals: true),
            let candidate = match(sampled, observations: sketch, allowsApproximation: false, anchors: (first, last)),
            let repair = checked(candidate.points, length: candidate.distance)
        {
            return repair
        }
        if let repair = checked(shortest, length: walk.length) { return repair }

        // A runner may draw loosely around a corner. Only use a wider corridor
        // when the turn is still supported and competing paths cannot reproduce it.
        guard allowsWideSearch else { return nil }
        func looselyFollows(_ candidate: Walk) -> Bool {
            guard (max(18, observedLength * 0.50)...limit).contains(candidate.length) else { return false }
            let route = [start.point] + candidate.steps.filter { $0.length > 0.000_001 }.map(\.end)
            let steps = max(8, Int(ceil(max(candidate.length, anchoredLength) / 4)))
            let actual = Self.samplePath(route, steps: steps)
            let reference = Self.samplePath(sketch, steps: steps)
            if Self.sharesBroadBends(actual, with: reference) {
                return Self.alignsInOrder(actual, with: reference, maxOffset: 38, averageOffset: 25)
            }
            // Compare with the anchored sketch. A well-supported match can move the
            // boundary along the road, changing the length of this interval.
            guard let entry, let exit,
                (drawn[0] - start.point).length <= Self.maximumOffset,
                (drawn[drawn.count - 1] - end.point).length <= Self.maximumOffset,
                abs(candidate.length - anchoredLength) <= 0.15 * anchoredLength
            else {
                return false
            }
            return Self.continuesCorridor(actual, following: reference, entry: entry, exit: exit)
                && Self.alignsInOrder(actual, with: reference, maxOffset: 34, averageOffset: 25)
        }
        guard looselyFollows(walk) else { return nil }
        let edges = Set(walk.steps.filter { $0.length > 0.01 }.map(\.segment))
        guard edges.count <= 24 else { return nil }
        for edge in edges.sorted() {
            if let alternative = transition(
                from: first, to: last, paths: paths(excluding: edge), excluding: edge),
                looselyFollows(alternative),
                Self.divergesMaterially(
                    [start.point] + alternative.steps.filter { $0.length > 0.000_001 }.map(\.end), from: shortest)
            {
                return nil
            }
        }
        var points = shortest
        points[points.count - 1] = end.point
        return Gap(points: points, length: walk.length)
    }

    private static func divergesMaterially(_ alternative: [Point], from primary: [Point]) -> Bool {
        let primaryEdges = Array(zip(primary, primary.dropFirst()))
        let samples = samplePath(alternative, steps: 24)
        let offsets = samples.map { point in
            primaryEdges.map { (point - point.projection(from: $0, to: $1).point).length }.min() ?? .infinity
        }
        // A very local fork or duplicate mapping can describe the same corridor.
        // A second plausible street or trail should stop the wider inference.
        return offsets.contains { $0 > 22 } || offsets.filter { $0 > 10 }.count >= 6
    }

    private func anchoredCandidate(_ anchor: Anchor) -> Candidate? {
        guard let index = segments.firstIndex(where: { $0.way == anchor.way && $0.a == anchor.a && $0.b == anchor.b })
        else { return nil }
        return Candidate(segment: index, fraction: anchor.fraction, point: anchor.point, distance: 0, emission: 0)
    }

    private static func pathLength(_ points: [Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0.0) { $0 + ($1.1 - $1.0).length }
    }

    private static func samplePath(_ points: [Point], steps: Int) -> [Point] {
        let edges = zip(points, points.dropFirst()).map { (start: $0, delta: $1 - $0) }.filter { $0.delta.length > 0 }
        let lengths = edges.map { $0.delta.length }
        let length = lengths.reduce(0, +)
        guard let first = points.first, let last = points.last, length > 0 else {
            return Array(repeating: points[0], count: steps + 1)
        }
        var sampled = [first]
        var edge = 0
        var covered = 0.0
        for index in 1..<steps {
            let distance = length * Double(index) / Double(steps)
            while edge + 1 < edges.count, covered + lengths[edge] < distance {
                covered += lengths[edge]
                edge += 1
            }
            sampled.append(edges[edge].start + edges[edge].delta * ((distance - covered) / lengths[edge]))
        }
        sampled.append(last)
        return sampled
    }

    private static func keepsTurns(in drawing: [Point], along route: [Point]) -> Bool {
        let edges = zip(route, route.dropFirst())
        for index in drawing.indices.dropFirst(3).dropLast(3) {
            let point = drawing[index]
            let entry = drawing[index - 3]
            let exit = drawing[index + 3]
            let incoming = point - entry
            let outgoing = exit - point
            let magnitude = incoming.length * outgoing.length
            guard magnitude > 16, incoming.dot(outgoing) < 0.72 * magnitude,
                (point - point.projection(from: entry, to: exit).point).length > 5.5
            else { continue }
            if !edges.contains(where: {
                (point - point.projection(from: $0, to: $1).point).length <= 10
            }) {
                return false
            }
        }
        return true
    }

    private static func alignsInOrder(
        _ route: [Point], with drawing: [Point], maxOffset: Double = 30, averageOffset: Double = 18
    ) -> Bool {
        // Find a monotone alignment within the corridor, penalizing displacement in
        // both directions. A path taking a very different route cannot rejoin later
        // and use the same close endpoint to hide its unsupported middle.
        let maximumSquaredOffset = maxOffset * maxOffset
        let averageSquaredOffset = averageOffset * averageOffset
        var prior = Array(repeating: Double.infinity, count: route.count + 1)
        prior[0] = 0
        for point in drawing {
            var current = Array(repeating: Double.infinity, count: route.count + 1)
            for (index, projected) in route.enumerated() {
                let offset = point - projected
                let squared = offset.dot(offset)
                guard squared <= maximumSquaredOffset else { continue }
                current[index + 1] = min(
                    prior[index] + 2 * squared,
                    prior[index + 1] + squared,
                    current[index] + squared)
            }
            prior = current
        }
        return prior[route.count] <= averageSquaredOffset * Double(drawing.count + route.count)
    }

    private static func sharesBroadBends(_ route: [Point], with drawing: [Point]) -> Bool {
        guard let first = drawing.first, let last = drawing.last else { return false }
        let chord = last - first
        guard chord.length >= 12 else { return false }
        let axis = chord * (1 / chord.length)
        func profile(_ points: [Point]) -> (left: Double, right: Double, backtrack: Double) {
            var peak = 0.0
            var backtrack = 0.0
            var left = 0.0
            var right = 0.0
            for point in points {
                let delta = point - first
                let lateral = axis.x * delta.y - axis.y * delta.x
                left = max(left, lateral)
                right = max(right, -lateral)
                let along = axis.dot(delta)
                peak = max(peak, along)
                backtrack = max(backtrack, peak - along)
            }
            return (left, right, backtrack)
        }
        let observed = profile(drawing)
        let mapped = profile(route)
        // Genuine reversals must remain freehand unless the close-fit test already proved them.
        guard max(observed.backtrack, mapped.backtrack) <= 18 else { return false }
        for (a, b) in [(observed.left, mapped.left), (observed.right, mapped.right)] {
            // Keep significant bends on the side of the chord where the user drew them.
            if max(a, b) >= 19 && min(a, b) < max(a, b) * 0.30 { return false }
        }
        return true
    }

    private static func continuesCorridor(_ route: [Point], following drawing: [Point], entry: Point, exit: Point)
        -> Bool
    {
        let origin = route[0]
        let chord = route[route.count - 1] - origin
        let span = chord.length
        guard span >= 90, let roadEntry = route.first(where: { ($0 - origin).length >= 10 }),
            let roadExit = route.reversed().first(where: { (route[route.count - 1] - $0).length >= 10 })
        else { return false }
        let axis = chord * (1 / span)
        func aligns(_ a: Point, _ b: Point) -> Bool {
            a.length > 0 && b.length > 0 && a.dot(b) >= 0.7 * a.length * b.length
        }
        guard aligns(entry, roadEntry - origin), aligns(exit, route[route.count - 1] - roadExit),
            aligns(entry, axis), aligns(exit, axis)
        else { return false }

        // A short lateral drift soon after a seam can lie across a broad mapped curve.
        // Reject deliberate interior bends and retracing even when endpoints line up.
        for (line, isDrawing) in [(route, false), (drawing, true)] {
            var progress = 0.0
            for point in line {
                let delta = point - origin
                let forward = axis.dot(delta)
                let offset = abs(axis.x * delta.y - axis.y * delta.x)
                guard forward >= progress - 8, offset <= 24 else { return false }
                if isDrawing, offset > 17, (span * 0.30...span * 0.70).contains(forward) {
                    return false
                }
                progress = max(progress, forward)
            }
        }
        return true
    }

    func matchCoherentlyShifted(_ stroke: [Point], observations: [Point], baseline: Route?) -> Route? {
        guard (13...200).contains(stroke.count), baseline?.rmsOffset ?? .infinity > 5 else { return nil }
        let turns = stroke.indices.dropFirst(2).dropLast(2).reduce(into: [Int]()) { turns, index in
            let incoming = stroke[index] - stroke[index - 2]
            let outgoing = stroke[index + 2] - stroke[index]
            let denominator = incoming.length * outgoing.length
            guard denominator > 64, abs(incoming.x * outgoing.y - incoming.y * outgoing.x) >= 0.5 * denominator,
                (stroke[index] - stroke[index].projection(from: stroke[index - 2], to: stroke[index + 2]).point)
                    .length >= 6, index - (turns.last ?? -5) >= 5
            else { return }
            turns.append(index)
        }
        guard turns.count >= 2 else { return nil }

        // Rank a small grid of coherent shifts using evenly spaced checks and additional bend checks.
        // Connected route search and the ordinary turn veto still apply to the shortlisted shifts.
        let sampleStep = max(4, stroke.count / 20)
        let probes = Set(stride(from: 0, to: stroke.count, by: sampleStep)).union(turns).sorted()
        var shifts: [(delta: Point, score: Double)] = []
        for x in [-16.0, -8, 0, 8, 16] {
            for y in [-16.0, -8, 0, 8, 16] where x != 0 || y != 0 {
                let delta = Point(x: x, y: y)
                guard delta.length <= 20 else { continue }
                var error = 0.0
                for index in probes {
                    let at = stroke[index] + delta
                    let nearest = segments.reduce(256.0) { best, edge in
                        let offset = at - at.projection(from: edge.start, to: edge.end).point
                        return min(best, offset.dot(offset))
                    }
                    error += nearest * (turns.contains(index) ? 2 : 1)
                }
                shifts.append((delta, sqrt(error / Double(probes.count + turns.count)) + delta.length * 0.15))
            }
        }
        shifts.sort { $0.score < $1.score }
        let shortList = shifts.reduce(into: [Point]()) { result, shift in
            if result.count < 5 && result.allSatisfy({ ($0 - shift.delta).length >= 8 }) { result.append(shift.delta) }
        }
        var best: Route?
        var score = min(8.0, (baseline?.rmsOffset ?? .infinity) - 3)
        let turnSamples = StrokeMatcher.resample(observations, preservingReversals: true) ?? stroke
        for delta in shortList {
            guard let candidate = match(turnSamples.map { $0 + delta }, observations: observations.map { $0 + delta }),
                candidate.rmsOffset <= 4.5,
                candidate.distanceByWayID.keys != baseline?.distanceByWayID.keys
            else { continue }
            let adjustedScore = candidate.rmsOffset + delta.length * 0.23
            if adjustedScore < score {
                best = candidate
                score = adjustedScore
            }
        }
        return best
    }

    private func isAligned(_ stroke: [Point], with chosen: ReversedCollection<[Candidate]>) -> Bool {
        // Compare travel direction between consecutive projections, including its sign. An
        // approximate route may be consistently displaced, but cannot turn away or stagnate.
        let observed = zip(stroke, stroke.dropFirst()).map { $1 - $0 }
        let projected = zip(chosen, chosen.dropFirst()).map { $1.point - $0.point }
        let agreements = zip(observed, projected).filter { a, b in
            let length = a.length
            let progress = b.length
            return progress >= length * 0.5 && a.dot(b) >= 0.8 * length * progress
        }.count
        return agreements * 5 >= observed.count * 4
    }

    private static func supportsEndpoint(_ projections: some Sequence<Candidate>) -> Bool {
        var window = projections.makeIterator()
        guard let endpoint = window.next(), endpoint.distance > Self.maximumEndpointOffset else { return true }
        var closeSamples = 0
        while let sample = window.next() {
            if sample.distance <= Self.maximumEndpointOffset {
                closeSamples += 1
            }
        }
        return closeSamples >= 2
    }

    private func candidates(near point: Point, tangent: Point, radius: Double, minimumAlignment: Double = 0)
        -> [Candidate]
    {
        var matches: [Candidate] = []
        for (index, segment) in segments.enumerated() {
            let delta = segment.end - segment.start
            let (projected, fraction) = point.projection(from: segment.start, to: segment.end)
            let distance = (point - projected).length
            guard distance <= radius else { continue }
            let alignment = tangent.length > 0 ? abs(tangent.dot(delta)) / (tangent.length * segment.length) : 1
            guard alignment >= minimumAlignment else { continue }
            let scaled = distance / 6
            matches.append(
                .init(
                    segment: index, fraction: fraction, point: projected, distance: distance,
                    emission: scaled * scaled + 1.75 * (1 - alignment)))
        }
        return Array(
            matches.sorted {
                $0.emission == $1.emission ? $0.segment < $1.segment : $0.emission < $1.emission
            }.prefix(8))
    }

    private func walks(from start: Int64, limit: Double, nodeLimit: Int = .max, excluding: Int? = nil) -> [Int64: Walk]
    {
        var frontier = [start: Walk(length: 0, steps: [])]
        var result: [Int64: Walk] = [:]
        while result.count < nodeLimit,
            let (node, walk) = frontier.min(by: {
                $0.value.length == $1.value.length ? $0.key < $1.key : $0.value.length < $1.value.length
            })
        {
            frontier.removeValue(forKey: node)
            result[node] = walk
            for edge in adjacency[node, default: []] where edge != excluding {
                let segment = segments[edge]
                let next = segment.a == node ? segment.b : segment.a
                guard result[next] == nil, let end = nodes[next] else { continue }
                let length = walk.length + segment.length
                guard length <= limit, length < frontier[next, default: .init(length: .infinity, steps: [])].length
                else { continue }
                frontier[next] = Walk(
                    length: length,
                    steps: walk.steps + [
                        .init(segment: edge, way: segment.way, end: end, length: segment.length)
                    ])
            }
        }
        return result
    }

    private func transition(
        from source: Candidate, to target: Candidate, paths: [Int64: [Int64: Walk]], excluding: Int? = nil
    ) -> Walk? {
        let a = segments[source.segment]
        let b = segments[target.segment]
        var best: Walk?
        if source.segment == target.segment && source.segment != excluding {
            let length = abs(source.fraction - target.fraction) * a.length
            best = Walk(
                length: length, steps: [.init(segment: source.segment, way: a.way, end: target.point, length: length)])
        }
        let starts = [(a.a, a.start, source.fraction * a.length), (a.b, a.end, (1 - source.fraction) * a.length)]
        let ends = [(b.a, target.fraction * b.length), (b.b, (1 - target.fraction) * b.length)]
        for (start, point, departure) in starts {
            for (end, arrival) in ends {
                guard let middle = paths[start]?[end] else { continue }
                let length = departure + middle.length + arrival
                if length < (best?.length ?? .infinity) {
                    best = Walk(
                        length: length,
                        steps: [.init(segment: source.segment, way: a.way, end: point, length: departure)]
                            + middle.steps
                            + [.init(segment: target.segment, way: b.way, end: target.point, length: arrival)])
                }
            }
        }
        return best
    }
}
