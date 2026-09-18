import AppKit
import QuartzCore

/// Draws a caret-shaped quad whose four corners move independently: corners facing the
/// direction of travel race ahead, trailing corners lag, so the caret smears toward its
/// destination and then fades out on top of the real caret.
final class CaretTrailView: NSView {
    private struct Quad {
        var points: [CGPoint] // top-left, top-right, bottom-right, bottom-left
        init(rect: CGRect) {
            points = [
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.minY),
            ]
        }
        var center: CGPoint {
            CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
        }
    }

    private enum Phase { case idle, moving, fading }

    private let shape = CAShapeLayer()
    private var displayLink: CADisplayLink?

    private var phase = Phase.idle
    private var start = Quad(rect: .zero)
    private var current = Quad(rect: .zero)
    private var target = Quad(rect: .zero)
    private var leadingness: [CGFloat] = [0, 0, 0, 0]
    private var phaseStart: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0.12
    private let fadeDuration: CFTimeInterval = 0.14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
        shape.opacity = 0
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        shape.frame = bounds
    }

    func animate(from: CGRect, to: CGRect, duration: CFTimeInterval) {
        start = phase == .idle ? Quad(rect: from) : current
        current = start
        target = Quad(rect: to)
        self.duration = duration

        let c = start.center
        let dir = CGVector(dx: target.center.x - c.x, dy: target.center.y - c.y)
        let len = hypot(dir.dx, dir.dy)
        // Corner offsets normalised to (±1, ±1) so a thin caret still has clear leading corners.
        leadingness = start.points.map { p in
            guard len > 0 else { return 0 }
            let ox: CGFloat = p.x >= c.x ? 1 : -1
            let oy: CGFloat = p.y >= c.y ? 1 : -1
            return (ox * dir.dx + oy * dir.dy) / (len * sqrt(2))
        }

        phase = .moving
        phaseStart = CACurrentMediaTime()
        setOpacity(1)
        render()
        startLink()
    }

    func hide() {
        phase = .idle
        setOpacity(0)
        stopLink()
    }

    // MARK: - Frame loop

    private func startLink() {
        if displayLink == nil {
            let link = self.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    private func stopLink() {
        displayLink?.isPaused = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        switch phase {
        case .moving:
            let t = min(1, (now - phaseStart) / duration)
            for i in 0..<4 {
                let p = progress(corner: i, t: t)
                current.points[i] = CGPoint(
                    x: start.points[i].x + (target.points[i].x - start.points[i].x) * p,
                    y: start.points[i].y + (target.points[i].y - start.points[i].y) * p
                )
            }
            render()
            if t >= 1 {
                phase = .fading
                phaseStart = now
            }
        case .fading:
            let f = min(1, (now - phaseStart) / fadeDuration)
            setOpacity(Float(1 - f))
            if f >= 1 {
                phase = .idle
                stopLink()
            }
        case .idle:
            stopLink()
        }
    }

    private func progress(corner: Int, t: CFTimeInterval) -> CGFloat {
        let t = CGFloat(t)
        let lead = 1 - pow(1 - t, 4)          // ease-out quart: leading corners jump ahead
        let trail = t * t * (3 - 2 * t)        // smoothstep: trailing corners catch up later
        let weight = (leadingness[corner] + 1) / 2
        return trail + (lead - trail) * weight
    }

    private func render() {
        let path = CGMutablePath()
        path.addLines(between: current.points)
        path.closeSubpath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
    }

    private func setOpacity(_ value: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.opacity = value
        CATransaction.commit()
    }
}
