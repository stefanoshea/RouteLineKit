#if DEBUG && targetEnvironment(simulator)
    import Foundation
    @_spi(Testing) import RouteLineKit

    enum PlannerPathFixture {
        // An invented right-angle graph for the UI tests. Its second leg starts
        // about 14.5 metres past the turn.
        static let corner = Coordinate(latitude: -33.87, longitude: 151.21)
        static let start = Coordinate(latitude: corner.latitude - 0.001, longitude: corner.longitude)
        static let end = Coordinate(latitude: corner.latitude, longitude: corner.longitude + 0.0012)
        static let afterCorner = Coordinate(latitude: corner.latitude, longitude: corner.longitude + 0.000157)
        static var stroke: [Coordinate] { [start, corner, end] }

        static var canConnect: Bool {
            ProcessInfo.processInfo.environment["ROUTELINE_UI_TEST_APPLE_CONNECTOR"] == "1"
        }

        static var preloadsDrawing: Bool {
            canConnect || ProcessInfo.processInfo.environment["ROUTELINE_UI_TEST_APPLE_GAP"] == "1"
        }

        static func walkingRoute(for samples: [Coordinate]) async throws -> ResolvedStroke {
            try await RouteLineKit.walkingRoute(for: samples, lookup: leg)
        }

        private static func leg(from source: Coordinate, to destination: Coordinate) -> [Coordinate] {
            if source == start && destination == corner { return [start, corner] }
            if source == corner && destination == end { return [afterCorner, end] }
            if canConnect && source == corner && destination == afterCorner { return [corner, afterCorner] }
            return []
        }
    }
#endif
