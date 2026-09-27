import Foundation

public enum UsagePayloadError: Error, Equatable {
    case invalidResponse, unexpectedAccount, missingWeeklyWindow
}

public enum LivePayloadDecoder {
    private struct CodexEnvelope: Decodable {
        let account_id: String?
        let rate_limit: CodexLimits?
    }
    private struct CodexLimits: Decodable {
        let primary_window: CodexWindow?
        let secondary_window: CodexWindow?
    }
    private struct CodexWindow: Decodable {
        let used_percent: Double?
        let limit_window_seconds: Double?
        let reset_at: Double?
    }
    private struct ClaudeEnvelope: Decodable {
        let limits: [WeeklyLimit]?
        let seven_day: ClaudeWindow?
    }
    private struct ClaudeWindow: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    private struct WeeklyLimit: Decodable {
        let kind: String?
        let percent: Double?
        let resets_at: String?
    }

    public static func codex(_ data: Data, expectedAccount: String, now: Date) throws -> UsageSnapshot {
        let envelope = try JSONDecoder().decode(CodexEnvelope.self, from: data)
        guard envelope.account_id == expectedAccount else { throw UsagePayloadError.unexpectedAccount }
        let windows = [envelope.rate_limit?.primary_window, envelope.rate_limit?.secondary_window].compactMap { $0 }
        guard let window = windows.first(where: { $0.limit_window_seconds == 604800 }),
              let used = window.used_percent, used.isFinite else { throw UsagePayloadError.missingWeeklyWindow }
        let end = window.reset_at.map(Date.init(timeIntervalSince1970:))
        return UsageSnapshot(provider: "codex", title: "Codex", accountID: expectedAccount,
                             accountLabel: "Current Codex account", usedPercent: used,
                             windowStart: end?.addingTimeInterval(-604800), resetsAt: end, observedAt: now)
    }

    // Claude's overall weekly limit across models. Model-scoped weekly limits such as Fable
    // never stand in for it, even when it is missing.
    public static func claude(_ data: Data, verifiedAccount: String, now: Date) throws -> UsageSnapshot {
        let envelope = try JSONDecoder().decode(ClaudeEnvelope.self, from: data)
        let overall = envelope.limits?.first { $0.kind == "weekly_all" }
        let used = overall?.percent ?? envelope.seven_day?.utilization
        let reset = overall?.resets_at ?? envelope.seven_day?.resets_at
        guard let used, used.isFinite else { throw UsagePayloadError.missingWeeklyWindow }
        let end: Date?
        if let reset {
            guard let date = isoDate(reset) else { throw UsagePayloadError.invalidResponse }
            end = date
        } else { end = nil }
        return UsageSnapshot(provider: "claude-fable", title: "Claude", accountID: verifiedAccount,
                             accountLabel: "Current Claude Code account", usedPercent: used,
                             windowStart: end?.addingTimeInterval(-604800), resetsAt: end, observedAt: now)
    }

    private static func isoDate(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value)
    }
}
