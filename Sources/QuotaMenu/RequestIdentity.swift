import Foundation

enum RequestIdentity {
    static let userAgent = userAgent(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    static func userAgent(version: String?) -> String {
        guard let version, !version.isEmpty, version.utf8.count <= 64,
              version.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || [45, 46, 95].contains($0) }) else { return "Allowance" }
        return "Allowance/" + version
    }

    static func apply(to request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }
}
