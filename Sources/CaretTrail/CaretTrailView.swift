import AppKit
import QuartzCore

/// Draws a caret-shaped quad whose four corners ride independent springs. Corners facing the
/// direction of travel are stiff and land on the real caret almost at once, never passing it;
/// trailing corners are soft and carry momentum between moves, so the caret smears toward its
/// destination and then fades out on top of the real caret. The smear reads like a comet: the
/// further the tail is left behind, the narrower and more transparent it gets.
final class CaretTrailView: NSView {
    private enum Phase { case idle, moving, fading }

    // Corner order: top-left, top-right, bottom-right, bottom-left.
    private static let cornerSigns: [CGVector] = [
        CGVector(dx: -1, dy: 1), CGVector(dx: 1, dy: 1), CGVector(dx: 1, dy: -1), CGVector(dx: -1, dy: -1),
    ]
    private static func corners(of rect: CGRect) -> [CGPoint] {
        cornerSigns.map { CGPoint(x: $0.dx > 0 ? rect.maxX : rect.minX, y: $0.dy > 0 ? rect.maxY : rect.minY) }
    }

    // Spring rates are divided by the trail duration. Trailing corners are looser and a touch bouncy.
    private static let leadRate: CGFloat = 25
    private static let trailRate: CGFloat = 4.5
    private static let leadDamping: CGFloat = 1
    private static let trailDamping: CGFloat = 0.8
    // Steps shorter than the caret is tall (typing) get a tail this much looser, otherwise the
    // smear is over before it can be seen.
    private static let shortStepLooseness: CGFloat = 0.3
    // Stretch, in points, at which the tail is half as wide as the caret.
    private static let taperLength: CGFloat = 25
    private static let minTailWidth: CGFloat = 0.45
    // Stretch, in points, at which the end of the tail is half transparent.
    private static let fadeLength: CGFloat = 8
    private static let minTailAlpha: CGFloat = 0.05
    private static let glowMargin: CGFloat = 16

    private let host = CALayer()          // carries the overall opacity and the tail fade mask
    private let shape = CAShapeLayer()
    private let fade = CAGradientLayer()  // alpha ramp from the head of the trail to its tail
    private var displayLink: CADisplayLink?

    private var phase = Phase.idle
    private var springs = CaretTrailView.corners(of: .zero).map { Spring(position: $0) }
    private var target = CaretTrailView.corners(of: .zero)
    private var weights: [CGFloat] = [0, 0, 0, 0] // 1 = fully leading, 0 = fully trailing
    private var tailLooseness: CGFloat = 1
    private var settings = TrailSettings(duration: 0.12, color: .controlAccentColor)
    private var lastTick: CFTimeInterval = 0
    private var fadeStart: CFTimeInterval = 0
    private let fadeDuration: CFTimeInterval = 0.14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Bold: solid body, a thin bright edge, and a soft glow of the same hue around it.
        shape.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        shape.lineWidth = 0.75
        shape.lineJoin = .round
        shape.shadowOpacity = 1
        shape.shadowRadius = 5
        shape.shadowOffset = .zero
        host.opacity = 0
        host.mask = fade
        host.addSublayer(shape)
        layer?.addSublayer(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        host.frame = bounds
        shape.frame = bounds
    }

