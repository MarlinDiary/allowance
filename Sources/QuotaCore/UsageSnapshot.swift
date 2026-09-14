import Foundation

public struct UsageSnapshot: Equatable, Codable {
    public let provider: String
    public let title: String
    public let accountID: String?
    public let accountLabel: String
    public let usedPercent: Double?
    public let windowStart: Date?
    public let resetsAt: Date?
    public let source: String?
    public let observedAt: Date

    public init(provider: String, title: String, accountID: String?, accountLabel: String,
                usedPercent: Double?, windowStart: Date?, resetsAt: Date?, observedAt: Date, source: String? = nil) {
        self.provider = provider
        self.title = title
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.usedPercent = usedPercent
        self.windowStart = windowStart
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.source = source
    }

    public func withSource(_ value: String) -> UsageSnapshot {
        UsageSnapshot(provider: provider, title: title, accountID: accountID, accountLabel: accountLabel,
            usedPercent: usedPercent, windowStart: windowStart, resetsAt: resetsAt, observedAt: observedAt, source: value)
    }

    public var remainingFraction: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return 1 - min(100, max(0, usedPercent)) / 100
    }

    public var remainingText: String {
        guard let remainingFraction else { return "—" }
        return "\(Int((remainingFraction * 100).rounded()))%"
    }

    // Percentage-point difference from uniform consumption, not an exhaustion forecast.
    public func paceDelta(at now: Date) -> Double? {
        guard let remainingFraction, let windowStart, let resetsAt,
              resetsAt > windowStart, now >= windowStart, now < resetsAt else { return nil }
        let elapsed = now.timeIntervalSince(windowStart) / resetsAt.timeIntervalSince(windowStart)
        return 1 - remainingFraction - elapsed
    }

    public func paceText(at now: Date) -> String {
        guard let fraction = remainingFraction else { return "Not connected" }
        if fraction == 0 { return "Limit reached" }
        guard let delta = paceDelta(at: now) else { return "Pace unavailable" }
        if delta > 0.05 { return "Fast" }
        if delta < -0.05 { return "Slow" }
        return "Steady"
    }

    public func resetText(at now: Date) -> String {
        guard let resetsAt else { return "No usage data" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Awaiting usage update" }
        let hours = Int(seconds / 3600)
        let days = hours / 24
        if days > 0 { return "Resets in \(days)d\(hours % 24 == 0 ? "" : " \(hours % 24)h")" }
        if hours > 0 { return "Resets in \(hours)h" }
        return "Resets in \(max(1, Int(ceil(seconds / 60))))m"
    }

    public func isStale(at now: Date, maxAge: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(observedAt) > maxAge
    }
}

// A future live adapter must identify the account before publishing its usage.
// Changing account invalidates the old snapshot immediately; token renewal does not.
public struct SnapshotCache {
    public private(set) var accountID: String?
    public private(set) var snapshot: UsageSnapshot?
    public init() {}

    public mutating func selectAccount(_ id: String?) {
        if id != accountID { snapshot = nil }
        accountID = id
    }

    @discardableResult
    public mutating func accept(_ value: UsageSnapshot) -> Bool {
        guard let accountID, value.accountID == accountID else { return false }
        snapshot = value
        return true
    }
}

public enum DemoScenario: String, CaseIterable {
    case everyday, balanced, fast, exhausted, disconnected

    public var label: String {
        switch self {
        case .everyday: return "Everyday usage"
        case .balanced: return "On track"
        case .fast: return "Using faster"
        case .exhausted: return "Limit reached"
        case .disconnected: return "Not connected"
        }
    }

    public func snapshots(at now: Date, alternateAccount: Bool = false) -> [UsageSnapshot] {
        let week: TimeInterval = 7 * 24 * 3600
        let remaining: [TimeInterval] = [3 * 24 * 3600, (3 * 24 + 13) * 3600]
        let used: [Double?]
        switch self {
        case .everyday: used = alternateAccount ? [46, 22] : [32, 64]
        case .balanced: used = remaining.map { (1 - $0 / week) * 100 }
        case .fast: used = [87, 92]
        case .exhausted: used = [100, 100]
        case .disconnected: used = [nil, nil]
        }
        return ["codex", "claude-fable"].enumerated().map { index, provider in
            let connected = self != .disconnected
            let end = now.addingTimeInterval(remaining[index])
            return UsageSnapshot(
                provider: provider, title: index == 0 ? "Codex" : "Fable",
                accountID: connected ? "demo-\(provider)-\(alternateAccount ? "B" : "A")" : nil,
                accountLabel: connected ? "\(alternateAccount ? "Alternate" : "Personal") demo account" : "No account connected",
                usedPercent: used[index], windowStart: connected ? end.addingTimeInterval(-week) : nil,
                resetsAt: connected ? end : nil, observedAt: now
            )
        }
    }
}
