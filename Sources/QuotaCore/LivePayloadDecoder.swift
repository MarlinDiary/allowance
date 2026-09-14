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
        let limits: [ScopedLimit]?
        let seven_day_fable: ClaudeWindow?
    }
    private struct ClaudeWindow: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    private struct ScopedLimit: Decodable {
        let kind: String?
        let percent: Double?
        let resets_at: String?
        let scope: Scope?
    }
    private struct Scope: Decodable { let model: Model? }
    private struct Model: Decodable { let display_name: String?; let id: String? }

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

    public static func fable(_ data: Data, verifiedAccount: String, now: Date) throws -> UsageSnapshot {
        let envelope = try JSONDecoder().decode(ClaudeEnvelope.self, from: data)
        let matching = envelope.limits?.first { limit in
            guard limit.kind == "weekly_scoped" else { return false }
            let name = limit.scope?.model?.display_name?.lowercased() ?? ""
            let id = limit.scope?.model?.id?.lowercased() ?? ""
            return name == "fable" || name.hasPrefix("fable ") || id.hasPrefix("claude-fable")
        }
        let used = matching?.percent ?? envelope.seven_day_fable?.utilization
        let reset = matching?.resets_at ?? envelope.seven_day_fable?.resets_at
        guard let used, used.isFinite else { throw UsagePayloadError.missingWeeklyWindow }
        let end: Date?
        if let reset {
            guard let date = isoDate(reset) else { throw UsagePayloadError.invalidResponse }
            end = date
        } else { end = nil }
        return UsageSnapshot(provider: "claude-fable", title: "Fable", accountID: verifiedAccount,
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
