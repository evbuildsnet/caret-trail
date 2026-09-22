import XCTest
@testable import CaretTrail

@MainActor
final class CaretRefreshCoalescerTests: XCTestCase {
    func testNotificationBurstPerformsOneLookupAndPreservesFocusChange() {
        let refreshed = expectation(description: "one lookup for the notification burst")
        refreshed.assertForOverFulfill = true
        let coalescer = CaretRefreshCoalescer { request in
            XCTAssertTrue(request.focusChanged, "a field switch must still suppress cross-field animation")
            XCTAssertTrue(request.verifyFocus)
            refreshed.fulfill()
        }
        for index in 0..<100 {
            coalescer.request(focusChanged: index == 40, verifyFocus: index == 40)
        }
        wait(for: [refreshed], timeout: 1)
    }

    func testSelectionOnlyBurstCanReuseFocusedElement() {
        let refreshed = expectation(description: "selection refresh")
        let coalescer = CaretRefreshCoalescer { request in
            XCTAssertFalse(request.focusChanged)
            XCTAssertFalse(request.verifyFocus, "selection events from a known field need no focus IPC")
            refreshed.fulfill()
        }
        coalescer.request(focusChanged: false, verifyFocus: false)
        coalescer.request(focusChanged: false, verifyFocus: false)
        wait(for: [refreshed], timeout: 1)
    }

    func testDetachDiscardsOldFocusChangeWithoutConsumingNewAppRequest() {
        let refreshed = expectation(description: "only the new app is refreshed")
        refreshed.assertForOverFulfill = true
        let coalescer = CaretRefreshCoalescer { request in
            XCTAssertFalse(request.focusChanged)
            refreshed.fulfill()
        }
        coalescer.request(focusChanged: true, verifyFocus: true)
        coalescer.takePending()
        coalescer.request(focusChanged: false, verifyFocus: true)
        wait(for: [refreshed], timeout: 1)
    }

    func testPollingConsumesPendingFocusChangeAndCancelsDuplicateLookup() {
        let refreshed = expectation(description: "no duplicate notification lookup")
        refreshed.isInverted = true
        let coalescer = CaretRefreshCoalescer { _ in refreshed.fulfill() }
        coalescer.request(focusChanged: true, verifyFocus: true)
        XCTAssertEqual(coalescer.takePending()?.focusChanged, true)
        XCTAssertNil(coalescer.takePending())
        wait(for: [refreshed], timeout: 0.05)
    }
}
