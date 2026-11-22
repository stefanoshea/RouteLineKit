#if canImport(MapKit)
import MapKit

extension Coordinate {
    /// Converts a MapKit or Core Location position to a stroke sample.
    public init(_ position: CLLocationCoordinate2D) {
        self.init(latitude: position.latitude, longitude: position.longitude)
    }

    public var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension Match {
    /// An overlay of the full matched path, including intermediate road vertices.
    public var polyline: MKPolyline {
        let positions = coordinates.map(\.mapCoordinate)
        return MKPolyline(coordinates: positions, count: positions.count)
    }
}

extension StrokeSegment {
    /// An overlay for rendering this section on an `MKMapView`.
    public var polyline: MKPolyline {
        let positions = coordinates.map(\.mapCoordinate)
        return MKPolyline(coordinates: positions, count: positions.count)
    }
}
#endif
