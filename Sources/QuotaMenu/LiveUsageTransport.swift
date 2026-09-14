import CryptoKit
import Foundation
import QuotaCore

protocol QuotaFetching: Sendable {
    func fetch(_ provider: QuotaProvider, credential: LiveCredential) async throws -> UsageSnapshot
    func cached(_ provider: QuotaProvider, credential: LiveCredential, at now: Date) async -> UsageSnapshot?
}
extension QuotaFetching {
    func cached(_ provider: QuotaProvider, credential: LiveCredential, at now: Date) async -> UsageSnapshot? { nil }
}

actor LiveUsageTransport: QuotaFetching {
    private let http: any UsageHTTPClient
    private let cache: any ClaudeUsageCacheReading
    private let webSessions: any ClaudeWebSessionReading
    private var verifiedClaudeProfiles: [String: String] = [:]
    private var verifiedWebProfiles: [String: String] = [:]
    private var preferWeb = false
    init(http: any UsageHTTPClient = NativeUsageHTTPClient(),
         cache: any ClaudeUsageCacheReading = ClaudeLocalUsageCache(),
         webSessions: any ClaudeWebSessionReading = NativeClaudeWebSessions(), preferWeb: Bool = false) {
        self.http = http; self.cache = cache; self.webSessions = webSessions; self.preferWeb = preferWeb
    }
    func cached(_ provider: QuotaProvider, credential: LiveCredential, at now: Date) async -> UsageSnapshot? {
        guard provider == .fable else { return nil }
        return await cache.read(for: credential, at: now)
    }
    func fetch(_ provider: QuotaProvider, credential: LiveCredential) async throws -> UsageSnapshot {
        do {
            if provider == .codex {
                guard let account = credential.accountHint, !credential.accessToken.isEmpty else { throw LiveReadError.notSignedIn }
                let data = try await oauth("https://chatgpt.com/backend-api/wham/usage", credential: credential,
                    headers: ["ChatGPT-Account-Id": account])
                return try LivePayloadDecoder.codex(data, expectedAccount: account, now: Date()).withSource("oauth")
            }
            // A previous 429 may prefer Web on the NEXT scheduled attempt, never
            // immediately in response to 429. The model owns the shared cooldown.
            var webAttempted = false
            if preferWeb {
                webAttempted = true
                do {
                    if let value = try await webIfAvailable(credential) { return value }
                    preferWeb = false
                } catch let error as LiveReadError {
                    // A Web-only challenge must not permanently trap Auto on that path.
                    // OAuth remains eligible here, but a 429 is always terminal for the cycle.
                    guard error == .http(403) || Self.recoverable(error) else { throw error }
                    preferWeb = false
                }
            }
            do {
                guard !credential.accessToken.isEmpty else { throw credential.credentialIssue ?? LiveReadError.notSignedIn }
                let fingerprint = credential.tokenFingerprint
                let verifiedAccount: String
                if let existing = verifiedClaudeProfiles[fingerprint] {
                    if let hint = credential.accountHint, hint != existing { throw LiveReadError.accountChanged }
                    verifiedAccount = existing
                } else {
                    let data = try await oauth("https://api.anthropic.com/api/oauth/profile", credential: credential)
                    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let account = root["account"] as? [String: Any], let id = account["uuid"] as? String,
                          !id.isEmpty else { throw LiveReadError.invalidResponse }
                    if let hint = credential.accountHint, hint != id { throw LiveReadError.accountChanged }
                    verifiedClaudeProfiles = [fingerprint: id]; verifiedAccount = id
                }
                let data = try await oauth("https://api.anthropic.com/api/oauth/usage", credential: credential)
                return try LivePayloadDecoder.fable(data, verifiedAccount: verifiedAccount, now: Date()).withSource("oauth")
            } catch let error as LiveReadError {
                if case .rateLimited = error { preferWeb = true; throw error }
                guard Self.recoverable(error) else { throw error }
                if !webAttempted, let value = try await webIfAvailable(credential) { preferWeb = true; return value }
                throw error
            } catch let error as UsagePayloadError {
                if !webAttempted, error != .unexpectedAccount, let value = try await webIfAvailable(credential) { preferWeb = true; return value }
                throw error
            }
        } catch let error as UsagePayloadError {
            switch error {
            case .unexpectedAccount: throw LiveReadError.accountChanged
            case .missingWeeklyWindow: throw provider == .fable ? LiveReadError.missingFable : LiveReadError.invalidResponse
            case .invalidResponse: throw LiveReadError.invalidResponse
            }
        } catch let error as LiveReadError { throw error }
        catch is DecodingError { throw LiveReadError.invalidResponse }
        catch { throw LiveReadError.network }
    }
    private static func recoverable(_ error: LiveReadError) -> Bool {
        switch error {
        case .notSignedIn, .loginExpired, .keychainPermission, .profileScopeMissing, .network, .invalidResponse, .missingFable: return true
        case .http(let code): return code >= 500
        default: return false
        }
    }
    private func oauth(_ endpoint: String, credential: LiveCredential, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Quota/0.6.3", forHTTPHeaderField: "User-Agent")
        if credential.provider == .fable { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }
    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await http.response(for: request)
            try UsageHTTPStatus.check(response)
            return data
        } catch let error as LiveReadError { throw error }
        catch { throw LiveReadError.network }
    }
    private func web(_ path: String, key: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://claude.ai/api/" + path)!)
        request.setValue("sessionKey=" + key, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Quota/0.6.3", forHTTPHeaderField: "User-Agent")
        return try await send(request)
    }
    private func webIfAvailable(_ credential: LiveCredential) async throws -> UsageSnapshot? {
        guard let account = credential.accountHint, !account.isEmpty,
              let organization = credential.organizationHint, UUID(uuidString: organization) != nil else { return nil }
        for session in await webSessions.read().prefix(2) {
            guard NativeClaudeWebSessions.valid(session.key) else { continue }
            let fingerprint = SHA256.hash(data: Data(session.key.utf8)).map { String(format: "%02x", $0) }.joined()
            let proof = account + ":" + organization
            do {
                if verifiedWebProfiles[fingerprint] != proof {
                    let bytes = try await web("account", key: session.key)
                    guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          root["uuid"] as? String == account else { continue }
                    let organizations = try await web("organizations", key: session.key)
                    guard let rows = try? JSONSerialization.jsonObject(with: organizations) as? [[String: Any]],
                          rows.contains(where: { $0["uuid"] as? String == organization }) else { continue }
                    verifiedWebProfiles = [fingerprint: proof]
                }
                let data = try await web("organizations/" + organization + "/usage", key: session.key)
                return try LivePayloadDecoder.fable(data, verifiedAccount: account, now: Date())
                    .withSource("web:" + session.source)
            } catch let error as LiveReadError {
                // Never hop to another cookie/source after 429 or a network challenge.
                if case .rateLimited = error { throw error }
                if error == .loginExpired { continue }
                throw error
            }
        }
        return nil
    }
}
