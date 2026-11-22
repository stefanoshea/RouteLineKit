import MapKit
import RouteLineKit
import SwiftUI
import UIKit

struct PlannerMap: UIViewRepresentable {
    let isDrawing: Bool
    let drawingRevision: Int
    let route: ResolvedStroke?
    let location: CLLocation?
    let onStrokeBegan: () -> Void
    let onStroke: ([Coordinate]) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> Surface {
        let surface = Surface()
        let map = surface.map
        map.delegate = context.coordinator
        let style = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.preferredConfiguration = style
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = false
        map.showsScale = true
        map.accessibilityIdentifier = "planner.map"
        var region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -33.8697, longitude: 151.2069),
            latitudinalMeters: 850, longitudinalMeters: 850)
        #if DEBUG && targetEnvironment(simulator)
            if PlannerPathFixture.preloadsDrawing {
                region = MKCoordinateRegion(center: PlannerPathFixture.corner.mapCoordinate,
                    latitudinalMeters: 400, longitudinalMeters: 400)
            } else if ProcessInfo.processInfo.environment["ROUTELINE_UI_TEST_APPLE_VIEWPORT"] == "1" {
                region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: -33.871675, longitude: 151.211680),
                    latitudinalMeters: 190, longitudinalMeters: 190)
            }
        #endif
        map.setRegion(region, animated: false)
        return surface
    }

    func updateUIView(_ surface: Surface, context: Context) {
        let map = surface.map
        let drawing = surface.drawing
        let coordinator = context.coordinator
        drawing.onBegan = onStrokeBegan
        drawing.onEnded = { [weak drawing, weak map] points in
            guard let drawing, let map else { return }
            let coordinates = points.map { Coordinate(map.convert($0, toCoordinateFrom: drawing)) }
            onStroke(coordinates)
        }
        if coordinator.drawingRevision != drawingRevision {
            coordinator.drawingRevision = drawingRevision
            drawing.cancel()
        }
        if drawing.isHidden == isDrawing {
            if isDrawing {
                map.setVisibleMapRect(map.visibleMapRect, animated: false)
            } else {
                drawing.cancel()
            }
            drawing.isHidden = !isDrawing
            map.isScrollEnabled = !isDrawing
            map.isZoomEnabled = !isDrawing
        }

        if let location, coordinator.location !== location {
            coordinator.location = location
            if let marker = coordinator.locationMarker {
                map.removeAnnotation(marker)
            }
            let marker = MKPointAnnotation()
            marker.title = "My location"
            marker.coordinate = location.coordinate
            coordinator.locationMarker = marker
            map.addAnnotation(marker)
            map.setRegion(
                MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 650, longitudinalMeters: 650),
                animated: !isDrawing && !reduceMotion
            )
        }

        if coordinator.route != route {
            map.removeOverlays(map.overlays)
            coordinator.route = route
            coordinator.styles.removeAll()
            if let route {
                let overlays = route.segments.map { segment in
                    let coordinates = segment.coordinates.map(\.mapCoordinate)
                    let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
                    coordinator.styles[ObjectIdentifier(line)] = RouteStyle(kind: segment.kind)
                    return line
                }
                map.addOverlays(overlays, level: .aboveLabels)
            }
        }
    }

    final class Surface: UIView {
        let map = MKMapView()
        let drawing = StrokeDrawingView()
        private var previousSize: CGSize = .zero

        init() {
            super.init(frame: .zero)
            addSubview(map)
            addSubview(drawing)
            drawing.tintColor = .systemTeal
            drawing.isHidden = true
            for view in [map, drawing] {
                view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: trailingAnchor),
                    view.topAnchor.constraint(equalTo: topAnchor),
                    view.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != previousSize {
                drawing.cancel()
                previousSize = bounds.size
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var route: ResolvedStroke?
        var drawingRevision = 0
        var location: CLLocation?
        var locationMarker: MKPointAnnotation?
        var styles: [ObjectIdentifier: RouteStyle] = [:]

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline, let style = styles[ObjectIdentifier(line)] else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = style.color
            renderer.lineWidth = 5
            renderer.lineCap = style.kind == .approximate ? .butt : .round
            renderer.lineJoin = .round
            renderer.lineDashPattern = style.dashPattern?.map { NSNumber(value: Double($0)) }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let locationMarker, annotation === locationMarker else { return nil }
            let identifier = "CurrentLocation"
            let marker = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            marker.annotation = annotation
            marker.markerTintColor = .systemBlue
            marker.glyphImage = UIImage(systemName: "location.fill")
            marker.canShowCallout = true
            marker.accessibilityIdentifier = "planner.location.position"
            return marker
        }
    }
}

struct RouteStyle {
    let kind: StrokeSegment.Kind

    var color: UIColor {
        switch kind {
        case .snapped: .systemBlue
        case .approximate: .systemOrange
        case .freehand: .systemTeal
        }
    }

    var dashPattern: [CGFloat]? {
        switch kind {
        case .snapped: nil
        case .approximate: [7, 3]
        case .freehand: [1, 5]
        }
    }
}
