import Foundation
import XCTest
@testable import QuotaMenu

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    final class Service: LoginItemManaging {
        var status: LoginItemStatus = .notRegistered
        var registrations = 0
        var removals = 0
        var error: Error?
        func register() throws {
            registrations += 1
            if let error { throw error }
            status = .enabled
        }
        func unregister() throws {
            removals += 1
            if let error { throw error }
            status = .notRegistered
        }
    }

    private func withFixture(_ body: (Service, UserDefaults) throws -> Void) rethrows {
        let name = "Allowance.LaunchAtLoginTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(Service(), defaults)
    }

    func testFirstInstalledLaunchRegistersExactlyOnceAcrossControllerRestarts() {
        withFixture { service, defaults in
            LaunchAtLogin(service: service, defaults: defaults, installed: true).configureOnFirstLaunch()
            LaunchAtLogin(service: service, defaults: defaults, installed: true).configureOnFirstLaunch()
            XCTAssertEqual(service.registrations, 1)
            XCTAssertEqual(service.status, .enabled)
            XCTAssertTrue(defaults.bool(forKey: LaunchAtLogin.configuredKey))
        }
    }

    func testBuildAndDiskImageLaunchesNeverRegister() {
        withFixture { service, defaults in
            LaunchAtLogin(service: service, defaults: defaults, installed: false).configureOnFirstLaunch()
            XCTAssertEqual(service.registrations, 0)
            XCTAssertFalse(defaults.bool(forKey: LaunchAtLogin.configuredKey))
        }
    }

    func testExistingEnabledOrRevokedConsentIsNeverOverridden() {
        for status in [LoginItemStatus.enabled, .requiresApproval, .notFound] {
            withFixture { service, defaults in
                service.status = status
                LaunchAtLogin(service: service, defaults: defaults, installed: true).configureOnFirstLaunch()
                XCTAssertEqual(service.registrations, 0)
                XCTAssertEqual(service.status, status)
                XCTAssertTrue(defaults.bool(forKey: LaunchAtLogin.configuredKey))
            }
        }
    }

    func testRemovalInSystemSettingsStaysRemovedOnNextLaunch() {
        withFixture { service, defaults in
            let login = LaunchAtLogin(service: service, defaults: defaults, installed: true)
            login.configureOnFirstLaunch()
            service.status = .notRegistered // user removes the item in System Settings
            login.configureOnFirstLaunch()
            XCTAssertEqual(service.registrations, 1)
            XCTAssertEqual(service.status, .notRegistered)
        }
    }

    func testRegistrationErrorDoesNotLoopOrForceAnotherPrompt() {
        withFixture { service, defaults in
            service.error = NSError(domain: "fixture", code: 1)
            let login = LaunchAtLogin(service: service, defaults: defaults, installed: true)
            login.configureOnFirstLaunch(); login.configureOnFirstLaunch()
            XCTAssertEqual(service.registrations, 1)
            XCTAssertTrue(defaults.bool(forKey: LaunchAtLogin.configuredKey))
        }
    }

    func testExplicitDisablePersistsAndExplicitEnableWorksAgain() throws {
        try withFixture { service, defaults in
            let login = LaunchAtLogin(service: service, defaults: defaults, installed: true)
            login.configureOnFirstLaunch()
            try login.setEnabled(false)
            login.configureOnFirstLaunch()
            XCTAssertEqual(service.status, .notRegistered)
            XCTAssertEqual(service.registrations, 1)
            XCTAssertEqual(service.removals, 1)
            try login.setEnabled(true)
            XCTAssertEqual(service.status, .enabled)
            XCTAssertEqual(service.registrations, 2)
        }
    }

    func testExplicitDisableBeforeFirstLaunchDoesNotLaterEnableIt() throws {
        try withFixture { service, defaults in
            let login = LaunchAtLogin(service: service, defaults: defaults, installed: true)
            try login.setEnabled(false)
            login.configureOnFirstLaunch()
            XCTAssertEqual(service.registrations, 0)
            XCTAssertEqual(service.removals, 0)
        }
    }

    func testExplicitEnableAdoptsPendingApprovalWithoutRepeatedRegistration() throws {
        try withFixture { service, defaults in
            service.status = .requiresApproval
            let login = LaunchAtLogin(service: service, defaults: defaults, installed: true)
            try login.setEnabled(true)
            XCTAssertEqual(service.status, .requiresApproval)
            XCTAssertEqual(service.registrations, 0)
        }
    }

    func testReadOnlyStatusNeverConfiguresAnything() {
        withFixture { service, defaults in
            let login = LaunchAtLogin(service: service, defaults: defaults, installed: true)
            XCTAssertEqual(login.evidence["status"] as? String, "notRegistered")
            XCTAssertEqual(login.evidence["mechanism"] as? String, "SMAppService.mainApp")
            XCTAssertEqual(login.evidence["addsMenuRows"] as? Bool, false)
            XCTAssertEqual(service.registrations, 0)
            XCTAssertFalse(defaults.bool(forKey: LaunchAtLogin.configuredKey))
        }
    }

    func testExplicitControlsRejectStagingBundles() throws {
        try withFixture { service, defaults in
            let login = LaunchAtLogin(service: service, defaults: defaults, installed: false)
            XCTAssertThrowsError(try login.setEnabled(true))
            XCTAssertThrowsError(try login.setEnabled(false))
            XCTAssertEqual(service.registrations, 0)
            XCTAssertEqual(service.removals, 0)
        }
    }

    func testOnlyApplicationsDirectoriesAreEligible() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        for path in ["/Applications/Allowance.app", "/Applications/Utilities/Allowance.app", "/Users/fixture/Applications/Allowance.app"] {
            XCTAssertTrue(LaunchAtLogin.isInstalled(bundleURL: URL(fileURLWithPath: path), homeURL: home), path)
        }
        for path in ["/Volumes/Allowance/Allowance.app", "/tmp/Allowance.app", "/Applications-old/Allowance.app", "/Users/fixture/.Trash/Allowance.app", "/Applications/Allowance", "/Applications"] {
            XCTAssertFalse(LaunchAtLogin.isInstalled(bundleURL: URL(fileURLWithPath: path), homeURL: home), path)
        }
    }
}
