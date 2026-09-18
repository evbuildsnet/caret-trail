import AppKit
import ApplicationServices

/// Follows the frontmost app through the Accessibility API and reports where its text caret is,
/// in Cocoa screen coordinates (origin bottom-left of the primary display).
final class CaretTracker {
    var onCaretMoved: ((_ from: CGRect, _ to: CGRect) -> Void)?
    var onCaretLost: (() -> Void)?
    var onStatus: ((String) -> Void)?

    private(set) var isRunning = false

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var appName = ""
    private var focusedElement: AXUIElement?
    private var lastRect: CGRect?
    private var lastRange: CFRange?
    private var pollTimer: Timer?

    private let notifications = [
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXSelectedTextChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXLayoutChangedNotification,
    ]

    func start() {
        guard !isRunning else { return }
        isRunning = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        if let app = NSWorkspace.shared.frontmostApplication { attach(to: app) }
        // Catches scrolling and apps that don't post selection notifications.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refresh(focusChanged: false)
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(to: app)
    }

    // MARK: - Observing

    private func attach(to app: NSRunningApplication) {
        detach()
        let pid = app.processIdentifier
        guard pid != getpid() else {
            onStatus?("Caret Trail is frontmost. Switch to another app.")
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else {
            onStatus?("Could not observe \(app.localizedName ?? "app")")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.05)
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
        refresh(focusChanged: true)
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        focusedElement = nil
        lastRect = nil
        lastRange = nil
    }

    fileprivate func handle(notification: String) {
        debugLog("tracker: notification \(notification)")
        let focusChanged = notification == kAXFocusedUIElementChangedNotification
            || notification == kAXFocusedWindowChangedNotification
        refresh(focusChanged: focusChanged)
    }

    // MARK: - Caret lookup

    /// Re-reads the caret. A changed selection range means the caret moved by itself: animate.
    /// Same range but a different rect means the content scrolled or the window moved: just remember it.
    private func refresh(focusChanged: Bool) {
        guard let appElement else { return }
        guard let element = focusedUIElement(of: appElement) else {
            lose("No focused element in \(appName)")
            return
        }
        let elementChanged = focusedElement.map { !CFEqual($0, element) } ?? true
        focusedElement = element

        guard let range = selectedRange(of: element) else {
            lose("\(appName): focused element has no text selection")
            return
        }
        guard range.length == 0 else {
            lose("\(appName): text selected, caret hidden")
            return
        }
        guard let rect = caretRect(of: element, location: range.location) else {
            lose("\(appName): no caret bounds for this element")
            return
        }

        let moved = lastRange.map { $0.location != range.location } ?? false
        debugLog("tracker: focusChanged=\(focusChanged) elementChanged=\(elementChanged) moved=\(moved) rect=\(rect) last=\(String(describing: lastRect))")
        if !elementChanged, !focusChanged, moved, let from = lastRect, from != rect {
            onCaretMoved?(from, rect)
        }
        lastRect = rect
        lastRange = range
        onStatus?("\(appName): caret at \(Int(rect.minX)), \(Int(rect.minY)) h=\(Int(rect.height))")
    }

    private func lose(_ reason: String) {
        debugLog("tracker: lost: \(reason)")
        lastRect = nil
        lastRange = nil
        onCaretLost?()
        onStatus?(reason)
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

private let axCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<CaretTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handle(notification: notification as String)
}
