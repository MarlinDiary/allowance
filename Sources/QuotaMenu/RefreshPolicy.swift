import CryptoKit
import Foundation
import QuotaCore

struct ProviderRefreshState: Codable, Equatable {
    enum Reason: String, Codable { case polling, failure, rateLimit }
    var nextAttempt: Date
    var reason: Reason
    var consecutiveRateLimits: Int
}

struct StoredProviderUsage: Codable {
    let ownerDigest: String
    let snapshot: UsageSnapshot
    static func digest(_ credential: LiveCredential) -> String {
        SHA256.hash(data: Data(credential.identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
protocol RefreshStateStoring {
    func load(_ provider: QuotaProvider) -> ProviderRefreshState?
    func save(_ state: ProviderRefreshState?, for provider: QuotaProvider)
    func loadUsage(_ provider: QuotaProvider) -> StoredProviderUsage?
    func saveUsage(_ usage: StoredProviderUsage, for provider: QuotaProvider)
}

@MainActor
final class MemoryRefreshStateStore: RefreshStateStoring {
    private var states: [QuotaProvider: ProviderRefreshState] = [:]
    private var usages: [QuotaProvider: StoredProviderUsage] = [:]
    func load(_ provider: QuotaProvider) -> ProviderRefreshState? { states[provider] }
    func loadUsage(_ provider: QuotaProvider) -> StoredProviderUsage? { usages[provider] }
    func saveUsage(_ usage: StoredProviderUsage, for provider: QuotaProvider) { usages[provider] = usage }
    func save(_ state: ProviderRefreshState?, for provider: QuotaProvider) { states[provider] = state }
}

@MainActor
final class DefaultsRefreshStateStore: RefreshStateStoring {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ provider: QuotaProvider) -> String { "quota.refresh.v1." + provider.rawValue }
    func loadUsage(_ provider: QuotaProvider) -> StoredProviderUsage? {
        guard let data = defaults.data(forKey: "quota.usage.v1." + provider.rawValue), data.count <= 16000 else { return nil }
        return try? JSONDecoder().decode(StoredProviderUsage.self, from: data)
    }
    func saveUsage(_ usage: StoredProviderUsage, for provider: QuotaProvider) {
        if let data = try? JSONEncoder().encode(usage) { defaults.set(data, forKey: "quota.usage.v1." + provider.rawValue) }
    }
    func load(_ provider: QuotaProvider) -> ProviderRefreshState? {
        guard let data = defaults.data(forKey: key(provider)),
              let state = try? JSONDecoder().decode(ProviderRefreshState.self, from: data),
              state.nextAttempt.timeIntervalSince1970.isFinite,
              (0...8).contains(state.consecutiveRateLimits) else { return nil }
        return state
    }
    func save(_ state: ProviderRefreshState?, for provider: QuotaProvider) {
        if let state, let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key(provider)) }
        else { defaults.removeObject(forKey: key(provider)) }
    }
}

@MainActor
final class RefreshPolicy {
    private let store: any RefreshStateStoring
    init(store: any RefreshStateStoring) { self.store = store }
    func restore(_ provider: QuotaProvider, credential: LiveCredential, at now: Date) -> UsageSnapshot? {
        guard let record = store.loadUsage(provider), record.ownerDigest == StoredProviderUsage.digest(credential),
              record.snapshot.provider == provider.rawValue, record.snapshot.accountID != nil,
              record.snapshot.remainingFraction != nil, let end = record.snapshot.resetsAt, end > now,
              record.snapshot.observedAt <= now, now.timeIntervalSince(record.snapshot.observedAt) <= 604800,
              credential.accountHint == nil || credential.accountHint == record.snapshot.accountID else { return nil }
        return record.snapshot
    }
    func capture(_ snapshot: UsageSnapshot, credential: LiveCredential) {
        guard snapshot.accountID != nil, snapshot.remainingFraction != nil else { return }
        store.saveUsage(StoredProviderUsage(ownerDigest: StoredProviderUsage.digest(credential), snapshot: snapshot), for: credential.provider)
    }
    static func interval(_ provider: QuotaProvider) -> TimeInterval { provider == .fable ? 300 : 120 }
    func state(_ provider: QuotaProvider) -> ProviderRefreshState? { store.load(provider) }
    func mayAttempt(_ provider: QuotaProvider, at now: Date) -> Bool {
        (state(provider)?.nextAttempt ?? .distantPast) <= now
    }
    func started(_ provider: QuotaProvider, at now: Date) {
        store.save(ProviderRefreshState(nextAttempt: now.addingTimeInterval(Self.interval(provider)),
            reason: .polling, consecutiveRateLimits: state(provider)?.consecutiveRateLimits ?? 0), for: provider)
    }
    func succeeded(_ provider: QuotaProvider, at now: Date) {
        store.save(ProviderRefreshState(nextAttempt: now.addingTimeInterval(Self.interval(provider)),
            reason: .polling, consecutiveRateLimits: 0), for: provider)
    }
    func failed(_ provider: QuotaProvider, error: LiveReadError, at now: Date) {
        if case .rateLimited(let serverDelay) = error {
            let count = min(8, (state(provider)?.consecutiveRateLimits ?? 0) + 1)
            let backoff = min(1800, 300 * pow(2, Double(count - 1)))
            // A server's longer Retry-After always wins; never cap it at our 30-minute backoff ceiling.
            let validServerDelay = serverDelay.isFinite ? max(60, serverDelay) : 300
            store.save(ProviderRefreshState(nextAttempt: now.addingTimeInterval(max(backoff, validServerDelay)),
                reason: .rateLimit, consecutiveRateLimits: count), for: provider)
        } else {
            store.save(ProviderRefreshState(nextAttempt: now.addingTimeInterval(
                max(Self.interval(provider), error == .loginExpired || error == .accountChanged ? 300 : 120)),
                reason: .failure, consecutiveRateLimits: state(provider)?.consecutiveRateLimits ?? 0), for: provider)
        }
    }
    func credentialsChanged(_ provider: QuotaProvider, accountChanged: Bool) {
        guard let existing = state(provider), existing.reason != .rateLimit else { return }
        // Token rotation doesn't shorten normal polling. A repaired login or genuinely new
        // account can request a fresh reading, but never cancels a provider's 429 cooldown.
        if accountChanged || existing.reason == .failure { store.save(nil, for: provider) }
    }
}
