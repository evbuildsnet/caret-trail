import AppKit

struct TrailSettings {
    var duration: Double
    var color: NSColor
    /// A caret-sized bar glides to the new place instead of the comet smear.
    var glide = false
    /// The glide follows Word's curve, cubic-bezier(0, 0, 0, 1): fast start, long settle. Word uses 100 ms.
    var wordCurve = false
    /// The soft halo around the trail.
    var glow = true
    /// Prototype, glide mode only: cover the real caret with this colour while ours glides.
    var maskColor: NSColor? = nil
    /// The real caret's colour, for our gliding one. Defaults to the trail colour.
    var caretColor: NSColor? = nil
}

/// Settings persist in UserDefaults; `trusted` and `status` are live state.
final class AppState: ObservableObject {
    private static let defaults = UserDefaults.standard

    @Published var enabled = defaults.object(forKey: "enabled") as? Bool ?? true {
        didSet { Self.defaults.set(enabled, forKey: "enabled") }
    }
    @Published var duration = defaults.object(forKey: "duration") as? Double ?? 0.12 {
        didSet { Self.defaults.set(duration, forKey: "duration") }
    }
    /// The user's pick. nil follows the system accent colour.
    @Published var customColor = defaults.data(forKey: "trailColor")
        .flatMap({ try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: $0) }) {
        didSet {
            let data = customColor.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            Self.defaults.set(data, forKey: "trailColor")
        }
    }
    @Published var glide = defaults.object(forKey: "glide") as? Bool ?? false {
        didSet { Self.defaults.set(glide, forKey: "glide") }
    }
    @Published var wordCurve = defaults.object(forKey: "wordCurve") as? Bool ?? false {
        didSet { Self.defaults.set(wordCurve, forKey: "wordCurve") }
    }
    @Published var glow = defaults.object(forKey: "glow") as? Bool ?? true {
        didSet { Self.defaults.set(glow, forKey: "glow") }
    }
    @Published var ignoreClicks = defaults.object(forKey: "ignoreClicks") as? Bool ?? false {
        didSet { Self.defaults.set(ignoreClicks, forKey: "ignoreClicks") }
    }
    @Published var terminalFix = defaults.object(forKey: "terminalFix") as? Bool ?? true {
        didSet { Self.defaults.set(terminalFix, forKey: "terminalFix") }
    }
    @Published var maskCaret = defaults.object(forKey: "maskCaret") as? Bool ?? false {
        didSet { Self.defaults.set(maskCaret, forKey: "maskCaret") }
    }
    @Published var noLineBreaks = defaults.object(forKey: "noLineBreaks") as? Bool ?? false {
        didSet { Self.defaults.set(noLineBreaks, forKey: "noLineBreaks") }
    }
    /// Where the app shows itself: "dock", "menuBar" or "both".
    @Published var placement = defaults.string(forKey: "placement") ?? "dock" {
        didSet { Self.defaults.set(placement, forKey: "placement") }
    }
    /// Bundle identifiers of the apps to leave alone.
    @Published var ignoredApps = defaults.stringArray(forKey: "ignoredApps") ?? [] {
        didSet { Self.defaults.set(ignoredApps, forKey: "ignoredApps") }
    }
    /// Window state, not saved: the ignored apps sheet and its selected row.
    @Published var showingIgnoredApps = false
    @Published var ignoredSelection: String?
    /// Mirrors the system's login item; the app delegate registers and unregisters it.
    @Published var openAtLogin = false
    @Published var screenAccess = false
    @Published var trusted = false
    @Published var status = "Waiting for the caret to move…"

    var trail: TrailSettings {
        TrailSettings(duration: duration, color: customColor ?? .controlAccentColor,
                      glide: glide, wordCurve: wordCurve, glow: glow)
    }
}

/// Enabled with CARET_TRAIL_DEBUG=1; prints to stdout.
let debugEnabled = ProcessInfo.processInfo.environment["CARET_TRAIL_DEBUG"] == "1"
func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    print(String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + message())
    fflush(stdout)
}
