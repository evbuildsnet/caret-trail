import AppKit
import QuartzCore
import SwiftUI

/// A small text field inside the settings window to try the effect without leaving the app.
/// Caret Trail never follows its own process through the Accessibility API, so this field reports
/// its caret directly, in the same screen coordinates the tracker uses.
///
/// With the glide option on, the field also shows what the glide is meant to look like: its own
/// caret is hidden and replaced by one that glides and fades its blink like WordCraft's. Only this
/// field can do that, since it is our own window.
struct CaretTestField: NSViewRepresentable {
    @ObservedObject var state: AppState
    var onCaretMoved: (_ from: CGRect, _ to: CGRect) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCaretMoved: onCaretMoved) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 56))
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let size = scroll.contentSize
        let textView = GlideTextView(frame: NSRect(origin: .zero, size: size))
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onCaretMoved = onCaretMoved
        guard let textView = nsView.documentView as? GlideTextView else { return }
        textView.trail = state.trail
        textView.snapOnClick = state.ignoreClicks
        textView.snapOnLineBreak = state.noLineBreaks
        textView.glideOn = state.glide
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onCaretMoved: (CGRect, CGRect) -> Void
        private var last: CGRect?

        init(onCaretMoved: @escaping (CGRect, CGRect) -> Void) { self.onCaretMoved = onCaretMoved }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? GlideTextView else { return }
            if textView.glideOn {
                last = nil
                textView.moveCaret(animated: true)
                return
            }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { last = nil; return }
            var rect = textView.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: nil)
            guard rect.height > 0 else { return }
            rect.size.width = 2
            if let last, last != rect { onCaretMoved(last, rect) }
            last = rect
        }
    }
}

/// A text view whose caret glides to its new place and fades its blink, the way WordCraft's does:
/// 100 ms on Word's curve, cubic-bezier(0, 0, 0, 1), on 530 ms and off 530 ms with 100 ms fades.
final class GlideTextView: NSTextView {
    var glideOn = false {
        didSet { if glideOn != oldValue { applyMode() } }
    }
    var trail = TrailSettings(duration: 0.12, color: .controlAccentColor)
    var snapOnClick = false
    var snapOnLineBreak = false

    private let caret = CALayer()
    private var clickedAt: CFTimeInterval = 0
    private var placed = false

    private static let blinkHalf: CFTimeInterval = 0.53
    private static let blinkFade: CFTimeInterval = 0.1

    private func applyMode() {
        insertionPointColor = glideOn ? .clear : .textColor
        hideNativeCaret()
        placed = false
        if glideOn {
            moveCaret(animated: false)
        } else {
            caret.removeAllAnimations()
            caret.isHidden = true
        }
        needsDisplay = true
    }

    /// Since macOS 14 the caret is a separate indicator view rather than drawn by the text view.
    private func hideNativeCaret() {
        for case let indicator as NSTextInsertionIndicator in subviews {
            indicator.displayMode = glideOn ? .hidden : .automatic
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if !glideOn { super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
    }

    /// The trail colour picker's panel sends its colour to the first responder: when that is this
    /// field, AppKit would paint the test text in the trail colour. Keep the text in its own colour.
    override func changeColor(_ sender: Any?) {}

    override func mouseDown(with event: NSEvent) {
        clickedAt = CACurrentMediaTime()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        // A text view taking focus pushes its own text colour (white in dark mode) into the shared
        // colour panel, and the trail colour well, still attached to the panel, takes it: the trail
        // turned white. Closing the panel first detaches the well.
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible {
            NSColorPanel.shared.close()
        }
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.moveCaret(animated: false) } }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            caret.isHidden = true
            placed = false
        }
        return resigned
    }

    /// The caret's rect in this view's (flipped) coordinates.
    private func caretRect() -> NSRect {
        let location = selectedRange().location
        let screen = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        if let window, screen.height > 0 {
            let local = convert(window.convertFromScreen(screen), from: nil)
            return NSRect(x: local.minX, y: local.minY, width: 2, height: local.height)
        }
        // Empty text: no glyph to measure, so stand at the start of the first line.
        let font = self.font ?? .systemFont(ofSize: 15)
        let padding = textContainer?.lineFragmentPadding ?? 5
        return NSRect(x: textContainerOrigin.x + padding, y: textContainerOrigin.y,
                      width: 2, height: ceil(font.ascender - font.descender + font.leading))
    }

    func moveCaret(animated: Bool) {
        guard glideOn else { return }
        hideNativeCaret()
        guard window?.firstResponder === self, selectedRange().length == 0 else {
            caret.isHidden = true
            placed = false
            return
        }
        if caret.superlayer == nil {
            wantsLayer = true
            caret.anchorPoint = .zero
            caret.zPosition = 10
            layer?.addSublayer(caret)
        }
        let rect = caretRect()
        let previous = caret.position // the model value: where the caret was heading
        let byClick = CACurrentMediaTime() - clickedAt < 0.3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            caret.backgroundColor = NSColor.textColor.cgColor
            caret.shadowColor = trail.color.cgColor
        }
        // This caret stays once it lands, as the real one would: opacity only lightens its halo.
        caret.shadowOpacity = trail.glow ? Float(trail.opacity) : 0
        caret.shadowRadius = 5 * trail.haloIntensity
        caret.shadowOffset = .zero
        caret.bounds = CGRect(origin: .zero, size: rect.size)
        caret.shadowPath = CaretTrailView.glowSilhouette(around: caret.bounds, intensity: trail.haloIntensity)
        caret.position = rect.origin
        caret.isHidden = false
        CATransaction.commit()

        // This view is flipped: down to a following line and back to the left is a wrap or Return.
        let lineBreak = rect.minY >= previous.y + rect.height - 1 && rect.minX < previous.x
        if animated, placed, !(snapOnClick && byClick), !(snapOnLineBreak && lineBreak), previous != rect.origin {
            // Replacing a glide under way restarts it from where it was heading, as WordCraft does.
            let glide = CABasicAnimation(keyPath: "position")
            glide.fromValue = NSValue(point: previous)
            glide.toValue = NSValue(point: rect.origin)
            glide.duration = trail.duration
            glide.timingFunction = trail.wordCurve
                ? CAMediaTimingFunction(controlPoints: 0, 0, 0, 1)
                : CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1) // ease-out cubic
            caret.add(glide, forKey: "glide")
        } else {
            caret.removeAnimation(forKey: "glide")
        }
        placed = true
        restartBlink()
    }

    /// Lit at once (fading in from however visible it was), steady while it moves, then a soft blink.
    private func restartBlink() {
        let current = caret.presentation()?.opacity ?? 1
        caret.removeAnimation(forKey: "blink")
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = current
        fadeIn.toValue = 1
        fadeIn.duration = Self.blinkFade
        caret.add(fadeIn, forKey: "fadeIn")

        let period = 2 * Self.blinkHalf
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0, 0, 1, 1]
        blink.keyTimes = [0, Self.blinkFade / period, Self.blinkHalf / period,
                          (Self.blinkHalf + Self.blinkFade) / period, 1].map { NSNumber(value: $0) }
        blink.duration = period
        blink.repeatCount = .infinity
        blink.beginTime = caret.convertTime(CACurrentMediaTime(), from: nil) + Self.blinkHalf
        caret.add(blink, forKey: "blink")
    }
}
