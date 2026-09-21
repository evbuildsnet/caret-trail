import AppKit

/// Transparent, click-through window that spans the screen the caret is on.
final class OverlayWindow: NSWindow {
    private let trail = CaretTrailView()
    private var currentScreen: NSScreen?

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
        if let screen = NSScreen.main { move(to: screen) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Rects are in Cocoa screen coordinates.
    func animate(from: CGRect, to: CGRect, settings: TrailSettings) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(to.origin) }) ?? NSScreen.main else { return }
        let screenChanged = currentScreen.map { $0.frame != screen.frame } ?? true
        if screenChanged { move(to: screen) }
        guard !screenChanged, screen.frame.contains(from.origin) else {
            debugLog("overlay: screen changed, skipping animation")
            trail.hide()
            return
        }
        debugLog("overlay: animate \(from.origin) -> \(to.origin) on screen \(screen.frame)")
        let origin = screen.frame.origin
        trail.animate(
            from: from.offsetBy(dx: -origin.x, dy: -origin.y),
            to: to.offsetBy(dx: -origin.x, dy: -origin.y),
            settings: settings
        )
    }

    func hide() { trail.hide() }

    private func move(to screen: NSScreen) {
        currentScreen = screen
        setFrame(screen.frame, display: false)
    }
}
