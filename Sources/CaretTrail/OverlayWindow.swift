import AppKit

/// Transparent, click-through window that exists only while a trail is on screen and is sized to
/// the trail itself. Between moves nothing of ours sits above other apps, so the window server has
/// no extra full-screen layer to composite and hit-test against.
final class OverlayWindow: NSWindow {
    private let trail = CaretTrailView()
    /// Room around the caret rects for the glow, the stroke, and a little spring overshoot.
    private static let padding: CGFloat = 32

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = trail
        trail.onExtentChanged = { [weak self] extent in
            guard let self else { return }
            let required = extent.insetBy(dx: -Self.padding, dy: -Self.padding).integral
            if !self.frame.contains(required) {
                self.setFrame(self.frame.union(required), display: false)
            }
        }
        trail.onIdle = { [weak self] in
            debugLog("overlay: idle, ordering out")
            self?.orderOut(nil)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Rects are in Cocoa screen coordinates. The window grows to cover both rects plus whatever
    /// the trail currently occupies, so a move that lands mid-animation never gets clipped.
    func animate(from: CGRect, to: CGRect, settings: TrailSettings) {
        var region = from.union(to)
        if let extent = trail.extent { region = region.union(extent) }
        region = region.insetBy(dx: -Self.padding, dy: -Self.padding).integral
        debugLog("overlay: animate \(from.origin) -> \(to.origin) in \(region)")
        if frame != region { setFrame(region, display: false) }
        trail.animate(from: from, to: to, settings: settings)
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        trail.hide()
        orderOut(nil)
    }
}
