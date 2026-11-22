#if canImport(UIKit)
import UIKit

/// Place above a stationary map while drawing. Points are in this view's coordinate space.
@MainActor
public final class StrokeDrawingView: UIView {
    public var onBegan: (() -> Void)?
    public var onEnded: (([CGPoint]) -> Void)?
    public var onCancelled: (() -> Void)?

    public var lineWidth: CGFloat = 5 {
        didSet {
            updateLineGeometry()
        }
    }

    public var minimumPointDistance: CGFloat = 2

    private let line = CAShapeLayer()
    private let startDot = CALayer()
    private var activeTouch: UITouch?
    private var points: [CGPoint] = []
    private var path = CGMutablePath()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isOpaque = false
        isMultipleTouchEnabled = true
        clipsToBounds = true
        line.fillColor = nil
        line.lineCap = .round
        line.lineJoin = .round
        updateLineGeometry()
        updateStrokeColors()
        startDot.isHidden = true
        layer.addSublayer(line)
        layer.addSublayer(startDot)
        line.actions = ["path": NSNull()]
        startDot.actions = ["position": NSNull(), "hidden": NSNull()]
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: StrokeDrawingView, _) in
            view.updateStrokeColors()
        }
    }

    private func updateLineGeometry() {
        let width = max(1, lineWidth)
        line.lineWidth = width
        startDot.bounds.size = CGSize(width: width, height: width)
        startDot.cornerRadius = width / 2
    }

    private func updateStrokeColors() {
        let resolved = tintColor.resolvedColor(with: traitCollection).cgColor
        line.strokeColor = resolved
        startDot.backgroundColor = resolved
    }

    public override func tintColorDidChange() {
        super.tintColorDidChange()
        updateStrokeColors()
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        let point = touch.location(in: self)
        points = [point]
        path = CGMutablePath()
        path.move(to: point)
        startDot.position = point
        startDot.isHidden = false
        onBegan?()
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        appendSamples(touch, event: event, includingFinalPoint: false)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        appendSamples(touch, event: event, includingFinalPoint: true)
        let completed = points
        reset()
        onEnded?(completed)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancel()
    }

    /// Discards an interrupted gesture, for example when switching out of drawing mode.
    public func cancel() {
        guard activeTouch != nil else { return }
        reset()
        onCancelled?()
    }

    private func appendSamples(_ touch: UITouch, event: UIEvent?, includingFinalPoint: Bool) {
        var appended = false
        for sample in event?.coalescedTouches(for: touch) ?? [] {
            if append(sample.location(in: self), honoringMinimumDistance: true) {
                appended = true
            }
        }
        if append(touch.location(in: self), honoringMinimumDistance: !includingFinalPoint) {
            appended = true
        }
        if appended {
            line.path = path.copy()
        }
    }

    @discardableResult
    private func append(_ point: CGPoint, honoringMinimumDistance: Bool) -> Bool {
        guard let last = points.last else {
            points.append(point)
            path.move(to: point)
            return true
        }
        guard point != last else { return false }
        if honoringMinimumDistance, minimumPointDistance > 0 {
            let dx = point.x - last.x
            let dy = point.y - last.y
            guard dx * dx + dy * dy >= minimumPointDistance * minimumPointDistance else {
                return false
            }
        }
        points.append(point)
        path.addLine(to: point)
        return true
    }

    private func reset() {
        activeTouch = nil
        points.removeAll(keepingCapacity: true)
        path = CGMutablePath()
        line.path = nil
        startDot.isHidden = true
    }
}
#endif
