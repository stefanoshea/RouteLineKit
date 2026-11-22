import Foundation

/// A WGS84 coordinate in degrees. The matcher validates input before using it.
public struct Coordinate: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    // The local projection uses a fixed longitude scale and excludes polar regions.
    var isValid: Bool {
        (-85...85).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// A graph vertex. Ways connect only when they share a node ID.
public struct Node: Sendable, Equatable {
    public let id: Int64
    public let coordinate: Coordinate

    public init(id: Int64, coordinate: Coordinate) {
        self.id = id
        self.coordinate = coordinate
    }
}

/// Consecutive node IDs describe bidirectional edges in this matcher.
public struct Way: Sendable, Equatable {
    public let id: Int64
    public let nodeIDs: [Int64]

    public init(id: Int64, nodeIDs: [Int64]) {
        self.id = id
        self.nodeIDs = nodeIDs
    }
}

struct Point: Equatable {
    let x: Double
    let y: Double

    static func + (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: Self, rhs: Self) -> Self { .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: Self, rhs: Double) -> Self { .init(x: lhs.x * rhs, y: lhs.y * rhs) }

    func dot(_ other: Self) -> Double { x * other.x + y * other.y }
    var length: Double { hypot(x, y) }

    func projection(from start: Self, to end: Self) -> (point: Self, fraction: Double) {
        let delta = end - start
        let squaredLength = delta.dot(delta)
        guard squaredLength > 0 else { return (start, 0) }
        let fraction = max(0, min(1, (self - start).dot(delta) / squaredLength))
        return (start + delta * fraction, fraction)
    }
}

struct LocalProjection {
    private static let metersPerDegree = 111_195.0
    private let origin: Coordinate
    private let longitudeScale: Double

    init(origin: Coordinate) {
        self.origin = origin
        longitudeScale = Self.metersPerDegree * cos(origin.latitude * .pi / 180)
    }

    func project(_ coordinate: Coordinate) -> Point {
        .init(
            x: Self.wrappedLongitude(coordinate.longitude - origin.longitude) * longitudeScale,
            y: (coordinate.latitude - origin.latitude) * Self.metersPerDegree)
    }

    func unproject(_ point: Point) -> Coordinate {
        .init(
            latitude: origin.latitude + point.y / Self.metersPerDegree,
            longitude: Self.wrappedLongitude(origin.longitude + point.x / longitudeScale))
    }

    private static func wrappedLongitude(_ longitude: Double) -> Double {
        if longitude > 180 { return longitude - 360 }
        if longitude < -180 { return longitude + 360 }
        return longitude
    }
}
