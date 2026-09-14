import Foundation
import XCTest
@testable import QuotaCore

final class LivePayloadDecoderTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func data(_ text: String) -> Data { Data(text.utf8) }

    func testCodexAcceptsWeeklyPrimary() throws {
        let raw = data(#"{"account_id":"A","rate_limit":{"primary_window":{"used_percent":21,"limit_window_seconds":604800,"reset_at":1800400000},"secondary_window":null}}"#)
        let value = try LivePayloadDecoder.codex(raw, expectedAccount: "A", now: now)
        XCTAssertEqual(value.remainingText, "79%")
        XCTAssertEqual(value.resetsAt!.timeIntervalSince(value.windowStart!), 604800)
    }

    func testCodexSelectsWeeklySecondaryNotSession() throws {
        let raw = data(#"{"account_id":"A","rate_limit":{"primary_window":{"used_percent":81,"limit_window_seconds":18000,"reset_at":1800010000},"secondary_window":{"used_percent":38,"limit_window_seconds":604800,"reset_at":1800400000}}}"#)
        XCTAssertEqual(try LivePayloadDecoder.codex(raw, expectedAccount: "A", now: now).remainingText, "62%")
    }

    func testCodexRejectsAnotherAccount() {
        let raw = data(#"{"account_id":"B","rate_limit":{"primary_window":{"used_percent":21,"limit_window_seconds":604800,"reset_at":1800400000}}}"#)
        XCTAssertThrowsError(try LivePayloadDecoder.codex(raw, expectedAccount: "A", now: now)) {
            XCTAssertEqual($0 as? UsagePayloadError, .unexpectedAccount)
        }
    }

    func testCodexDoesNotSubstituteReserveOrSparkWindow() {
        let raw = data(#"{"account_id":"A","rate_limit":{"primary_window":{"used_percent":9,"limit_window_seconds":18000,"reset_at":1800010000}},"additional_rate_limits":[{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,"reset_at":1800400000}}}]}"#)
        XCTAssertThrowsError(try LivePayloadDecoder.codex(raw, expectedAccount: "A", now: now))
    }

    func testFableUsesItsScopedPercentageNotAllModels() throws {
        let raw = data(#"{"seven_day":{"utilization":17,"resets_at":"2027-01-20T15:00:00Z"},"limits":[{"kind":"weekly_all","percent":17},{"kind":"weekly_scoped","percent":58,"resets_at":"2027-01-20T15:00:00.123456+00:00","scope":{"model":{"display_name":"Fable","id":null}},"is_active":false}]}"#)
        let value = try LivePayloadDecoder.fable(raw, verifiedAccount: "C", now: now)
        XCTAssertEqual(value.remainingText, "42%")
        XCTAssertEqual(value.accountID, "C")
        XCTAssertEqual(value.resetsAt!.timeIntervalSince(value.windowStart!), 604800)
    }

    func testFlatFableFieldIsSupported() throws {
        let raw = data(#"{"seven_day_fable":{"utilization":30,"resets_at":"2027-01-20T15:00:00Z"}}"#)
        XCTAssertEqual(try LivePayloadDecoder.fable(raw, verifiedAccount: "C", now: now).remainingText, "70%")
    }

    func testMissingFableDoesNotBecomeSharedWeeklyOrZero() {
        let raw = data(#"{"seven_day":{"utilization":17},"limits":[{"kind":"weekly_scoped","percent":3,"scope":{"model":{"display_name":"Sonnet"}}}]}"#)
        XCTAssertThrowsError(try LivePayloadDecoder.fable(raw, verifiedAccount: "C", now: now)) {
            XCTAssertEqual($0 as? UsagePayloadError, .missingWeeklyWindow)
        }
    }

    func testNullFableAndBadTimestampStayUnknown() {
        for raw in [
            #"{"seven_day_fable":null}"#,
            #"{"seven_day_fable":{"utilization":10,"resets_at":"bad date"}}"#
        ] { XCTAssertThrowsError(try LivePayloadDecoder.fable(data(raw), verifiedAccount: "C", now: now)) }
    }

    func testInvalidPercentageTypeIsRejected() {
        let raw = data(#"{"account_id":"A","rate_limit":{"primary_window":{"used_percent":true,"limit_window_seconds":604800,"reset_at":1800400000}}}"#)
        XCTAssertThrowsError(try LivePayloadDecoder.codex(raw, expectedAccount: "A", now: now))
    }
}
