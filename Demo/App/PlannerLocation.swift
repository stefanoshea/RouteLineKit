import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class PlannerLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var position: CLLocation?
    private(set) var isLocating = false
    private(set) var message: String?

    // Core Location delivers delegate callbacks on the run loop that created the manager.
    private let manager = CLLocationManager()
    private var awaitingAuthorization = false

    override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = self
    }

    func recenter() {
        guard !isLocating else { return }
        message = nil
        isLocating = true
        switch manager.authorizationStatus {
        case .notDetermined:
            awaitingAuthorization = true
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestPosition()
        case .denied, .restricted:
            finish("Location access is unavailable. You can move the map to your starting point.")
        @unknown default:
            finish("Location is unavailable. You can move the map to your starting point.")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isLocating, awaitingAuthorization else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            awaitingAuthorization = false
            requestPosition()
        case .denied, .restricted:
            finish("Location access is unavailable. You can move the map to your starting point.")
        case .notDetermined:
            break
        @unknown default:
            finish("Location is unavailable. You can move the map to your starting point.")
        }
    }

    private func requestPosition() {
        #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["ROUTELINE_UI_TEST_LOCATION"] == "1" {
                acceptLocations([CLLocation(latitude: -33.8320, longitude: 151.1850)])
                return
            }
        #endif
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        acceptLocations(locations)
    }

    private func acceptLocations(_ locations: [CLLocation]) {
        guard isLocating else { return }
        if let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) {
            position = location
            finish()
        } else {
            finish("Your location couldn’t be found. Try again or move the map.")
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard isLocating else { return }
        finish("Your location couldn’t be found. Try again or move the map.")
    }

    func clearMessage() {
        message = nil
    }

    func cancel() {
        guard isLocating else { return }
        manager.stopUpdatingLocation()
        finish()
    }

    private func finish(_ message: String? = nil) {
        isLocating = false
        awaitingAuthorization = false
        self.message = message
    }
}
