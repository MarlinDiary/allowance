import Foundation
import QuotaCore

protocol ClaudeUsageCacheReading: Sendable {
    func read(for credential: LiveCredential, at now: Date) async -> UsageSnapshot?
}

struct ClaudeLocalUsageCache: ClaudeUsageCacheReading {
    let file: URL
    init(file: URL = ClaudeAccountContext.fileURL) { self.file = file }
    func read(for credential: LiveCredential, at now: Date) async -> UsageSnapshot? {
        await Task.detached(priority: .utility) { [file] in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
                  let data = try? Data(contentsOf: file) else { return nil }
            return Self.decode(data, expectedAccount: credential.accountHint, at: now)
        }.value
    }
    static func decode(_ data: Data, expectedAccount: String?, at now: Date) -> UsageSnapshot? {
        guard let expectedAccount, !expectedAccount.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              cache["accountUuid"] as? String == expectedAccount,
              let milliseconds = cache["fetchedAtMs"] as? Double, milliseconds.isFinite,
              let payload = cache["utilization"] as? [String: Any],
              let bytes = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let captured = Date(timeIntervalSince1970: milliseconds / 1000)
        guard captured <= now, now.timeIntervalSince(captured) <= 900,
              let value = try? LivePayloadDecoder.fable(bytes, verifiedAccount: expectedAccount, now: captured),
              let end = value.resetsAt, end > now else { return nil }
        return value.withSource("claude-code-cache")
    }
}

struct ClaudeAccountContext {
    let account: String
    let organization: String?
    static var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: root).appendingPathComponent(".claude.json")
        }
        return home.appendingPathComponent(".claude.json")
    }
    static func load() -> ClaudeAccountContext? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let id = account["accountUuid"] as? String, !id.isEmpty else { return nil }
        return ClaudeAccountContext(account: id, organization: account["organizationUuid"] as? String)
    }
}
