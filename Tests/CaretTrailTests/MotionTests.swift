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

    func testSpringResponseIsIndependentOfFramePartitioning() {
        // A skipped frame must land at the same position and velocity as multiple small frames,
        // including during a reversal where the spring starts with momentum away from its target.
        for damping in [0.8, 1.0] {
            let initial = Spring(position: CGPoint(x: 80, y: -30), velocity: CGVector(dx: 400, dy: -150))
            let target = CGPoint(x: -20, y: 50)
            var singleFrame = initial
            var fourFrames = initial
            singleFrame.step(toward: target, omega: 50, damping: damping, overshoots: true, dt: 1.0 / 30)
            for _ in 0..<4 {
                fourFrames.step(toward: target, omega: 50, damping: damping, overshoots: true, dt: 1.0 / 120)
            }
            XCTAssertEqual(singleFrame.position.x, fourFrames.position.x, accuracy: 1e-9)
            XCTAssertEqual(singleFrame.position.y, fourFrames.position.y, accuracy: 1e-9)
            XCTAssertEqual(singleFrame.velocity.dx, fourFrames.velocity.dx, accuracy: 1e-9)
            XCTAssertEqual(singleFrame.velocity.dy, fourFrames.velocity.dy, accuracy: 1e-9)
        }
    }
}
