import CommonCrypto
import Foundation
import SQLite3
import XCTest
@testable import QuotaMenu

final class CookieFormatTests: XCTestCase {
    private func cookie(domain: String = ".claude.ai", expiry: Date = Date().addingTimeInterval(3600)) -> Data {
        func u32(_ value: Int, little: Bool = true) -> [UInt8] {
            let bytes = (0..<4).map { UInt8((value >> ($0 * 8)) & 255) }
            return little ? bytes : Array(bytes.reversed())
        }
        var record = [UInt8](repeating: 0, count: 56)
        for (field, value) in [(16, domain), (20, "sessionKey"), (24, "/"), (28, "sk-ant-synthetic-session")] {
            record.replaceSubrange(field..<field+4, with: u32(record.count))
            record += Array(value.utf8) + [0]
        }
        record.replaceSubrange(0..<4, with: u32(record.count))
        let bits = expiry.timeIntervalSinceReferenceDate.bitPattern
        record.replaceSubrange(40..<48, with: (0..<8).map { UInt8((bits >> ($0 * 8)) & 255) })
        let page = [UInt8](arrayLiteral: 0,0,1,0) + u32(1) + u32(12) + record + [0,0,0,0]
        return Data(Array("cook".utf8) + u32(1, little: false) + u32(page.count, little: false) + page)
    }
    func testSafariTargetDomainExpiryAndTruncatedBounds() {
        let valid = cookie()
        XCTAssertEqual(SafariSessionCookie.decode(valid, at: Date()), "sk-ant-synthetic-session")
        XCTAssertNil(SafariSessionCookie.decode(cookie(domain: "not-claude.ai"), at: Date()))
        XCTAssertNil(SafariSessionCookie.decode(cookie(expiry: Date().addingTimeInterval(-1)), at: Date()))
        for length in 0..<valid.count { XCTAssertNil(SafariSessionCookie.decode(valid.prefix(length), at: Date())) }
    }
    func testDesktopV10DecryptionAndUnknownFormatFailClosed() {
        let password = Data("synthetic-password".utf8)
        var key = [UInt8](repeating: 0, count: 16); let salt = [UInt8]("saltysalt".utf8)
        let status = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        let input = [UInt8]("sk-ant-synthetic-session".utf8); let iv = [UInt8](repeating: 32, count: 16)
        var output = [UInt8](repeating: 0, count: input.count + 16); var count = 0
        XCTAssertEqual(CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, input, input.count, &output, output.count, &count), Int32(kCCSuccess))
        let data = Data("v10".utf8) + Data(output.prefix(count))
        XCTAssertEqual(DesktopSessionCookie.decrypt(data, password: password), "sk-ant-synthetic-session")
        XCTAssertNil(DesktopSessionCookie.decrypt(data, password: Data("wrong-password".utf8)))
        XCTAssertNil(DesktopSessionCookie.decrypt(Data("v20unsupported".utf8), password: password))
    }
    func testDesktopPlaintextCookieReadIsReadOnlyAndScoped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Quota-cookie-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Cookies")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        let expiry = Int64((Date().timeIntervalSince1970 + 3600 + 11_644_473_600) * 1_000_000)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,expires_utc INTEGER); INSERT INTO cookies VALUES('.claude.ai','sessionKey','sk-ant-synthetic-session',X'',\(expiry));", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: file)
        XCTAssertEqual(DesktopSessionCookie.read(file, at: Date()), "sk-ant-synthetic-session")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}