    func animate(from: CGRect, to: CGRect, settings: TrailSettings) {
        let now = CACurrentMediaTime()
        self.settings = settings
        if phase != .moving {
            springs = Self.corners(of: from).map { Spring(position: $0) }
            lastTick = now
        }
        target = Self.corners(of: to)
        let step = hypot(to.midX - from.midX, to.midY - from.midY)
        tailLooseness = min(max(step / max(to.height, 1), Self.shortStepLooseness), 1)

        let center = CGPoint(
            x: springs.map(\.position.x).reduce(0, +) / 4,
            y: springs.map(\.position.y).reduce(0, +) / 4
        )
        let dir = CGVector(dx: to.midX - center.x, dy: to.midY - center.y)
        let len = hypot(dir.dx, dir.dy)
        // Signs instead of real offsets so a thin caret still has clear leading corners.
        weights = Self.cornerSigns.map { sign -> CGFloat in
            guard len > 0 else { return 0.5 }
            // ±1 for the corners of an axis-aligned move, so a horizontal move has a pure head and tail.
            let leadingness: CGFloat = (sign.dx * dir.dx + sign.dy * dir.dy) / len
            return min(max((leadingness + 1) / 2, 0), 1)
        }

        phase = .moving
        withoutActions {
            // The accent colour is dynamic: resolve it now so system changes show up on the next move.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = settings.color
                shape.fillColor = (color.blended(withFraction: 0.15, of: .white) ?? color).cgColor
                shape.shadowColor = color.cgColor
            }
            host.opacity = 1
        }
        render()
        startLink()
    }

    func hide() {
        phase = .idle
        withoutActions { host.opacity = 0 }
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
            let dt = min(now - lastTick, 1.0 / 30)
            lastTick = now
            let leadOmega = Self.leadRate / settings.duration
            let trailOmega = Self.trailRate * tailLooseness / settings.duration
            var settled = true
            for i in springs.indices {
                springs[i].step(
                    toward: target[i],
                    omega: trailOmega + (leadOmega - trailOmega) * weights[i],
                    damping: Self.trailDamping + (Self.leadDamping - Self.trailDamping) * weights[i],
                    overshoots: weights[i] <= 0.5, // the head of the trail must never pass the real caret
                    dt: dt
                )
                let distance = hypot(springs[i].position.x - target[i].x, springs[i].position.y - target[i].y)
                let speed = hypot(springs[i].velocity.dx, springs[i].velocity.dy)
                if distance > 0.5 || speed > 10 { settled = false }
            }
            render()
            if settled {
                phase = .fading
                fadeStart = now
            }
        case .fading:
            let f = min(1, (now - fadeStart) / fadeDuration)
            withoutActions { host.opacity = Float(1 - f) }
            if f >= 1 {
                phase = .idle
                stopLink()
            }
        case .idle:
            stopLink()
        }
    }

    /// Weighted centre of the head (`leading`) or tail corners.
    private func centroid(of points: [CGPoint], leading: Bool) -> CGPoint {
        var sum = CGPoint.zero
        var total: CGFloat = 0
        for (point, weight) in zip(points, weights) {
            let w = leading ? weight : 1 - weight
            sum.x += point.x * w
            sum.y += point.y * w
            total += w
        }
        return total > 0 ? CGPoint(x: sum.x / total, y: sum.y / total) : sum
    }

    /// Squeezes the tail corners toward the tail's centre and fades them out, harder the further
    /// the tail has been left behind. At rest nothing is squeezed or faded, so the shape still
    /// merges into the caret.
    private func render() {
        let points = springs.map(\.position)
        let head = centroid(of: points, leading: true)
        let tail = centroid(of: points, leading: false)
        let restHead = centroid(of: target, leading: true)
        let restTail = centroid(of: target, leading: false)
        let stretch = max(0, hypot(head.x - tail.x, head.y - tail.y) - hypot(restHead.x - restTail.x, restHead.y - restTail.y))
        let tailWidth = max(Self.minTailWidth, 1 / (1 + stretch / Self.taperLength))
        let tailAlpha = max(Self.minTailAlpha, 1 / (1 + stretch / Self.fadeLength))

        let path = CGMutablePath()
        path.addLines(between: zip(points, weights).map { point, weight in
            let scale = 1 - (1 - weight) * (1 - tailWidth)
            return CGPoint(x: tail.x + (point.x - tail.x) * scale, y: tail.y + (point.y - tail.y) * scale)
        })
        path.closeSubpath()

        let box = path.boundingBoxOfPath.insetBy(dx: -Self.glowMargin, dy: -Self.glowMargin)
        func unit(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
        }
        withoutActions {
            shape.path = path
            fade.frame = box
            fade.startPoint = unit(head)
            fade.endPoint = unit(tail)
            fade.colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: tailAlpha)]
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
