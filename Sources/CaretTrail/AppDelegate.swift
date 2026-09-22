import AppKit
import ApplicationServices
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let overlay = OverlayWindow()
    private let tracker = CaretTracker()
    private var window: NSWindow!
    private var trustTimer: Timer?
    private var enabledObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Caret Trail"
        window.contentView = NSHostingView(rootView: SettingsView(state: state))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        tracker.onCaretMoved = { [weak self] from, to in
            guard let self, self.state.enabled else { return }
            self.overlay.animate(from: from, to: to, settings: self.state.trail)
        }
        tracker.onCaretLost = { [weak self] in self?.overlay.hide() }
        tracker.onStatus = { [weak self] text in self?.state.status = text }

        // Disabling stops the accessibility traffic entirely, not just the drawing.
        enabledObserver = state.$enabled.sink { [weak self] enabled in
            guard let self else { return }
            self.checkTrust(enabled: enabled)
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        checkTrust()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkTrust()
        }
    }

    private func checkTrust(enabled: Bool? = nil) {
        let trusted = AXIsProcessTrusted()
        if state.trusted != trusted { state.trusted = trusted }
        if trusted, enabled ?? state.enabled {
            if !tracker.isRunning { tracker.start() }
        } else {
            tracker.stop()
            overlay.hide()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trustTimer?.invalidate()
        enabledObserver?.cancel()
        tracker.stop()
        overlay.hide()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }
}
