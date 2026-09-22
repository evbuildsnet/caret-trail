import Foundation

/// Collapses an accessibility notification burst into one lookup on the next main-loop turn.
/// Focus changes survive coalescing so changing text fields never creates a trail between them.
final class CaretRefreshCoalescer {
    struct Request {
        var focusChanged: Bool
        var verifyFocus: Bool
    }

    private var pending: Request?
    private var generation = 0
    private let refresh: (Request) -> Void

    init(refresh: @escaping (Request) -> Void) {
        self.refresh = refresh
    }

    func request(focusChanged: Bool, verifyFocus: Bool) {
        if var pending {
            pending.focusChanged = pending.focusChanged || focusChanged
            pending.verifyFocus = pending.verifyFocus || verifyFocus
            self.pending = pending
            return
        }
        pending = Request(focusChanged: focusChanged, verifyFocus: verifyFocus)
        let scheduledGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == scheduledGeneration,
                  let request = self.takePending() else { return }
            self.refresh(request)
        }
    }

    /// Polling can consume a queued lookup; detaching can discard it. Stale queued blocks cannot
    /// consume notifications belonging to a newly attached app or a restarted tracker.
    @discardableResult
    func takePending() -> Request? {
        let request = pending
        pending = nil
        generation &+= 1
        return request
    }
}
