import Foundation
import ServiceManagement

enum LoginItemStatus: String {
    case notRegistered, enabled, requiresApproval, notFound
}

@MainActor
protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct NativeLoginItemService: LoginItemManaging {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LaunchAtLogin {
    static let configuredKey = "allowance.launch-at-login.configured.v1"
    private let service: any LoginItemManaging
    private let defaults: UserDefaults
    private let installed: Bool

    init(service: (any LoginItemManaging)? = nil, defaults: UserDefaults = .standard,
         installed: Bool = LaunchAtLogin.isInstalled(bundleURL: Bundle.main.bundleURL)) {
        self.service = service ?? NativeLoginItemService(); self.defaults = defaults; self.installed = installed
    }

    nonisolated static func isInstalled(bundleURL: URL, homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let app = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard app.pathExtension == "app" else { return false }
        let roots = [URL(fileURLWithPath: "/Applications"), homeURL.appendingPathComponent("Applications")]
        return roots.contains { app.path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
    }

    /// First installed launch only. Once configured, the OS owns the user's choice:
    /// removing/disabling this login item never causes us to register it again.
    func configureOnFirstLaunch() {
        guard installed, !defaults.bool(forKey: Self.configuredKey) else { return }
        defaults.set(true, forKey: Self.configuredKey)
        // A newly installed main app can report notFound until its first registration.
        guard service.status == .notRegistered || service.status == .notFound else { return }
        do { try service.register() }
        catch {
            let error = error as NSError
            fputs("Launch at login registration: \(error.domain) / \(error.code). Manage Allowance in System Settings > General > Login Items.\n", stderr)
        }
    }

    /// Explicit local controls, also used by release acceptance and rollback.
    /// Diagnostics and builds never call the automatic registration path.
    func setEnabled(_ enabled: Bool) throws {
        guard installed else { throw NSError(domain: "Allowance.LoginItem", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Move Allowance.app into Applications before configuring launch at login."]) }
        if enabled {
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
        defaults.set(true, forKey: Self.configuredKey)
    }

    var evidence: [String: Any] {
        ["mode": "launch-at-login", "mechanism": "SMAppService.mainApp", "status": service.status.rawValue,
         "configuredOnce": defaults.bool(forKey: Self.configuredKey), "installedApplication": installed,
         "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "source",
         "launchesAt": "user login", "opensMainWindow": false, "addsMenuRows": false]
    }
}
