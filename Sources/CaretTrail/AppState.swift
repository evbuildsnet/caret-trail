import Foundation

final class AppState: ObservableObject {
    @Published var enabled = true
    @Published var duration: Double = 0.12
    @Published var trusted = false
    @Published var status = "Waiting for the caret to move…"
}

/// Enabled with CARET_TRAIL_DEBUG=1; prints to stdout.
let debugEnabled = ProcessInfo.processInfo.environment["CARET_TRAIL_DEBUG"] == "1"
func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    print(message())
    fflush(stdout)
}
