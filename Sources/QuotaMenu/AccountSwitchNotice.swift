import Foundation
import UserNotifications

/// Tells the user which account a CLI switched to. A later switch replaces the notice.
enum AccountSwitchNotice {
    static func content(for provider: QuotaProvider, email: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(provider == .codex ? "Codex" : "Claude Code") account switched"
        content.body = "Allowance now shows usage for \(email ?? "the new account")."
        return content
    }

    static func post(for provider: QuotaProvider, email: String?) {
        let request = UNNotificationRequest(identifier: "allowance.account-switch." + provider.rawValue,
                                            content: content(for: provider, email: email), trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
