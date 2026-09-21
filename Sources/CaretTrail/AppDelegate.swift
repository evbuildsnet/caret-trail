import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let overlay = OverlayWindow()
    private let tracker = CaretTracker()
    private var window: NSWindow!
    private var trustTimer: Timer?

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

        overlay.orderFrontRegardless()

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        checkTrust()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkTrust()
        }
    }

    private func checkTrust() {
        let trusted = AXIsProcessTrusted()
        if state.trusted != trusted { state.trusted = trusted }
        if trusted, !tracker.isRunning { tracker.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }
}
