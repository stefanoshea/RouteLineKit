#if canImport(UIKit)
    import UIKit

    /// Place above a stationary map while drawing. Points are in this view's coordinate space.
    @MainActor
    public final class StrokeDrawingView: UIView {
        public var onBegan: (() -> Void)?
        public var onEnded: (([CGPoint]) -> Void)?
        public var onCancelled: (() -> Void)?

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
            line.lineWidth = 5
            line.lineCap = .round
            line.lineJoin = .round
            line.strokeColor = tintColor.cgColor
            startDot.backgroundColor = tintColor.cgColor
            startDot.bounds.size = CGSize(width: line.lineWidth, height: line.lineWidth)
            startDot.cornerRadius = line.lineWidth / 2
            startDot.isHidden = true
            layer.addSublayer(line)
            layer.addSublayer(startDot)
            line.actions = ["path": NSNull()]
            startDot.actions = ["position": NSNull(), "hidden": NSNull()]
        }

        public override func tintColorDidChange() {
            super.tintColorDidChange()
            line.strokeColor = tintColor.cgColor
            startDot.backgroundColor = tintColor.cgColor
        }

        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard activeTouch == nil, let touch = touches.first else { return }
            activeTouch = touch
            onBegan?()
            let point = touch.location(in: self)
            points = [point]
            path = CGMutablePath()
            path.move(to: point)
            startDot.position = point
            startDot.isHidden = false
        }

        public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activeTouch, touches.contains(touch) else { return }
            appendSamples(touch, event: event)
        }

        public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = activeTouch, touches.contains(touch) else { return }
            appendSamples(touch, event: event)
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

        private func appendSamples(_ touch: UITouch, event: UIEvent?) {
            for sample in event?.coalescedTouches(for: touch) ?? [] {
                append(sample.location(in: self))
            }
            append(touch.location(in: self))
            line.path = path.copy()
        }

        private func append(_ point: CGPoint) {
            guard point != points.last else { return }
            points.append(point)
            path.addLine(to: point)
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
