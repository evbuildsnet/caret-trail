import CoreGraphics

/// Damped spring in 2D. Velocity survives retargeting, which is what gives the trail inertia.
/// Stepped with the closed-form solution, so it is stable at any frame rate.
struct Spring {
    var position: CGPoint
    var velocity = CGVector.zero

    /// `damping` is the damping ratio, at most 1. With `overshoots` off the spring stops dead on the
    /// target instead of swinging past it.
    mutating func step(toward target: CGPoint, omega: CGFloat, damping: CGFloat, overshoots: Bool, dt: CGFloat) {
        func advance(_ x: CGFloat, _ v: CGFloat) -> (x: CGFloat, v: CGFloat) {
            let next: (x: CGFloat, v: CGFloat)
            if damping >= 1 {
                let decay = exp(-omega * dt)
                let b = v + omega * x
                next = (decay * (x + b * dt), decay * (v - omega * b * dt))
            } else {
                let decay = exp(-damping * omega * dt)
                let omegaD = omega * (1 - damping * damping).squareRoot()
                let c = cos(omegaD * dt)
                let s = sin(omegaD * dt)
                let b = (v + damping * omega * x) / omegaD
                next = (decay * (x * c + b * s), decay * (v * c - (damping * omega * b + omegaD * x) * s))
            }
            return !overshoots && next.x * x <= 0 ? (0, 0) : next
        }
        let x = advance(position.x - target.x, velocity.dx)
        let y = advance(position.y - target.y, velocity.dy)
        position = CGPoint(x: target.x + x.x, y: target.y + y.x)
        velocity = CGVector(dx: x.v, dy: y.v)
    }
}
