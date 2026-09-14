import Foundation
import XCTest
@testable import QuotaCore

final class ResetNotificationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func event(_ id: String = "123", banked: Bool = false, observed: Bool = false, author: String = "thsottiaux", scheduled: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["id": id, "reset_type": banked ? "banked" : "regular",
            "announced_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
            "source": observed ? ["type": "observed"] : ["type": "x_post", "author": author, "url": "https://x.com/thsottiaux/status/123"]]
        if scheduled { value["scheduled_for"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1)) }
        return value
    }
    func status(latest: [String: Any]? = nil, pending: [String: Any]? = nil, watch: Bool = false) throws -> ResetStatus {
        let payload: [String: Any] = ["latest_reset": latest as Any? ?? NSNull(), "scheduled_reset": pending as Any? ?? NSNull(),
            "active_watch": watch ? ["chance": "100%", "level": "strong", "text": "imminent"] : NSNull()]
        return try JSONDecoder().decode(ResetStatus.self, from: JSONSerialization.data(withJSONObject: ["data": payload]))
    }
    func testInitialHistoricalResetIsSilent() throws {
        var state = ResetNoticeState()
        XCTAssertEqual(ResetNoticePolicy.notices(status: try status(latest: event()), state: &state, now: now), [])
        XCTAssertTrue(state.initialized)
        XCTAssertEqual(state.delivered, ["reset.confirmed.123"])
    }
    func testInitialExplicitAnnouncementIsUseful() throws {
        var state = ResetNoticeState()
        let notices = ResetNoticePolicy.notices(status: try status(latest: event("122"), pending: event(scheduled: true)), state: &state, now: now)
        XCTAssertEqual(notices.map(\.kind), [.announced])
        XCTAssertEqual(notices.first?.title, "Codex reset announced")
    }
    func testAnnouncementAndExecutionWithSameIDBothNotifyOnce() throws {
        var state = ResetNoticeState(); state.initialized = true
        let planned = try status(pending: event(scheduled: true))
        let advance = ResetNoticePolicy.notices(status: planned, state: &state, now: now)
        ResetNoticePolicy.record(advance[0].identifier, in: &state)
        XCTAssertEqual(ResetNoticePolicy.notices(status: planned, state: &state, now: now), [])
        let executed = try status(latest: event(), pending: event(scheduled: true))
        let confirmation = ResetNoticePolicy.notices(status: executed, state: &state, now: now)
        XCTAssertEqual(confirmation.map(\.kind), [.confirmed])
        ResetNoticePolicy.record(confirmation[0].identifier, in: &state)
        let restored = try JSONDecoder().decode(ResetNoticeState.self, from: JSONEncoder().encode(state))
        state = restored
        XCTAssertEqual(ResetNoticePolicy.notices(status: executed, state: &state, now: now), [])
    }
    func testPassedScheduledTimeIsNotExecution() throws {
        var state = ResetNoticeState(); state.initialized = true
        let notices = ResetNoticePolicy.notices(status: try status(pending: event(scheduled: true)), state: &state, now: now)
        XCTAssertEqual(notices.map(\.kind), [.announced])
    }
    func testWatchAndBankedNeverNotify() throws {
        var state = ResetNoticeState(); state.initialized = true
        XCTAssertEqual(ResetNoticePolicy.notices(status: try status(latest: event(banked: true), pending: event(banked: true), watch: true), state: &state, now: now), [])
    }
    func testOtherAuthorsAndObservedAdvanceDoNotNotify() throws {
        var state = ResetNoticeState(); state.initialized = true
        XCTAssertEqual(ResetNoticePolicy.notices(status: try status(latest: event(author: "someone"), pending: event(observed: true)), state: &state, now: now), [])
    }
    func testObservedExecutionIsLabeledObserved() throws {
        var state = ResetNoticeState(); state.initialized = true
        let notices = ResetNoticePolicy.notices(status: try status(latest: event("observed-1", observed: true)), state: &state, now: now)
        XCTAssertEqual(notices.map(\.kind), [.confirmed]); XCTAssertEqual(notices.first?.observed, true)
        XCTAssertEqual(notices.first?.sourceURL, ResetNoticePolicy.fallbackURL)
    }
    func testUnacceptedDeliveryRetriesWithoutDedupeCommit() throws {
        var state = ResetNoticeState(); state.initialized = true
        let payload = try status(latest: event())
        let first = ResetNoticePolicy.notices(status: payload, state: &state, now: now)
        XCTAssertEqual(first, ResetNoticePolicy.notices(status: payload, state: &state, now: now))
        ResetNoticePolicy.record(first[0].identifier, in: &state)
        XCTAssertTrue(ResetNoticePolicy.notices(status: payload, state: &state, now: now).isEmpty)
    }
    func testInvalidOrFutureOrOldEventIsIgnored() throws {
        for field in ["id": "../payload", "announced_at": "invalid"] {
            var value = event(); value[field.key] = field.value
            var state = ResetNoticeState(); state.initialized = true
            XCTAssertTrue(ResetNoticePolicy.notices(status: try status(latest: value), state: &state, now: now).isEmpty)
        }
        for offset in [1000.0, -604900.0] {
            var value = event(); value["announced_at"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
            var state = ResetNoticeState(); state.initialized = true
            XCTAssertTrue(ResetNoticePolicy.notices(status: try status(latest: value), state: &state, now: now).isEmpty)
        }
    }
    func testSourceURLIsStrictAndRemovesTracking() {
        for value in ["http://x.com/thsottiaux/status/123", "https://x.com.evil/thsottiaux/status/123", "file:///tmp/a", "https://u@x.com/thsottiaux/status/123", "https://x.com/someone/status/123", "https://x.com:443/thsottiaux/status/123"] {
            XCTAssertEqual(ResetNoticePolicy.trustedURL(value), ResetNoticePolicy.fallbackURL)
        }
        XCTAssertEqual(ResetNoticePolicy.trustedURL("https://twitter.com/thsottiaux/status/123?q=a").absoluteString, "https://x.com/thsottiaux/status/123")
    }
    func testBoundedDedupeAnd304CadenceAndRetryAfter() {
        var state = ResetNoticeState()
        for i in 0..<200 { ResetNoticePolicy.record("reset.confirmed.\(i)", in: &state) }
        XCTAssertEqual(state.delivered.count, 128)
        var polling = ResetPollPolicy()
        polling.finish(status: 200, retryAfter: nil, at: now)
        XCTAssertEqual(polling.nextAttempt.timeIntervalSince(now), 300)
        polling.finish(status: 429, retryAfter: 7200, at: now)
        XCTAssertEqual(polling.nextAttempt.timeIntervalSince(now), 7200)
        polling.finish(status: 503, retryAfter: nil, at: now)
        XCTAssertEqual(polling.nextAttempt.timeIntervalSince(now), 600)
        polling.finish(status: 304, retryAfter: nil, at: now)
        XCTAssertEqual(polling.failures, 0); XCTAssertEqual(polling.nextAttempt.timeIntervalSince(now), 300)
    }
}
