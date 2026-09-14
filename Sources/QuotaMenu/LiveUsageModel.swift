import Combine
import Foundation
import QuotaCore

@MainActor
final class LiveUsageModel: ObservableObject {
    @Published private(set) var snapshots = DemoScenario.disconnected.snapshots(at: Date())
    @Published private(set) var issues: [String: String] = [
        "codex": "Checking login", "claude-fable": "Checking login"
    ]
    @Published private(set) var isRefreshing = false
    private let reader: any CredentialReading
    private let client: any QuotaFetching
    private let policy: RefreshPolicy
    private let clock: () -> Date
    private var selectedIdentities: [QuotaProvider: String] = [:]
    private var generations: [QuotaProvider: Int] = [:]
    private var inFlight = Set<QuotaProvider>()
    private var observedTokens: [QuotaProvider: String] = [:]

    init(reader: any CredentialReading = SystemCredentialReader(),
         client: any QuotaFetching = LiveUsageTransport(), startAutomatically: Bool = true,
         stateStore: (any RefreshStateStoring)? = nil, clock: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.client = client
        self.clock = clock
        self.policy = RefreshPolicy(store: stateStore ?? DefaultsRefreshStateStore())
        if startAutomatically { Task { await refresh() } }
    }

    var statusText: String {
        for provider in QuotaProvider.allCases {
            if let issue = issues[provider.rawValue] { return "\(provider.shortName): \(issue)" }
        }
        return "Live usage"
    }

    func refreshIfNeeded() { Task { await refresh() } }

    func refresh(allowClaudeInteraction: Bool = false) async {
        async let codex: Void = refreshProvider(.codex)
        async let fable: Void = refreshProvider(.fable, allowInteraction: allowClaudeInteraction)
        _ = await (codex, fable)
    }

    // Audits are local reads. Every HTTP trigger shares the same per-provider gate.
    func auditCredentials() async {
        for provider in QuotaProvider.allCases {
            do {
                let credential = try await reader.read(provider, allowInteraction: false)
                if select(credential) { Task { await self.refreshProvider(provider) } }
            } catch let error as LiveReadError { invalidate(provider, error: error) }
            catch { invalidate(provider, error: .notSignedIn) }
        }
    }

    @discardableResult
    private func select(_ credential: LiveCredential) -> Bool {
        let provider = credential.provider
        let accountChanged = selectedIdentities[provider] != credential.identity
        let tokenChanged = observedTokens[provider] != credential.tokenFingerprint
        guard accountChanged || tokenChanged else { return false }
        if accountChanged {
            clear(provider)
            if let saved = policy.restore(provider, credential: credential, at: clock()) {
                snapshots[provider.index] = saved
                issues[provider.rawValue] = nil
            }
        }
        policy.credentialsChanged(provider, accountChanged: accountChanged && selectedIdentities[provider] != nil)
        selectedIdentities[provider] = credential.identity
        observedTokens[provider] = credential.tokenFingerprint
        return true
    }

    private func clear(_ provider: QuotaProvider) {
        generations[provider, default: 0] += 1
        // Don't free a still-running request: account changes must not stack HTTP calls.
        snapshots[provider.index] = DemoScenario.disconnected.snapshots(at: clock())[provider.index]
        issues[provider.rawValue] = "Refreshing"
    }

    private func invalidate(_ provider: QuotaProvider, error: LiveReadError) {
        if selectedIdentities[provider] == nil, snapshots[provider.index].remainingFraction == nil,
           issues[provider.rawValue] == error.message { return }
        clear(provider)
        selectedIdentities[provider] = nil
        observedTokens[provider] = nil
        issues[provider.rawValue] = error.message
    }

