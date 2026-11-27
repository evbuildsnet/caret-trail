import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let overlay = OverlayWindow()
    private let tracker = CaretTracker()
    private var window: NSWindow!
    private var trustTimer: Timer?
    private var enabledObserver: AnyCancellable?
    private var optionObservers: [AnyCancellable] = []
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var lastClick: CFTimeInterval = 0
    private let sampler = ScreenSampler()
    /// The real caret's look per app, learned once when the app comes to the front (each capture
    /// lights the Screen Recording indicator). A nil value: probed, no blinking caret found.
    private var shapes: [pid_t: ScreenSampler.Shape?] = [:]
    private var currentCaret: CGRect?
    private var statusItem: NSStatusItem?
    /// A caret move this soon after a mouse click counts as made by the click.
    private static let clickWindow: CFTimeInterval = 0.3

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Caret Trail"
        // The neon background runs under a transparent title bar; the window is always dark.
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = makeMainMenu()
        tracker.tr = { [weak self] english in self?.state.t(english) ?? english }
        window.contentView = NSHostingView(rootView: SettingsView(state: state) { [weak self] from, to in
            self?.showTrail(from: from, to: to)
        })
        // The window takes the height its content needs, with no empty band at the bottom.
        if let content = window.contentView { window.setContentSize(content.fittingSize) }
        window.center()
        state.openAtLogin = SMAppService.mainApp.status == .enabled
        applyPlacement(state.placement)
        // With a menu bar icon to reach the settings, start quietly unless something needs the user.
        if state.placement == "dock" || !AXIsProcessTrusted() {
            showSettings()
        }

        tracker.onCaretMoved = { [weak self] from, to in
            self?.currentCaret = to
            self?.showTrail(from: from, to: to, newLine: self?.tracker.lastMoveStartedNewLine ?? false)
        }
        tracker.onCaretLost = { [weak self] in
            self?.currentCaret = nil
            self?.overlay.hide()
        }
        tracker.onCaretFound = { [weak self] rect in
            self?.currentCaret = rect
            self?.probeIfNeeded(at: rect)
        }
        tracker.onStatus = { [weak self] text in self?.state.status = text }

        // Disabling stops the accessibility traffic entirely, not just the drawing.
        enabledObserver = state.$enabled.sink { [weak self] enabled in
            guard let self else { return }
            self.checkTrust(enabled: enabled)
        }

        optionObservers = [
            state.$terminalFix.sink { [weak self] on in self?.tracker.terminalWorkaround = on },
            // The sink fires before the new value is stored: rebuild the menus on the next turn.
            state.$language.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.relabelMenus() } },
            state.$keepOnTop.sink { [weak self] on in self?.window.level = on ? .floating : .normal },
            state.$ignoredApps.sink { [weak self] ids in
                self?.tracker.ignoredBundleIDs = Set(ids)
                self?.overlay.hide()
            },
            state.$placement.dropFirst().sink { [weak self] placement in self?.applyPlacement(placement) },
            state.$openAtLogin.dropFirst().removeDuplicates().sink { [weak self] on in self?.setOpenAtLogin(on) },
            state.$enabled.sink { [weak self] on in self?.enabledMenuItem?.state = on ? .on : .off },
            // Watches mouse clicks only, never the keyboard, and only while the option is on.
            state.$ignoreClicks.sink { [weak self] on in self?.watchClicks(on) },
            state.$maskCaret.sink { [weak self] on in
                guard let self else { return }
                if on, !ScreenSampler.hasPermission { ScreenSampler.requestPermission() }
                self.state.screenAccess = ScreenSampler.hasPermission
            },
        ]

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

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
        let screen = ScreenSampler.hasPermission
        if state.screenAccess != screen { state.screenAccess = screen }
        if trusted, enabled ?? state.enabled {
            if !tracker.isRunning { tracker.start() }
        } else {
            tracker.stop()
            overlay.hide()
        }
    }

    /// Without a main menu, Cmd+A, Cmd+C, Cmd+V, Cmd+Z and Cmd+Q do nothing in the window.
    private func makeMainMenu() -> NSMenu {
        let t = state.t as (String) -> String
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: t("Quit Caret Trail"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: t("Edit"))
        edit.addItem(withTitle: t("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: t("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: t("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: t("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: t("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: t("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    private func showTrail(from: CGRect, to: CGRect, newLine: Bool = false) {
        guard state.enabled else { return }
        if state.ignoreClicks, CACurrentMediaTime() - lastClick < Self.clickWindow {
            overlay.hide()
            return
        }
        // Down to a following line and back to the left: a line wrap while typing, or Return.
        // In terminals, sending a message (Return in Claude Code) clears the input and the caret
        // jumps back to its start on the same row: a long jump left counts as a line break too.
        let terminalReturn = Self.frontmostIsTerminal && abs(to.minY - from.minY) < 1 && from.minX - to.minX > 8 * to.height
        if state.noLineBreaks, newLine || terminalReturn || (to.maxY <= from.minY + 1 && to.minX < from.minX) {
            overlay.hide()
            return
        }
        // In terminals the caret's shape depends on the program running inside (a block in the
        // shell, an underline in Claude Code), so the glide can't copy it: they keep the comet.
        if state.glide, Self.frontmostIsTerminal {
            var settings = state.trail
            settings.glide = false
            overlay.animate(from: from, to: to, settings: settings)
            return
        }
        guard state.glide, state.maskCaret, state.screenAccess,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            overlay.animate(from: from, to: to, settings: state.trail)
            return
        }
        if let known = shapes[pid], let shape = known {
            animateMasked(from: from, to: to, shape: shape)
        } else {
            // Shape still unknown, or no blinking caret to copy: the comet trail meanwhile.
            var settings = state.trail
            settings.glide = false
            overlay.animate(from: from, to: to, settings: settings)
            probeIfNeeded(at: to)
        }
    }

    /// Learns the front app's caret by watching it blink, once per activation, while it stands still.
    private func probeIfNeeded(at rect: CGRect) {
        guard state.enabled, state.glide, state.maskCaret, state.screenAccess, !sampler.busy, !Self.frontmostIsTerminal,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != getpid(), shapes[pid] == nil else { return }
        let start = CACurrentMediaTime()
        sampler.probe(caret: rect) { [weak self] shape, note in
            guard let self else { return }
            let still = self.currentCaret == rect
            debugLog("mask: probe \(Int((CACurrentMediaTime() - start) * 1000)) ms, \(note)\(still ? "" : ", caret moved meanwhile: discarded")")
            guard still, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.shapes[pid] = .some(shape)
        }
    }

    /// A new capture for each app as it comes to the front: its colours may have changed meanwhile.
    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        shapes.removeValue(forKey: app.processIdentifier)
    }

    /// Glides a copy of the real caret (its shape, place and colour) over a cover hiding the real one.
    private func animateMasked(from: CGRect, to: CGRect, shape: ScreenSampler.Shape) {
        func place(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX + shape.offset.minX, y: r.minY + shape.offset.minY,
                   width: shape.offset.width, height: shape.offset.height)
        }
        var settings = state.trail
        settings.maskColor = shape.background
        settings.caretColor = shape.caret
        overlay.animate(from: place(from), to: place(to), settings: settings)
    }

    private var enabledMenuItem: NSMenuItem?
    private var statusMenu: NSMenu?

    /// Menus are AppKit, not SwiftUI: they are retitled by hand when the language changes.
    private func relabelMenus() {
        NSApp.mainMenu = makeMainMenu()
        guard let menu = statusMenu else { return }
        enabledMenuItem?.title = state.t("Enabled")
        menu.items.first { $0.action == #selector(showSettings) }?.title = state.t("Settings…")
        menu.items.first { $0.action == #selector(NSApplication.terminate(_:)) }?.title = state.t("Quit Caret Trail")
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu, let item = statusItem, let menu = statusMenu else {
            showSettings()
            return
        }
        // Attach the menu only for this click, so a left click keeps opening the settings.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
    private var ignoreMenuItem: NSMenuItem?
    /// The app in front when the menu bar menu opened (opening it doesn't activate Caret Trail).
    private var menuTargetApp: NSRunningApplication?

    @objc private func toggleIgnoreFrontApp() {
        guard let id = menuTargetApp?.bundleIdentifier else { return }
        if state.ignoredApps.contains(id) {
            state.ignoredApps.removeAll { $0 == id }
        } else {
            state.ignoredApps.append(id)
        }
    }

    private static var frontmostIsTerminal: Bool {
        CaretTracker.terminalBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    @objc private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleEnabled() { state.enabled.toggle() }

    /// Dock icon, menu bar icon, or both. Without a Dock icon the app is an accessory: no Dock
    /// tile, no app switcher entry, and the menu bar icon is the way back to the settings.
    private func applyPlacement(_ placement: String) {
        let dock = placement != "menuBar"
        let menuBar = placement != "dock"
        NSApp.setActivationPolicy(dock ? .regular : .accessory)
        if menuBar, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Caret Trail")
            let menu = NSMenu()
            menu.delegate = self
            let ignore = NSMenuItem(title: "Ignore", action: #selector(toggleIgnoreFrontApp), keyEquivalent: "")
            ignore.target = self
            menu.addItem(ignore)
            ignoreMenuItem = ignore
            menu.addItem(.separator())
            let enabled = NSMenuItem(title: state.t("Enabled"), action: #selector(toggleEnabled), keyEquivalent: "")
            enabled.target = self
            enabled.state = state.enabled ? .on : .off
            menu.addItem(enabled)
            enabledMenuItem = enabled
            let settings = NSMenuItem(title: state.t("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)
            menu.addItem(.separator())
            menu.addItem(withTitle: state.t("Quit Caret Trail"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            // Left click opens the settings; right click (or Control-click) shows the menu.
            statusMenu = menu
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        } else if !menuBar, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            enabledMenuItem = nil
        }
        // Switching to accessory hides the window along with the Dock icon: bring it back.
        if window.isVisible || !dock { DispatchQueue.main.async { [weak self] in
            if self?.window.isVisible == true { self?.showSettings() }
        } }
    }

    /// Registers the app as a login item (System Settings › General › Login Items).
    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            state.status = state.t("Open at login failed: %@", error.localizedDescription)
        }
        let actual = SMAppService.mainApp.status == .enabled
        if state.openAtLogin != actual { state.openAtLogin = actual }
    }

    private func watchClicks(_ on: Bool) {
        if on, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                self?.lastClick = CACurrentMediaTime()
            }
            // Clicks in our own window (the test field) never reach a global monitor.
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.lastClick = CACurrentMediaTime()
                return event
            }
        } else if !on {
            for monitor in [clickMonitor, localClickMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
            clickMonitor = nil
            localClickMonitor = nil
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
        showSettings()
        return true
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Names the front app in the menu bar menu: "Ignore Safari" or "Stop Ignoring Safari".
    func menuNeedsUpdate(_ menu: NSMenu) {
        let app = NSWorkspace.shared.frontmostApplication
        let usable = app.map { $0.processIdentifier != getpid() && $0.bundleIdentifier != nil } ?? false
        menuTargetApp = usable ? app : nil
        guard let item = ignoreMenuItem else { return }
        guard usable, let app, let id = app.bundleIdentifier else {
            item.title = state.t("Ignore Front App")
            item.isEnabled = false
            return
        }
        let name = app.localizedName ?? id
        item.title = state.ignoredApps.contains(id) ? state.t("Stop Ignoring %@", name) : state.t("Ignore %@", name)
        item.isEnabled = true
    }
}
