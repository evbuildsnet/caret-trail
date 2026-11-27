import AppKit
import QuartzCore

/// Draws a caret-shaped quad whose four corners ride independent springs. Corners facing the
/// direction of travel are stiff and land on the real caret almost at once, never passing it;
/// trailing corners are soft and carry momentum between moves, so the caret smears toward its
/// destination and then fades out on top of the real caret. The smear reads like a comet: the
/// further the tail is left behind, the narrower and more transparent it gets.
///
/// Springs and targets stay in screen coordinates; only `render` maps them into the window,
/// so the window is free to move and resize around the trail mid-animation.
final class CaretTrailView: NSView {
    private enum Phase { case idle, moving, fading }

    /// Fires once the trail has faded out completely.
    var onIdle: (() -> Void)?

    /// Gives the window a chance to accommodate spring overshoot before mapping into local space.
    var onExtentChanged: ((CGRect) -> Void)?

    /// Screen-space box around the trail's current corners while it is on screen.
    var extent: CGRect? {
        guard phase != .idle else { return nil }
        let xs = springs.map(\.position.x)
        let ys = springs.map(\.position.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

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
    private var fadeDuration: CFTimeInterval { settings.glide ? 0.1 : 0.14 }

    /// Glide mode: a caret-sized bar travels from `from` to `to`, like WordCraft's caret.
    private struct Glide { var from: CGRect; var to: CGRect; var start: CFTimeInterval }
    private var glide: Glide?
    /// Covers the real caret at the destination while ours glides (prototype).
    private let maskLayer = CALayer()
    private var maskRect: CGRect?

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
        maskLayer.isHidden = true
        host.addSublayer(maskLayer)
        host.addSublayer(shape)
        layer?.addSublayer(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        withoutActions {
            host.frame = bounds
            shape.frame = bounds
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        if window != nil {
            prepareLink()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 1
        withoutActions {
            host.contentsScale = scale
            shape.contentsScale = scale
            fade.contentsScale = scale
        }
    }

    func animate(from: CGRect, to: CGRect, settings: TrailSettings) {
        if settings.glide {
            animateGlide(from: from, to: to, settings: settings)
            return
        }
        glide = nil
        maskRect = nil
        withoutActions { maskLayer.isHidden = true }
        let now = CACurrentMediaTime()
        self.settings = settings
        let isStarting = phase != .moving
        if isStarting {
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
        if isStarting {
            // Put a visible trail in the first submitted frame. Otherwise a resumed display link
            // spends its first refresh displaying the old caret before any motion can appear.
            let framesPerSecond = max(window?.screen?.maximumFramesPerSecond ?? 60, 30)
            _ = advanceSprings(by: 1 / CGFloat(framesPerSecond))
        }
        withoutActions {
            // The accent colour is dynamic: resolve it now so system changes show up on the next move.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = settings.color
                shape.fillColor = (color.blended(withFraction: 0.15, of: .white) ?? color).cgColor
                shape.shadowColor = color.cgColor
            }
            shape.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
            shape.shadowOpacity = settings.glow ? 1 : 0
            shape.shadowRadius = 5
            // On the shape, not the host: the host's opacity runs the fade-out.
            shape.opacity = Float(settings.opacity)
            host.opacity = 1
        }
        render()
        startLink()
    }

    private func animateGlide(from: CGRect, to: CGRect, settings: TrailSettings) {
        self.settings = settings
        // Another move before arrival: snap to where the bar was heading and glide on from there.
        let start = (phase == .moving ? glide?.to : nil) ?? from
        glide = Glide(from: start, to: to, start: CACurrentMediaTime())
        phase = .moving
        target = Self.corners(of: to)
        springs = Self.corners(of: start).map { Spring(position: $0) }
        weights = [1, 1, 1, 1]
        // The real caret is a little wider than its 2 pt rect once antialiased: cover a margin.
        maskRect = settings.maskColor.map { _ in to.insetBy(dx: -1.5, dy: -1) }
        withoutActions {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                shape.fillColor = (settings.caretColor ?? settings.color).cgColor
                shape.shadowColor = settings.color.cgColor
                maskLayer.backgroundColor = settings.maskColor?.cgColor
            }
            maskLayer.isHidden = maskRect == nil
            shape.strokeColor = nil
            shape.shadowOpacity = settings.glow ? 1 : 0
            shape.shadowRadius = 5 * settings.haloIntensity
            // The mask over the real caret is a sibling layer, so it stays opaque.
            shape.opacity = Float(settings.opacity)
            host.opacity = 1
        }
        render()
        startLink()
    }

    /// Word's glide curve, cubic-bezier(0, 0, 0, 1): with these control points time is u³ and
    /// distance 3u² − 2u³, so distance = 3s^(2/3) − 2s. Otherwise a plain ease-out.
    private static func glideEase(_ s: CGFloat, word: Bool) -> CGFloat {
        let s = min(max(s, 0), 1)
        return word ? 3 * pow(s, 2.0 / 3.0) - 2 * s : 1 - pow(1 - s, 3)
    }

    func hide() {
        phase = .idle
        glide = nil
        maskRect = nil
        withoutActions {
            host.opacity = 0
            maskLayer.isHidden = true
        }
        stopLink()
    }

    // MARK: - Frame loop

    private func prepareLink() {
        if displayLink == nil {
            let link = self.displayLink(target: self, selector: #selector(tick(_:)))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func startLink() {
        prepareLink()
        displayLink?.isPaused = false
    }

    private func stopLink() {
        displayLink?.isPaused = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        advanceFrame(at: CACurrentMediaTime())
    }

    /// Advances the same frame clock for a display callback or an offscreen rendering check.
    func advanceFrame(at now: CFTimeInterval) {
        switch phase {
        case .moving where glide != nil:
            let g = glide!
            let duration = settings.duration
            let s = CGFloat(min(1, (now - g.start) / duration))
            let e = Self.glideEase(s, word: settings.wordCurve)
            let rect = CGRect(
                x: g.from.minX + (g.to.minX - g.from.minX) * e,
                y: g.from.minY + (g.to.minY - g.from.minY) * e,
                width: g.from.width + (g.to.width - g.from.width) * e,
                height: g.from.height + (g.to.height - g.from.height) * e
            )
            springs = Self.corners(of: rect).map { Spring(position: $0) }
            render()
            if s >= 1 {
                glide = nil
                if maskRect != nil {
                    // Hand over to the real caret at once: no fade, it is right underneath.
                    maskRect = nil
                    phase = .idle
                    withoutActions {
                        maskLayer.isHidden = true
                        host.opacity = 0
                    }
                    stopLink()
                    onIdle?()
                } else {
                    phase = .fading
                    fadeStart = now
                }
            }
        case .moving:
            let dt = min(now - lastTick, 1.0 / 30)
            lastTick = now
            let settled = advanceSprings(by: dt)
            render()
            if settled {
                phase = .fading
                fadeStart = now
            }
        case .fading:
            let f = min(1, (now - fadeStart) / fadeDuration)
            // Ease out of the settled caret and into transparency with no abrupt opacity slope.
            let eased = f * f * (3 - 2 * f)
            withoutActions { host.opacity = Float(1 - eased) }
            if f >= 1 {
                phase = .idle
                stopLink()
                onIdle?()
            }
        case .idle:
            stopLink()
        }
    }

    private func advanceSprings(by dt: CGFloat) -> Bool {
        let leadOmega = Self.leadRate / settings.duration
        let trailOmega = Self.trailRate * tailLooseness / settings.duration / max(settings.tailLength, 0.1)
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
        return settled
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
        if let extent { onExtentChanged?(extent) }
        let origin = window?.frame.origin ?? .zero
        func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
        let points = springs.map { local($0.position) }
        let head = centroid(of: points, leading: true)
        let tail = centroid(of: points, leading: false)
        let restHead = local(centroid(of: target, leading: true))
        let restTail = local(centroid(of: target, leading: false))
        let stretch = max(0, hypot(head.x - tail.x, head.y - tail.y) - hypot(restHead.x - restTail.x, restHead.y - restTail.y))
        let tailWidth = max(Self.minTailWidth, 1 / (1 + stretch / (Self.taperLength * settings.tailLength)))
        let tailAlpha = settings.glide ? 1 : max(Self.minTailAlpha, 1 / (1 + stretch / (Self.fadeLength * settings.tailLength)))

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
            // Supplying the silhouette avoids Core Animation discovering it from offscreen alpha.
            // A 2 pt bar blurs into almost nothing: the glide's halo comes from a wider silhouette.
            shape.shadowPath = settings.glide ? Self.glowSilhouette(around: path.boundingBoxOfPath, intensity: settings.haloIntensity) : path
            fade.frame = settings.glide ? bounds : box
            if let maskRect {
                maskLayer.frame = CGRect(origin: local(maskRect.origin), size: maskRect.size)
            }
            fade.startPoint = unit(head)
            fade.endPoint = unit(tail)
            fade.colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: tailAlpha)]
        }
    }

    /// The halo grows with its intensity; at 3 it still fits the overlay window's 32 pt padding.
    static func glowSilhouette(around box: CGRect, intensity: CGFloat = 1) -> CGPath {
        CGPath(roundedRect: box.insetBy(dx: -3 * intensity, dy: -intensity),
               cornerWidth: 3 * intensity, cornerHeight: 3 * intensity, transform: nil)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
