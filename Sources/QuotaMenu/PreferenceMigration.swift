import Foundation

/// Only the previous app's four owned cache/scheduling keys; no credentials or
/// unrelated defaults migrate. Existing Allowance values always win.
enum PreferenceMigration {
    static let ownedKeys = ["quota.refresh.v1.codex", "quota.refresh.v1.claude-fable",
                            "quota.usage.v1.codex", "quota.usage.v1.claude-fable"]
    static func migrate(from old: [String: Any], to defaults: UserDefaults) {
        for key in ownedKeys where defaults.object(forKey: key) == nil {
            guard let data = old[key] as? Data, data.count <= 64_000,
                  (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
            defaults.set(data, forKey: key)
        }
    }
    static func migratePreviousApp() {
        migrate(from: UserDefaults.standard.persistentDomain(forName: "local.marlin.QuotaMenuPreview") ?? [:], to: .standard)
    }
}
