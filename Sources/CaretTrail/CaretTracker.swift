import AppKit
import ApplicationServices

/// Follows the frontmost app through the Accessibility API and reports where its text caret is,
/// in Cocoa screen coordinates (origin bottom-left of the primary display).
final class CaretTracker {
    var onCaretMoved: ((_ from: CGRect, _ to: CGRect) -> Void)?
    var onCaretLost: (() -> Void)?
    /// Set just before `onCaretMoved`: the caret went forward in the text but left on screen,
    /// i.e. onto a new line. Terminals such as Claude Code scroll the input up as it grows, so
    /// there the new line can even sit at the same height as the old one.
    private(set) var lastMoveStartedNewLine = false
    /// A caret appeared where there was none: a newly focused field or app.
    var onCaretFound: ((CGRect) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Translates status messages (English keys, `%@` placeholders).
    var tr: (String) -> String = { $0 }
    private func tr(_ format: String, _ args: CVarArg...) -> String { String(format: tr(format), arguments: args) }

    private(set) var isRunning = false

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var appName = ""
    private var focusedElement: AXUIElement?
    private var lastRect: CGRect?
    private var lastRange: CFRange?
    private var pollTimer: Timer?
    private var lastStatus: String?
    private lazy var refreshCoalescer = CaretRefreshCoalescer { [weak self] request in
        self?.refresh(focusChanged: request.focusChanged, verifyFocus: request.verifyFocus)
    }

    // Deliberately no layout, move, or resize notifications: web content posts layout changes on
    // every hover-induced style change, and each one used to cost the browser a burst of
    // synchronous accessibility calls. The poll covers scrolling and window moves instead.
    private let notifications = [
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXSelectedTextChangedNotification,
    ]

    /// Poll fast while a caret is being followed, slowly while waiting for one to appear.
    private static let trackingPollInterval: TimeInterval = 0.2
    private static let idlePollInterval: TimeInterval = 1

    /// In terminals, a move is trusted only if the caret is still away from its old place after
    /// this delay. Other apps animate at once: the delay would only make the trail feel late.
    /// Terminal UIs (Claude Code and other Ink apps) park the real cursor on another line for a
    /// moment while they redraw; animating that excursion makes the trail bounce away and back.
    private static let moveConfirmationDelay: TimeInterval = 0.03
    private var pendingMove: (work: DispatchWorkItem, since: CFTimeInterval)?

    /// Terminal UIs such as Claude Code hide the real cursor and draw their own. When they redraw
    /// after a pause they leave the hidden cursor at the start of the next line until the next
    /// key press brings it back, which would draw a trail down and back at every pause. In these
    /// apps a caret at column 0 is ignored, and the trail resumes from the last real position.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]
    private var isTerminal = false
    /// Turns the terminal handling above (column 0 and the confirmation delay) on or off.
    var terminalWorkaround = true
    /// Apps never observed nor queried. Changing the set re-attaches to the front app.
    var ignoredBundleIDs: Set<String> = [] {
        didSet {
            guard isRunning, ignoredBundleIDs != oldValue, let app = NSWorkspace.shared.frontmostApplication else { return }
            attach(to: app)
        }
    }
    private var terminalRules: Bool { terminalWorkaround && isTerminal }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Every accessibility call blocks our main thread until the other app answers. Never wait
        // long for a busy app; a missed frame is better than a frozen overlay.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.05)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        if let app = NSWorkspace.shared.frontmostApplication { attach(to: app) }
        schedulePoll()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detach()
    }

    /// Catches scrolling, window moves, and apps that don't post selection notifications.
    private func schedulePoll() {
        pollTimer?.invalidate()
        guard isRunning else { return }
        let interval = lastRect == nil ? Self.idlePollInterval : Self.trackingPollInterval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.isRunning else { return }
            // A pending focus notification must still suppress animation if a poll arrives first.
            let pending = self.refreshCoalescer.takePending()
            self.refresh(focusChanged: pending?.focusChanged ?? false)
            self.schedulePoll()
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(to: app)
    }

