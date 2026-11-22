import RouteLineKit
import UIKit
import XCTest

@MainActor
final class StrokeDrawingViewTests: XCTestCase {
    private final class TestTouch: UITouch {
        override func location(in view: UIView?) -> CGPoint { CGPoint(x: 12, y: 16) }
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
}
