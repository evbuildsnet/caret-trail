import XCTest
@testable import CaretTrail

final class MotionTests: XCTestCase {
    func testSpringKeepsMomentumWhenRetargeted() {
        var spring = Spring(position: .zero)
        for _ in 0..<3 { spring.step(toward: CGPoint(x: 100, y: 0), omega: 50, damping: 0.8, overshoots: true, dt: 1.0 / 120) }
        let speed = spring.velocity.dx
        XCTAssertGreaterThan(speed, 0)

        spring.step(toward: CGPoint(x: 200, y: 0), omega: 50, damping: 0.8, overshoots: true, dt: 1.0 / 120)
        XCTAssertGreaterThan(spring.velocity.dx, speed, "a new target accelerates from the current velocity, not from rest")
    }

    func testSpringSettlesOnTargetAtAnyFrameRate() {
        for fps in [30.0, 60, 120] {
            for damping in [0.8, 1.0] {
                var spring = Spring(position: .zero)
                for _ in 0..<Int(fps) { spring.step(toward: CGPoint(x: 100, y: -40), omega: 80, damping: damping, overshoots: true, dt: 1 / fps) }
                XCTAssertEqual(spring.position.x, 100, accuracy: 0.01)
                XCTAssertEqual(spring.position.y, -40, accuracy: 0.01)
            }
        }
    }

    func testHeadNeverPassesTheCaretEvenWithMomentum() {
        var spring = Spring(position: .zero, velocity: CGVector(dx: 8000, dy: 0))
        for _ in 0..<60 {
            spring.step(toward: CGPoint(x: 8, y: 0), omega: 200, damping: 1, overshoots: false, dt: 1.0 / 60)
            XCTAssertLessThanOrEqual(spring.position.x, 8)
        }
        XCTAssertEqual(spring.position.x, 8, accuracy: 0.01)
    }
}