    // MARK: - Observing

    private func attach(to app: NSRunningApplication) {
        detach()
        defer { schedulePoll() }
        let pid = app.processIdentifier
        guard pid != getpid() else {
            publishStatus(tr("Caret Trail is frontmost. Switch to another app."))
            return
        }
        if let id = app.bundleIdentifier, ignoredBundleIDs.contains(id) {
            publishStatus(tr("%@ is ignored", app.localizedName ?? id))
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else {
            publishStatus(tr("Could not observe %@", app.localizedName ?? "app"))
            return
        }
        let element = AXUIElementCreateApplication(pid)
        // Chromium/Electron only build their accessibility tree when asked to.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in notifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        self.observer = observer
        appElement = element
        appName = app.localizedName ?? "pid \(pid)"
        isTerminal = Self.terminalBundleIDs.contains(app.bundleIdentifier ?? "")
        refresh(focusChanged: true)
    }

    private func detach() {
        refreshCoalescer.takePending()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        focusedElement = nil
        clearCaret()
    }

    fileprivate func handle(notification: String, element: AXUIElement) {
        guard isRunning else { return }
        debugLog("tracker: notification \(notification)")
        let focusChanged = notification == kAXFocusedUIElementChangedNotification
            || notification == kAXFocusedWindowChangedNotification
        // Selection events from the cached field need no extra IPC to rediscover that field.
        // App-level events and polling still verify focus, including silent focus changes.
        let isFocusedElement = focusedElement.map { CFEqual($0, element) } ?? false
        refreshCoalescer.request(focusChanged: focusChanged, verifyFocus: focusChanged || !isFocusedElement)
    }

    private func observeFocusedElement(_ element: AXUIElement?) {
        guard let observer, let appElement else { return }
        if let previous = focusedElement, !CFEqual(previous, appElement) {
            AXObserverRemoveNotification(observer, previous, kAXSelectedTextChangedNotification as CFString)
        }
        focusedElement = element
        if let element, !CFEqual(element, appElement) {
            // Some apps post selection changes only on their text field, not the application.
            AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
    }

    // MARK: - Caret lookup

    /// Re-reads the caret. A changed selection range means the caret moved by itself: animate.
    /// Same range but a different rect means scrolling or a window move: hide the old trail and remember it.
    private func refresh(focusChanged: Bool, verifyFocus: Bool = true, confirming: Bool = false) {
        guard let appElement else { return }
        let wasTracking = lastRect != nil
        defer {
            // Do not leave a newly discovered caret waiting on the previous one-second idle timer.
            if wasTracking != (lastRect != nil) { schedulePoll() }
        }
        let element = verifyFocus ? focusedUIElement(of: appElement) : focusedElement
        guard let element else {
            observeFocusedElement(nil)
            lose(tr("No focused element in %@", appName))
            return
        }
        let elementChanged = focusedElement.map { !CFEqual($0, element) } ?? true
        if elementChanged { observeFocusedElement(element) }
        if focusChanged || elementChanged { clearCaret() }

        guard let range = selectedRange(of: element) else {
            lose(tr("%@: focused element has no text selection", appName))
            return
        }
        guard range.length == 0 else {
            lose(tr("%@: text selected, caret hidden", appName))
            return
        }
        guard let rect = caretRect(of: element, location: range.location) else {
            lose(tr("%@: no caret bounds for this element", appName))
            return
        }

        let moved = lastRange.map { $0.location != range.location } ?? false
        debugLog("tracker: focusChanged=\(focusChanged) elementChanged=\(elementChanged) moved=\(moved) confirming=\(confirming) rect=\(rect) last=\(String(describing: lastRect))")
        if moved, terminalRules, range.location > 0,
           string(of: element, range: CFRange(location: range.location - 1, length: 1)) == "\n" {
            debugLog("tracker: terminal cursor at column 0, ignored")
            return
        }
        if moved, !confirming, terminalRules, let from = lastRect, from != rect {
            // Hold the trail back until a second read shows the caret really left.
            if pendingMove == nil { scheduleMoveConfirmation() }
            return
        }
        if !moved, let pending = pendingMove {
            cancelPendingMove()
            debugLog("tracker: transient jump ignored, caret back after \(Int((CACurrentMediaTime() - pending.since) * 1000)) ms")
        } else if confirming, !moved {
            debugLog("tracker: transient jump ignored at confirmation")
        }
        if let from = lastRect, from != rect {
            if moved {
                lastMoveStartedNewLine = (lastRange.map { range.location > $0.location } ?? false) && rect.minX < from.minX - 1
                onCaretMoved?(from, rect)
            } else {
                // A scroll or window move invalidates any trail still fading at the old position.
                onCaretLost?()
            }
        }
        lastRect = rect
        lastRange = range
        if !wasTracking { onCaretFound?(rect) }
        publishStatus(tr("%@: caret at %@", appName, "\(Int(rect.minX)), \(Int(rect.minY)) h=\(Int(rect.height))"))
    }

    private func lose(_ reason: String) {
        debugLog("tracker: lost: \(reason)")
        clearCaret()
        publishStatus(reason)
    }

    private func scheduleMoveConfirmation() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.pendingMove != nil else { return }
            self.pendingMove = nil
            self.refresh(focusChanged: false, confirming: true)
        }
        pendingMove = (work, CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.moveConfirmationDelay, execute: work)
    }

