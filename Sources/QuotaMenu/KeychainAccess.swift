import Darwin
import Foundation
import LocalAuthentication
import Security

/// Reads another app's Keychain item. Background reads fail instead of prompting; only an
/// explicit menu action may show the system's access prompt.
enum KeychainAccess {
    enum Failure: Error, Equatable { case notFound, denied }

    // One read at a time, outside Swift's cooperative pool. A prompt left unanswered for
    // hours once held those pool threads and stopped every provider's refresh with it.
    private static let queue = DispatchQueue(label: "dev.marlindiary.Allowance.keychain", qos: .utility)

    // The login keychain ignores LAContext.interactionNotAllowed and prompts anyway. Its own
    // process-wide switch is the only way to fail instead; deprecated with no replacement
    // for this keychain, it is looked up at run time.
    private typealias SetInteraction = @convention(c) (DarwinBoolean) -> OSStatus
    private static let setInteraction: SetInteraction? = dlsym(dlopen(nil, RTLD_NOW), "SecKeychainSetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: SetInteraction.self) }

    static var suppressesLegacyPrompts: Bool { setInteraction != nil }

    static func password(service: String, account: String? = nil, allowInteraction: Bool) async -> Result<Data, Failure> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: read(service: service, account: account, allowInteraction: allowInteraction))
            }
        }
    }

    private static func read(service: String, account: String?, allowInteraction: Bool) -> Result<Data, Failure> {
        _ = setInteraction?(DarwinBoolean(allowInteraction))
        defer { _ = setInteraction?(false) }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return .success(data) }
        return .failure(status == errSecItemNotFound ? .notFound : .denied)
    }
}
