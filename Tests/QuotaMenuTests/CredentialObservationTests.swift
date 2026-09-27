import Foundation
import XCTest
@testable import QuotaMenu

@MainActor
final class CredentialObservationTests: XCTestCase {
    func testLoginFileChangesAreNoticedWhetherRewrittenOrReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("allowance-login-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{"account":"A"}"#.utf8).write(to: file)
        var notices = 0
        // No directory watch: every notice below must come from the file's own watch.
        let observation = CredentialObservation(directories: [], files: [file], changed: { notices += 1 }, refresh: {})
        defer { observation.stop() }
        func waitForNotice(after count: Int, _ step: String) async throws {
            let deadline = Date().addingTimeInterval(5)
            while notices <= count, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertGreaterThan(notices, count, step)
        }
        // An in-place rewrite never touches the directory.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"account":"B"}"#.utf8))
        try handle.close()
        try await waitForNotice(after: 0, "in-place rewrite")
        var seen = notices
        try Data(#"{"account":"C"}"#.utf8).write(to: file, options: .atomic)
        try await waitForNotice(after: seen, "atomic replacement")
        // The watch follows the replacement to the new file.
        seen = notices
        let later = try FileHandle(forWritingTo: file)
        try later.truncate(atOffset: 0)
        try later.write(contentsOf: Data(#"{"account":"D"}"#.utf8))
        try later.close()
        try await waitForNotice(after: seen, "rewrite after replacement")
    }
}
