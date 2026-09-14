import Foundation

/// Public global reset feed; never treats an account's percentage or a forecast as proof.
public struct ResetStatus: Decodable, Equatable {
    public struct Source: Decodable, Equatable {
        public let type: String
        public let author: String?
        public let url: String?
    }
    public struct Reset: Decodable, Equatable {
        public let id: String
        public let resetType: String
        public let announcedAt: String
        public let scheduledFor: String?
        public let source: Source
        enum CodingKeys: String, CodingKey {
            case id, source; case resetType = "reset_type"
            case announcedAt = "announced_at", scheduledFor = "scheduled_for"
        }
    }
    public struct Payload: Decodable, Equatable {
        public let latestReset: Reset?
        public let scheduledReset: Reset?
        enum CodingKeys: String, CodingKey {
            case latestReset = "latest_reset", scheduledReset = "scheduled_reset"
        }
        // active_watch, banked statistics, predictions and tweet text are intentionally ignored.
    }
    public let data: Payload
}

public struct ResetNotice: Equatable {
    public enum Kind: String, Codable { case announced, confirmed }
    public let kind: Kind
    public let resetID: String
    public let scheduledFor: Date?
    public let observed: Bool
    public let sourceURL: URL
    public var identifier: String { "reset.\(kind.rawValue).\(resetID)" }
    public var title: String { kind == .announced ? "Codex reset announced" : "Codex reset confirmed" }
}

public struct ResetNoticeState: Codable, Equatable {
    public var initialized = false
    public var delivered: [String] = []
    public init() {}
}

public enum ResetNoticePolicy {
    public static let fallbackURL = URL(string: "https://codex-resets.com")!

    /// First successful observation baselines the historical execution. A pending
    /// explicit announcement is useful even on first install. Delivery is committed
    /// separately only when the OS accepts the notification request.
    public static func notices(status: ResetStatus, state: inout ResetNoticeState, now: Date) -> [ResetNotice] {
        let latest = valid(status.data.latestReset, now: now, announcement: false)
        if !state.initialized {
            if let latest { record(latest.identifier, in: &state) }
            state.initialized = true
        }
        var result: [ResetNotice] = []
        if let pending = valid(status.data.scheduledReset, now: now, announcement: true),
           pending.resetID != status.data.latestReset?.id,
           !state.delivered.contains("reset.confirmed.\(pending.resetID)"),
           !state.delivered.contains(pending.identifier) { result.append(pending) }
        if let latest, !state.delivered.contains(latest.identifier) { result.append(latest) }
        return result
    }

    public static func record(_ identifier: String, in state: inout ResetNoticeState) {
        if !state.delivered.contains(identifier) { state.delivered.append(identifier) }
        state.delivered = Array(state.delivered.suffix(128))
    }

    private static func valid(_ reset: ResetStatus.Reset?, now: Date, announcement: Bool) -> ResetNotice? {
        guard let reset, reset.resetType == "regular",
              reset.id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              let date = parseDate(reset.announcedAt), date <= now.addingTimeInterval(300) else { return nil }
        // No old announcements/executions resurrected after a long absence or feed replay.
        guard now.timeIntervalSince(date) < 604800 else { return nil }
        let tibo = reset.source.type == "x_post" && reset.source.author == "thsottiaux"
        let observed = reset.source.type == "observed"
        guard announcement ? tibo : (tibo || observed) else { return nil }
        return ResetNotice(kind: announcement ? .announced : .confirmed, resetID: reset.id,
            scheduledFor: reset.scheduledFor.flatMap(parseDate), observed: observed,
            sourceURL: trustedURL(reset.source.url))
    }

    public static func trustedURL(_ raw: String?) -> URL {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.user == nil,
              url.password == nil, url.port == nil,
              ["x.com", "twitter.com"].contains(url.host?.lowercased() ?? ""),
              url.path.range(of: "^/thsottiaux/status/[0-9]+$", options: .regularExpression) != nil else { return fallbackURL }
        return URL(string: "https://x.com" + url.path) ?? fallbackURL
    }

    public static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// Independent public-feed cadence. 304 is success; 429 and failures are quiet.
public struct ResetPollPolicy {
    public private(set) var nextAttempt = Date.distantPast
    public private(set) var failures = 0
    public init() {}
    public mutating func finish(status: Int?, retryAfter: TimeInterval?, at now: Date) {
        if status == 200 || status == 304 { failures = 0; nextAttempt = now.addingTimeInterval(300) }
        else {
            failures = min(failures + 1, 6)
            let delay = min(3600, 300 * pow(2, Double(failures - 1)))
            nextAttempt = now.addingTimeInterval(max(delay, retryAfter ?? 0))
        }
    }
}
