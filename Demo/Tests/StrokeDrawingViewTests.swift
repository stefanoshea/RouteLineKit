import RouteLineKit
import UIKit
import XCTest

@MainActor
final class StrokeDrawingViewTests: XCTestCase {
    private final class TestTouch: UITouch {
        var point: CGPoint

        init(_ point: CGPoint = CGPoint(x: 12, y: 16)) {
            self.point = point
            super.init()
        }

        override func location(in view: UIView?) -> CGPoint { point }
    }

    func testCancellingFromOnBeganClearsTheStartDotAndAllowsAnotherStroke() throws {
        let view = StrokeDrawingView()
        var cancellations = 0
        var completed: [[CGPoint]] = []
        view.onCancelled = { cancellations += 1 }
        view.onEnded = { completed.append($0) }
        view.onBegan = { [weak view] in view?.cancel() }

        let touch = TestTouch()
        view.touchesBegan([touch], with: nil)
        view.touchesEnded([touch], with: nil)
        let startDot = try XCTUnwrap(view.layer.sublayers?.last)
        XCTAssertTrue(startDot.isHidden)
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(completed.isEmpty)

        view.onBegan = nil
        view.touchesBegan([touch], with: nil)
        XCTAssertFalse(startDot.isHidden)
        view.touchesEnded([touch], with: nil)
        XCTAssertEqual(completed, [[CGPoint(x: 12, y: 16)]])
        XCTAssertTrue(startDot.isHidden)
    }

    func testMinimumPointDistanceFiltersDenseMovesAndPreservesLiftEndpoint() {
        let view = StrokeDrawingView()
        var completed: [[CGPoint]] = []
        view.onEnded = { completed.append($0) }

        let touch = TestTouch(CGPoint(x: 0, y: 0))
        view.touchesBegan([touch], with: nil)
        for next in [
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1.5, y: 0.5),
            CGPoint(x: 5, y: 0),
            CGPoint(x: 5.5, y: 0),
        ] {
            touch.point = next
            view.touchesMoved([touch], with: nil)
        }
        touch.point = CGPoint(x: 6, y: 0)
        view.touchesEnded([touch], with: nil)

        XCTAssertEqual(completed, [[CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 6, y: 0)]])
    }

    func testLineWidthUpdatesStrokeAndStartDotGeometry() throws {
        let view = StrokeDrawingView()
        let lineLayer = try XCTUnwrap(view.layer.sublayers?.first as? CAShapeLayer)
        let startDot = try XCTUnwrap(view.layer.sublayers?.last)

        view.lineWidth = 10
        XCTAssertEqual(lineLayer.lineWidth, 10)
        XCTAssertEqual(startDot.bounds.size, CGSize(width: 10, height: 10))
        XCTAssertEqual(startDot.cornerRadius, 5)

        view.lineWidth = 0
        XCTAssertEqual(lineLayer.lineWidth, 1)
        XCTAssertEqual(startDot.bounds.size, CGSize(width: 1, height: 1))
        XCTAssertEqual(startDot.cornerRadius, 0.5)
    }

    func testTraitChangeUpdatesResolvedStrokeColor() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = StrokeDrawingView(frame: window.bounds)
        view.tintColor = .systemTeal
        window.addSubview(view)
        window.makeKeyAndVisible()

        view.overrideUserInterfaceStyle = .light
        view.layoutIfNeeded()
        let lineLayer = try XCTUnwrap(view.layer.sublayers?.first as? CAShapeLayer)
        let startDot = try XCTUnwrap(view.layer.sublayers?.last)
        let lightColor = try XCTUnwrap(lineLayer.strokeColor)

        view.overrideUserInterfaceStyle = .dark
        view.layoutIfNeeded()
        let darkColor = try XCTUnwrap(lineLayer.strokeColor)
        let darkDotColor = try XCTUnwrap(startDot.backgroundColor)

        XCTAssertNotEqual(lightColor, darkColor)
        XCTAssertEqual(darkColor, darkDotColor)
    }
}
