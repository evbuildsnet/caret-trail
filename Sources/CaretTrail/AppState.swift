import AppKit

struct TrailSettings {
    var duration: Double
    var color: NSColor
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
    @Published var trusted = false
    @Published var status = "Waiting for the caret to move…"

    var trail: TrailSettings {
        TrailSettings(duration: duration, color: customColor ?? .controlAccentColor)
    }
}

/// Enabled with CARET_TRAIL_DEBUG=1; prints to stdout.
let debugEnabled = ProcessInfo.processInfo.environment["CARET_TRAIL_DEBUG"] == "1"
func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    print(message())
    fflush(stdout)
}
