import CoreGraphics

/// Damped spring in 2D. Velocity survives retargeting, which is what gives the trail inertia.
/// Stepped with the closed-form solution, so it is stable at any frame rate.
struct Spring {
    var position: CGPoint
    var velocity = CGVector.zero

    /// `damping` is the damping ratio, at most 1. With `overshoots` off the spring stops dead on the
    /// target instead of swinging past it.
    mutating func step(toward target: CGPoint, omega: CGFloat, damping: CGFloat, overshoots: Bool, dt: CGFloat) {
        // Both axes have the same response. Evaluate the exponential and trigonometry once per
        // spring, then apply the resulting position/velocity coefficients to each axis.
        let decay = exp(-min(damping, 1) * omega * dt)
        let positionResponse: CGFloat
        let velocityResponse: CGFloat
        if damping >= 1 {
            positionResponse = decay
            velocityResponse = decay * dt
        } else {
            let omegaD = omega * (1 - damping * damping).squareRoot()
            positionResponse = decay * cos(omegaD * dt)
            velocityResponse = decay * sin(omegaD * dt) / omegaD
        }
        let dampingRate = min(damping, 1) * omega
        func advance(_ x: CGFloat, _ v: CGFloat) -> (x: CGFloat, v: CGFloat) {
            let next = (
                x: positionResponse * x + velocityResponse * (v + dampingRate * x),
                v: positionResponse * v - velocityResponse * (dampingRate * v + omega * omega * x)
            )
            return !overshoots && next.x * x <= 0 ? (0, 0) : next
        }
        let x = advance(position.x - target.x, velocity.dx)
        let y = advance(position.y - target.y, velocity.dy)
        position = CGPoint(x: target.x + x.x, y: target.y + y.x)
        velocity = CGVector(dx: x.v, dy: y.v)
    }
}