    func refreshProvider(_ provider: QuotaProvider, allowInteraction: Bool = false) async {
        let credential: LiveCredential
        do { credential = try await reader.read(provider, allowInteraction: allowInteraction) }
        catch let error as LiveReadError { invalidate(provider, error: error); return }
        catch { invalidate(provider, error: .notSignedIn); return }
        select(credential)
        guard !inFlight.contains(provider) else { return }
        if let local = await client.cached(provider, credential: credential, at: clock()),
           (try? await reader.read(provider, allowInteraction: false)) == credential,
           !inFlight.contains(provider), selectedIdentities[provider] == credential.identity,
           observedTokens[provider] == credential.tokenFingerprint {
            // A passive read is allowed during cooldown. It retains Claude's own capture
            // time and never cancels backoff or replaces a newer network observation.
            if snapshots[provider.index].remainingFraction == nil || local.observedAt > snapshots[provider.index].observedAt {
                snapshots[provider.index] = local
                policy.capture(local, credential: credential)
            }
            if clock().timeIntervalSince(local.observedAt) < RefreshPolicy.interval(provider) {
                if policy.state(provider)?.reason == .rateLimit { issues[provider.rawValue] = "Rate limited" }
                else { issues[provider.rawValue] = nil }
                return
            }
        }
        // Awaiting an actor/cache read can allow another trigger to start a request.
        guard !inFlight.contains(provider), selectedIdentities[provider] == credential.identity,
              observedTokens[provider] == credential.tokenFingerprint else { return }
        guard policy.mayAttempt(provider, at: clock()) else {
            if policy.state(provider)?.reason == .rateLimit { issues[provider.rawValue] = "Rate limited" }
            return
        }
        let generation = generations[provider, default: 0] + 1
        generations[provider] = generation
        inFlight.insert(provider)
        isRefreshing = true
        policy.started(provider, at: clock())
        if snapshots[provider.index].remainingFraction == nil { issues[provider.rawValue] = "Refreshing" }
        var recheck = false
        defer {
            inFlight.remove(provider)
            isRefreshing = !inFlight.isEmpty
            if recheck { Task { await self.refreshProvider(provider) } }
        }
        do {
            let snapshot = try await client.fetch(provider, credential: credential)
            let latest = try await reader.read(provider, allowInteraction: false)
            guard generations[provider] == generation, latest == credential else {
                select(latest)
                recheck = true
                return
            }
            snapshots[provider.index] = snapshot
            policy.capture(snapshot, credential: credential)
            issues[provider.rawValue] = nil
            policy.succeeded(provider, at: clock())
        } catch {
            let issue = error as? LiveReadError ?? .network
            // Even a late 429 for the previous account still imposes a provider cooldown.
            if case .rateLimited = issue { policy.failed(provider, error: issue, at: clock()) }
            guard generations[provider] == generation else { recheck = true; return }
            if case .rateLimited = issue {} else { policy.failed(provider, error: issue, at: clock()) }
            issues[provider.rawValue] = issue.message
            switch issue {
            case .notSignedIn, .loginExpired, .accountChanged:
                invalidate(provider, error: issue)
            default: break
            }
            // Keep the original measurement time through transient failures.
        }
    }

    func tooltip(at now: Date) -> String {
        snapshots.map { snapshot in
            let readout = MenuReadout(snapshot: snapshot, now: now, issue: issues[snapshot.provider])
            let detail: String
            if let issue = issues[snapshot.provider] {
                detail = snapshot.remainingFraction == nil ? issue : "Last known usage. \(issue)."
            } else { detail = "Updated \(max(0, Int(now.timeIntervalSince(snapshot.observedAt))))s ago." }
            return readout.summary + " " + detail
        }.joined(separator: "\n")
    }

    func evidence(at now: Date) -> [String: Any] {
        ["mode": "live", "status": statusText,
         "refreshSchedule": QuotaProvider.allCases.map { provider in
             let state = policy.state(provider)
             return ["provider": provider.rawValue, "intervalSeconds": RefreshPolicy.interval(provider),
                     "nextAttemptAt": state?.nextAttempt.timeIntervalSince1970 as Any? ?? NSNull(),
                     "reason": state?.reason.rawValue as Any? ?? NSNull(),
                     "consecutiveRateLimits": state?.consecutiveRateLimits ?? 0] as [String: Any]
         },
         "snapshots": snapshots.map { snapshot in
             ["provider": snapshot.provider, "remaining": snapshot.remainingText,
              "usedPercent": snapshot.usedPercent as Any? ?? NSNull(),
              "source": snapshot.source as Any? ?? NSNull(),
              "resetsAt": snapshot.resetsAt?.timeIntervalSince1970 as Any? ?? NSNull(),
              "issue": issues[snapshot.provider] as Any? ?? NSNull(),
              "accountVerified": snapshot.accountID != nil && snapshot.remainingFraction != nil,
              "ageSeconds": max(0, Int(now.timeIntervalSince(snapshot.observedAt)))] as [String: Any]
         }]
    }
}
