import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum QuotaProvider: String, CaseIterable, Sendable {
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
    init(provider: QuotaProvider, accessToken: String, accountHint: String?,
         organizationHint: String? = nil, credentialIssue: LiveReadError? = nil) {
        self.provider = provider; self.accessToken = accessToken; self.accountHint = accountHint
        self.organizationHint = organizationHint; self.credentialIssue = credentialIssue
    }
    var tokenFingerprint: String { SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined() }
    var identity: String { accountHint ?? tokenFingerprint }
}

enum LiveReadError: Error, Equatable {
    case notSignedIn, loginExpired, keychainPermission, profileScopeMissing
    case rateLimited(TimeInterval), http(Int), invalidResponse, accountChanged, missingFable, network

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
        case .missingFable: return "Fable limit unavailable"
        case .network: return "Offline"
        }
    }
}

protocol CredentialReading: Sendable {
    func read(_ provider: QuotaProvider, allowInteraction: Bool) async throws -> LiveCredential
}

struct SystemCredentialReader: CredentialReading {
    func read(_ provider: QuotaProvider, allowInteraction: Bool = false) async throws -> LiveCredential {
        try await Task.detached(priority: .utility) {
            do { return try Self.load(provider, allowInteraction: allowInteraction) }
            catch let error as LiveReadError {
                if provider == .fable, let context = ClaudeAccountContext.load() {
                    // Identity metadata is not a bearer token. It lets a same-account local
                    // cache or existing Web session work when the CLI token is unavailable.
                    return LiveCredential(provider: provider, accessToken: "", accountHint: context.account,
                        organizationHint: context.organization, credentialIssue: error)
                }
                throw error
            }
        }.value
    }

    private static func load(_ provider: QuotaProvider, allowInteraction: Bool) throws -> LiveCredential {
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
            return LiveCredential(provider: provider, accessToken: access, accountHint: account)
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
            let context = LAContext()
            context.interactionNotAllowed = !allowInteraction
            var result: CFTypeRef?
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials",
                kSecAttrAccount as String: NSUserName(),
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context
            ]
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let secret = result as? Data else {
                if status == errSecItemNotFound { throw LiveReadError.notSignedIn }
                throw LiveReadError.keychainPermission
            }
            data = secret
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
                              organizationHint: account?.organization)
    }
}
