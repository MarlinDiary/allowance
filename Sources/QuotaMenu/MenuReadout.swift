import Foundation
import QuotaCore

struct MenuReadout: Equatable {
    let title: String
    let subtitle: String
    let brand: ProviderBrand
    let remaining: String
    let remainingFraction: Double?
    let usedFraction: Double?
    let remainingLabel: String
    let unavailableText: String?
    let reset: String
    let pace: String

    init(snapshot: UsageSnapshot, now: Date, issue: String? = nil) {
        let isCodex = snapshot.provider == "codex"
        title = isCodex ? "Codex" : "Claude Code"
        brand = isCodex ? .openAI : .claude
        subtitle = "\(isCodex ? "Weekly" : "Fable · Weekly") · \(snapshot.accountLabel)"
        remaining = snapshot.remainingText
        remainingFraction = snapshot.remainingFraction
        usedFraction = snapshot.remainingFraction.map { 1 - $0 }
        // A weekly reading is a cached observation, not a live stream. Short 429s are
        // an internal scheduling concern, not an actionable menu error.
        let rateLimited = issue == "Rate limited"
        let freshnessBudget: TimeInterval = !isCodex || rateLimited ? 900 : 300
        let expiredWindow = snapshot.resetsAt.map { $0 <= now } ?? false
        let tooOld = snapshot.isStale(at: now, maxAge: freshnessBudget) || expiredWindow
        let visibleIssue = rateLimited ? nil : issue
        let outOfDate = snapshot.remainingFraction != nil && (visibleIssue != nil || tooOld)
        remainingLabel = snapshot.remainingFraction == nil ? "" : (outOfDate ? "last known" : "left")
        unavailableText = snapshot.remainingFraction == nil ? (rateLimited ? "Updating" : issue ?? "No usage data") : nil
        reset = snapshot.resetText(at: now)
        pace = rateLimited ? (tooOld ? "Delayed" : snapshot.paceText(at: now))
            : visibleIssue ?? (outOfDate ? "Out of date" : snapshot.paceText(at: now))
    }

    var summary: String {
        if let unavailableText { return "\(title): \(unavailableText). \(subtitle)." }
        let freshness = remainingLabel == "last known" ? "Last known: " : ""
        return "\(title): \(freshness)\(remaining) remaining. \(subtitle). \(reset). \(pace)."
    }

    static func tooltip(snapshots: [UsageSnapshot], now: Date, status: String) -> String {
        snapshots.map { MenuReadout(snapshot: $0, now: now).summary }.joined(separator: "\n") + "\n" + status
    }
}
