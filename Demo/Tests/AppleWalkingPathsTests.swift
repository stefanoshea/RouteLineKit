import Foundation
import RouteLineKit
import XCTest
@testable import RouteLineDemo

final class AppleWalkingPathsTests: XCTestCase {
    func testOrderedAnchorsAndConnectedLegsFollowTheDrawing() async throws {
        let start = coordinate(x: 0, y: 0)
        let corner = coordinate(x: 100, y: 0)
        let end = coordinate(x: 100, y: 100)
        let stroke = [start, coordinate(x: 50, y: 0), corner, coordinate(x: 100, y: 50), end]
        XCTAssertEqual(try AppleWalkingPaths.anchors(for: stroke), [start, corner, end])

        let route = try await AppleWalkingPaths { source, destination in
            [source, destination]
        }.resolve(stroke)
        XCTAssertEqual(route.snappedDistanceMeters, 200, accuracy: 0.5)
        XCTAssertEqual(route.distanceMeters, route.snappedDistanceMeters)
    }

    func testKeepsTheDrawnCornerWhenConnectedAppleLegsCutIt() async throws {
        let start = coordinate(x: 0, y: 0)
        let corner = coordinate(x: 100, y: 0)
        let end = coordinate(x: 100, y: 100)
        let stroke = [start, corner, end]
        let shortcutJoin = coordinate(x: 80, y: 20)
        let paths = AppleWalkingPaths { source, destination in
            source == start ? [source, shortcutJoin] : [shortcutJoin, destination]
        }

        let route = try await paths.resolve(stroke)
        let gap = try XCTUnwrap(route.segments.first { $0.kind == .freehand })
        XCTAssertTrue(gap.coordinates.contains(corner))
        XCTAssertFalse(route.segments.flatMap(\.coordinates).contains(shortcutJoin))
    }

    func testRejectsEndpointShortcutAcrossABlock() async throws {
        let start = coordinate(x: 0, y: 0)
        let end = coordinate(x: 100, y: 0)
        let stroke = [start, coordinate(x: 0, y: 100), coordinate(x: 100, y: 100), end]
        let paths = AppleWalkingPaths { _, _ in [start, end] }

        do {
            _ = try await paths.resolve(stroke)
            XCTFail("The direct route has no support along the three drawn sides.")
        } catch let error as AppleWalkingPaths.LookupError {
            XCTAssertEqual(error, .doesNotFollowDrawing)
        }
    }

    func testKeepsBothWalkingLegsAroundADisconnectedCorner() async throws {
        let start = coordinate(x: 0, y: 0)
        let corner = coordinate(x: 100, y: 0)
        let end = coordinate(x: 100, y: 100)
        let beforeCorner = coordinate(x: 94, y: 0)
        let afterCorner = coordinate(x: 100, y: 13.2)
        let paths = AppleWalkingPaths { source, destination in
            source == start ? [source, beforeCorner] : [afterCorner, destination]
        }

        let route = try await paths.resolve([
            start, coordinate(x: 50, y: 0), corner, coordinate(x: 100, y: 50), end,
        ])
        XCTAssertEqual(route.segments.map(\.kind), [.snapped, .freehand, .snapped])
        XCTAssertGreaterThan(route.snappedDistanceMeters, 160)
        let gap = try XCTUnwrap(route.segments.first { $0.kind == .freehand })
        XCTAssertTrue(gap.coordinates.contains(corner))
        XCTAssertGreaterThan(gap.distanceMeters, 14)
    }

    func testUsesVerifiedWalkingConnectorWithRoundedEndpointsAcrossA45MeterGap() async throws {
        let start = coordinate(x: 0, y: 0)
        let beforeCorner = coordinate(x: 80, y: 0)
        let corner = coordinate(x: 100, y: 0)
        let afterCorner = coordinate(x: 100, y: 40)
        let end = coordinate(x: 100, y: 100)
        let roundedStart = coordinate(x: 80.25, y: 0)
        let roundedEnd = coordinate(x: 100, y: 39.7)
        let paths = AppleWalkingPaths { source, destination in
            if source == start && destination == corner { return [start, beforeCorner] }
            if source == corner && destination == end { return [afterCorner, end] }
            if source == beforeCorner && destination == afterCorner { return [roundedStart, corner, roundedEnd] }
            throw AppleWalkingPaths.LookupError.noWalkingRoute
        }

        let route = try await paths.resolve([start, corner, end])
        XCTAssertEqual(route.segments.map(\.kind), [.snapped])
        XCTAssertEqual(route.snappedDistanceMeters, 200, accuracy: 0.5)
        XCTAssertTrue(route.segments.flatMap(\.coordinates).contains(corner))
    }

