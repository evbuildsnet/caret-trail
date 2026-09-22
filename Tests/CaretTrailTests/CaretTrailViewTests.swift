import AppKit
import QuartzCore
import XCTest
@testable import CaretTrail

final class CaretTrailViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: CaretTrailView!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = CaretTrailView(frame: CGRect(origin: .zero, size: window.frame.size))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        view.hide()
        window.contentView = nil // Invalidates the prepared display link.
        window.close()
        view = nil
        window = nil
        super.tearDown()
    }

    func testFirstTypingFrameAlreadyMovesBeforeDisplayLinkTicks() throws {
        let from = CGRect(x: 140, y: 130, width: 2, height: 20)
        let to = from.offsetBy(dx: 8, dy: 0)
        view.animate(from: from, to: to, settings: TrailSettings(duration: 0.12, color: .systemBlue))

        let extent = try XCTUnwrap(view.extent)
        XCTAssertGreaterThan(extent.maxX, from.maxX, "the first submitted frame must visibly move after idle")
        XCTAssertLessThanOrEqual(extent.maxX, to.maxX, "the leading edge must not pass the actual caret")
        XCTAssertLessThan(extent.minX, to.minX, "the first frame must retain a trailing edge")
    }

    func testRenderUsesLocalCoordinatesAndNativeBackingScale() throws {
        let from = CGRect(x: 140, y: 130, width: 2, height: 20)
        view.animate(from: from, to: from.offsetBy(dx: 8, dy: 0), settings: TrailSettings(duration: 0.12, color: .systemBlue))

        let host = try XCTUnwrap(view.layer?.sublayers?.first)
        let shape = try XCTUnwrap(host.sublayers?.first as? CAShapeLayer)
        let path = try XCTUnwrap(shape.path)
        XCTAssertLessThan(path.boundingBoxOfPath.maxX, 100, "screen coordinates must be mapped into the compact window")
        XCTAssertEqual(shape.contentsScale, window.backingScaleFactor)
        XCTAssertEqual(shape.shadowPath, shape.path, "the glow must use the known silhouette")
    }

    func testLongJumpRemainsInsideExpandedWindowAndBecomesIdleOnce() throws {
        let overlay = OverlayWindow()
        defer {
            overlay.hide()
            overlay.contentView = nil
            overlay.close()
        }
        let view = try XCTUnwrap(overlay.contentView as? CaretTrailView)
        let from = CGRect(x: 140, y: 130, width: 2, height: 20)
        let to = from.offsetBy(dx: 3000, dy: 0)
        var idleCount = 0
        let orderOutWhenIdle = view.onIdle
        view.onIdle = {
            idleCount += 1
            orderOutWhenIdle?()
        }
        overlay.animate(from: from, to: to, settings: TrailSettings(duration: 0.12, color: .systemBlue))
        let initialFrame = overlay.frame
        XCTAssertTrue(overlay.isVisible)
        let start = CACurrentMediaTime()
        let shape = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers?.first as? CAShapeLayer)
        for frame in 1...180 {
            view.advanceFrame(at: start + Double(frame) / 120)
            if let path = shape.path, view.extent != nil {
                let glow = path.boundingBoxOfPath.insetBy(dx: -16, dy: -16)
                XCTAssertTrue(CGRect(origin: .zero, size: overlay.frame.size).contains(glow), "the window must include the trail and glow during overshoot")
            }
        }
        XCTAssertGreaterThan(overlay.frame.width, initialFrame.width, "this jump must exercise spring overshoot beyond initial padding")
        XCTAssertNil(view.extent)
        XCTAssertEqual(idleCount, 1)
        XCTAssertEqual(view.layer?.sublayers?.first?.opacity, 0)
        XCTAssertFalse(overlay.isVisible, "the production idle callback must remove the overlay")
    }
}
