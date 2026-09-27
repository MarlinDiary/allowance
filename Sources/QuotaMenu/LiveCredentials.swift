import CryptoKit
import Foundation

enum QuotaProvider: String, CaseIterable, Sendable {
    // `fable` is Claude Code's all-model weekly limit. The case and its stored identifier
    // predate that switch and stay so persisted refresh gates survive upgrades.
    case codex = "codex", fable = "claude-fable"
    var shortName: String { self == .codex ? "Codex" : "Claude" }
    var index: Int { self == .codex ? 0 : 1 }
}

struct LiveCredential: Equatable, Sendable {
    let provider: QuotaProvider
    let accessToken: String
    let accountHint: String?
    let organizationHint: String?
    let credentialIssue: LiveReadError?
    /// Display only: names the account in a switch notification. Never sent or logged.
    let accountEmail: String?
    init(provider: QuotaProvider, accessToken: String, accountHint: String?,
         organizationHint: String? = nil, credentialIssue: LiveReadError? = nil, accountEmail: String? = nil) {
        self.provider = provider; self.accessToken = accessToken; self.accountHint = accountHint
        self.organizationHint = organizationHint; self.credentialIssue = credentialIssue
        self.accountEmail = accountEmail.flatMap(Self.displayEmail)
    }
    var tokenFingerprint: String { SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined() }
    // Claude's weekly limit belongs to an organization, so switching organizations under
    // one account is an account switch too.
    var identity: String {
        guard let accountHint else { return tokenFingerprint }
        return organizationHint.map { accountHint + ":" + $0 } ?? accountHint
    }

    static func displayEmail(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...254).contains(value.count), value.contains("@"), !value.contains(where: \.isNewline) else { return nil }
        return value
    }

    /// The `email` claim of a CLI's own ID token, decoded locally for display. The token is
    /// neither verified nor sent anywhere.
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }
}

enum LiveReadError: Error, Equatable {
    case notSignedIn, loginExpired, keychainPermission, profileScopeMissing
    case rateLimited(TimeInterval), http(Int), invalidResponse, accountChanged, missingWeekly, network

    var message: String {
        switch self {
        case .notSignedIn: return "Sign in required"
        case .loginExpired: return "Login expired"
        case .keychainPermission: return "Keychain access needed"
        case .profileScopeMissing: return "Profile access needed"
        case .rateLimited: return "Rate limited"
        case .http: return "Usage request failed"
        case .invalidResponse: return "Usage unavailable"
        case .accountChanged: return "Account changed"
        case .missingWeekly: return "Weekly limit unavailable"
        case .network: return "Offline"
        }
    }
}

protocol CredentialReading: Sendable {
    func read(_ provider: QuotaProvider, allowInteraction: Bool) async throws -> LiveCredential
}

struct SystemCredentialReader: CredentialReading {
    func read(_ provider: QuotaProvider, allowInteraction: Bool = false) async throws -> LiveCredential {
        do { return try await Self.load(provider, allowInteraction: allowInteraction) }
        catch let error as LiveReadError {
            if provider == .fable, let context = ClaudeAccountContext.load() {
                // Identity metadata is not a bearer token. It lets a same-account local
                // cache or existing Web session work when the CLI token is unavailable.
                return LiveCredential(provider: provider, accessToken: "", accountHint: context.account,
                    organizationHint: context.organization, credentialIssue: error, accountEmail: context.email)
            }
            throw error
        }
    }

    private static func load(_ provider: QuotaProvider, allowInteraction: Bool) async throws -> LiveCredential {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        if provider == .codex {
            let root = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            guard let data = try? Data(contentsOf: root.appendingPathComponent("auth.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = object["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String, !access.isEmpty,
                  let account = tokens["account_id"] as? String, !account.isEmpty else {
                throw LiveReadError.notSignedIn
            }
            return LiveCredential(provider: provider, accessToken: access, accountHint: account,
                accountEmail: (tokens["id_token"] as? String).flatMap(LiveCredential.email(fromIDToken:)))
        }
        let customDirectory = environment["CLAUDE_CONFIG_DIR"]
        let root = customDirectory.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let path = root.appendingPathComponent(".credentials.json")
        let data: Data
        if FileManager.default.fileExists(atPath: path.path) {
            guard let fileData = try? Data(contentsOf: path) else { throw LiveReadError.notSignedIn }
            data = fileData
        } else {
            // A custom profile must not silently adopt the default global profile's credentials.
            guard customDirectory == nil else { throw LiveReadError.notSignedIn }
            switch await KeychainAccess.password(service: "Claude Code-credentials", account: NSUserName(),
                                                 allowInteraction: allowInteraction) {
            case .success(let secret): data = secret
            case .failure(.notFound): throw LiveReadError.notSignedIn
            case .failure(.denied): throw LiveReadError.keychainPermission
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty else { throw LiveReadError.notSignedIn }
        if let expiry = oauth["expiresAt"] as? Double, expiry <= Date().timeIntervalSince1970 * 1000 {
            throw LiveReadError.loginExpired
        }
        if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:profile") {
            throw LiveReadError.profileScopeMissing
        }
        // This is an identity hint only. The server profile must prove it before usage is published.
        let account = ClaudeAccountContext.load()
        return LiveCredential(provider: provider, accessToken: access, accountHint: account?.account,
                              organizationHint: account?.organization, accountEmail: account?.email)
    }
}