    func testKeepsGapFreehandWhenAppleConnectorLeavesTheDrawing() async throws {
        let start = coordinate(x: 0, y: 0)
        let beforeCorner = coordinate(x: 80, y: 0)
        let corner = coordinate(x: 100, y: 0)
        let afterCorner = coordinate(x: 100, y: 40)
        let end = coordinate(x: 100, y: 100)
        let detour = coordinate(x: 130, y: 12)
        let paths = AppleWalkingPaths { source, destination in
            if source == start && destination == corner { return [start, beforeCorner] }
            if source == corner && destination == end { return [afterCorner, end] }
            if source == beforeCorner && destination == afterCorner { return [beforeCorner, detour, afterCorner] }
            throw AppleWalkingPaths.LookupError.noWalkingRoute
        }

        let route = try await paths.resolve([start, corner, end])
        let gap = try XCTUnwrap(route.segments.first { $0.kind == .freehand })
        XCTAssertTrue(gap.coordinates.contains(corner))
        XCTAssertFalse(route.segments.flatMap(\.coordinates).contains(detour))
    }

    func testKeepsSupportedApproachesWhenAnImpreciseCornerIsFarFromBothLegs() async throws {
        let start = coordinate(x: 0, y: 0)
        let approach = coordinate(x: 70, y: 0)
        let corner = coordinate(x: 100, y: -40)
        let end = coordinate(x: 100, y: 100)
        let beforeGap = coordinate(x: 80, y: 0)
        let afterGap = coordinate(x: 100, y: 40)
        let endOfShortLeg = coordinate(x: 100, y: 45)
        let stroke = [start, coordinate(x: 35, y: 0), approach, corner, coordinate(x: 100, y: 0), endOfShortLeg, end]
        XCTAssertEqual(try AppleWalkingPaths.anchors(for: stroke), [start, approach, corner, end])
        let paths = AppleWalkingPaths { source, destination in
            if source == start { return [start, beforeGap] }
            if destination == end { return [afterGap, end] }
            return [afterGap, endOfShortLeg]
        }

        let route = try await paths.resolve(stroke)
        XCTAssertEqual(route.segments.map(\.kind), [.snapped, .freehand, .snapped])
        XCTAssertEqual(route.snappedDistanceMeters, 130, accuracy: 1)
        let gap = try XCTUnwrap(route.segments.first { $0.kind == .freehand })
        XCTAssertTrue(gap.coordinates.contains(corner))
        XCTAssertGreaterThan(gap.distanceMeters, 120)
    }

    func testAnchorSelectionBoundsRequestsOnWindingDrawing() throws {
        let stroke = (0...12).map { index in
            coordinate(x: Double(index) * 35, y: index.isMultiple(of: 2) ? 0 : 80)
        }
        let anchors = try AppleWalkingPaths.anchors(for: stroke)
        XCTAssertEqual(anchors.count, 5)
        XCTAssertEqual(anchors.first, stroke.first)
        XCTAssertEqual(anchors.last, stroke.last)
        let sourceIndices = try anchors.map { coordinate in
            try XCTUnwrap(stroke.firstIndex(of: coordinate))
        }
        XCTAssertEqual(sourceIndices, sourceIndices.sorted())
    }

    func testRejectsUnsupportedDrawingsBeforeLookingUpDirections() throws {
        let start = coordinate(x: 0, y: 0)
        for stroke in [
            [start, start],
            [start, coordinate(x: 10, y: 0)],
            [start, coordinate(x: 280, y: 0)],
            [start, Coordinate(latitude: .nan, longitude: 0)],
            [Coordinate(latitude: 0, longitude: 179.9999), Coordinate(latitude: 0, longitude: -179.9999)],
        ] {
            XCTAssertThrowsError(try AppleWalkingPaths.anchors(for: stroke)) {
                XCTAssertEqual($0 as? AppleWalkingPaths.LookupError, .unsupportedDrawing)
            }
        }
    }

    private func coordinate(x: Double, y: Double) -> Coordinate {
        Coordinate(latitude: y / 111_195, longitude: x / 111_195)
    }
}