    private func cancelPendingMove() {
        pendingMove?.work.cancel()
        pendingMove = nil
    }

    private func clearCaret() {
        cancelPendingMove()
        let hadCaret = lastRect != nil
        lastRect = nil
        lastRange = nil
        if hadCaret { onCaretLost?() }
    }

    private func publishStatus(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus?(status)
    }

    private func focusedUIElement(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func bounds(of element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    private func string(of element: AXUIElement, range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    /// WebKit and Chromium (Safari, Chrome, Electron) answer bounds-for-range only on static text
    /// nodes, but expose the caret precisely through VoiceOver's text-marker API.
    private func markerCaretBounds(of element: AXUIElement) -> CGRect? {
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &selection) == .success,
              let selection else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, selection, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    /// Returns the caret as a 2pt-wide rect in Cocoa screen coordinates.
    /// Zero-length ranges are unreliable (AppKit reports them a line too high), so the caret is
    /// derived from the glyph after it, then the glyph before it, and only then the empty range.
    private func caretRect(of element: AXUIElement, location: Int) -> CGRect? {
        var x: CGFloat
        var axRect: CGRect
        if let rect = markerCaretBounds(of: element) {
            axRect = rect
            x = rect.minX
        } else if let rect = bounds(of: element, range: CFRange(location: location, length: 1)) {
            axRect = rect
            x = rect.minX
        } else if location > 0, let rect = bounds(of: element, range: CFRange(location: location - 1, length: 1)) {
            let previous = string(of: element, range: CFRange(location: location - 1, length: 1))
            if previous == "\n" || previous == "\r" {
                // Empty last line: one line below the newline, at the left edge of the text.
                let left = bounds(of: element, range: CFRange(location: 0, length: 1))?.minX ?? rect.minX
                axRect = rect.offsetBy(dx: 0, dy: rect.height)
                x = left
            } else {
                axRect = rect
                x = rect.maxX
            }
        } else if let rect = bounds(of: element, range: CFRange(location: location, length: 0)) {
            axRect = rect
            x = rect.minX
        } else {
            return nil
        }
        guard axRect.height < 200 else { return nil } // whole-element rects are not a caret
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let y = primaryHeight - axRect.maxY
        return CGRect(x: x, y: y, width: 2, height: axRect.height)
    }
}

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<CaretTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handle(notification: notification as String, element: element)
}
