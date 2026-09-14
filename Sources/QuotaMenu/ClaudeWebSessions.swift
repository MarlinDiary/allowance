import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3

struct ClaudeWebSession: Sendable {
    let key: String
    let source: String
}
protocol ClaudeWebSessionReading: Sendable {
    func read() async -> [ClaudeWebSession]
}

struct NativeClaudeWebSessions: ClaudeWebSessionReading {
    func read() async -> [ClaudeWebSession] {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            var result = [ClaudeWebSession]()
            for relative in ["Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
                             "Library/Cookies/Cookies.binarycookies"] {
                let file = home.appendingPathComponent(relative)
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_000_000,
                   let bytes = try? Data(contentsOf: file),
                   let key = SafariSessionCookie.decode(bytes, at: Date()) {
                    result.append(ClaudeWebSession(key: key, source: "safari")); break
                }
            }
            let desktop = home.appendingPathComponent("Library/Application Support/Claude/Cookies")
            if let key = DesktopSessionCookie.read(desktop, at: Date()), !result.contains(where: { $0.key == key }) {
                result.append(ClaudeWebSession(key: key, source: "claude-desktop"))
            }
            return result
        }.value
    }
    static func valid(_ key: String) -> Bool {
        key.hasPrefix("sk-ant-") && (8...4096).contains(key.utf8.count) && key.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ .").contains($0)
                && $0 != " "
        }
    }
}

// A bounded, read-only decoder for the system's binary cookie format. Only the
// claude.ai sessionKey value is ever returned; no browser database is modified.
enum SafariSessionCookie {
    static func decode(_ data: Data, at now: Date) -> String? {
        let bytes = [UInt8](data)
        func u32(_ offset: Int, little: Bool) -> Int? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            let b = Array(bytes[offset..<offset+4]); let ordered = little ? Array(b.reversed()) : b
            return ordered.reduce(0) { ($0 << 8) | Int($1) }
        }
        guard bytes.count >= 8, Array(bytes.prefix(4)) == Array("cook".utf8),
              let pages = u32(4, little: false), (1...1024).contains(pages), 8 + pages * 4 <= bytes.count else { return nil }
        var pageStart = 8 + pages * 4
        for page in 0..<pages {
            guard let size = u32(8 + page * 4, little: false), size >= 12,
                  pageStart <= bytes.count - size else { return nil }
            defer { pageStart += size }
            let end = pageStart + size
            guard let count = u32(pageStart + 4, little: true), count <= 16384, 8 + count * 4 <= size else { continue }
            for index in 0..<count {
                guard let offset = u32(pageStart + 8 + index * 4, little: true), offset >= 8 + count * 4,
                      offset <= size - 56 else { continue }
                let record = pageStart + offset
                guard let length = u32(record, little: true), length >= 56, record <= end - length else { continue }
                func string(_ field: Int) -> String? {
                    guard let relative = u32(record + field, little: true), relative >= 56, relative < length else { return nil }
                    let start = record + relative
                    guard let zero = bytes[start..<record+length].firstIndex(of: 0) else { return nil }
                    return String(bytes: bytes[start..<zero], encoding: .utf8)
                }
                guard let domain = string(16), ["claude.ai", ".claude.ai"].contains(domain),
                      string(20) == "sessionKey" else { continue }
                let bits = bytes[record+40..<record+48].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
                let expiry = Double(bitPattern: bits)
                guard expiry.isFinite, Date(timeIntervalSinceReferenceDate: expiry) > now,
                      let key = string(28), NativeClaudeWebSessions.valid(key) else { continue }
                return key
            }
        }
        return nil
    }
}

enum DesktopSessionCookie {
    static func read(_ file: URL, at now: Date) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        let query = "SELECT value, encrypted_value, expires_utc FROM cookies WHERE host_key IN ('claude.ai','.claude.ai') AND name='sessionKey' ORDER BY expires_utc DESC LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let expiry = Double(sqlite3_column_int64(statement, 2)) / 1_000_000 - 11_644_473_600
        guard expiry > now.timeIntervalSince1970 else { return nil }
        if let text = sqlite3_column_text(statement, 0) {
            let key = String(cString: text)
            if NativeClaudeWebSessions.valid(key) { return key }
        }
        let count = Int(sqlite3_column_bytes(statement, 1))
        guard (4...8192).contains(count), let blob = sqlite3_column_blob(statement, 1),
              let password = safeStoragePassword() else { return nil }
        return decrypt(Data(bytes: blob, count: count), password: password)
    }
    private static func safeStoragePassword() -> Data? {
        for service in ["Claude Safe Storage", "Claude SafeStorage"] {
            let context = LAContext(); context.interactionNotAllowed = true
            var result: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data { return data }
        }
        return nil
    }
    static func decrypt(_ data: Data, password: Data) -> String? {
        // Chromium's macOS v10 format. Unknown/app-bound formats are left untouched.
        guard data.prefix(3) == Data("v10".utf8), !password.isEmpty else { return nil }
        var key = [UInt8](repeating: 0, count: 16)
        let salt = [UInt8]("saltysalt".utf8)
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        let encrypted = [UInt8](data.dropFirst(3)); let iv = [UInt8](repeating: 32, count: 16)
        var output = [UInt8](repeating: 0, count: encrypted.count + 16); var written = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, encrypted, encrypted.count, &output, output.count, &written)
        guard status == kCCSuccess else { return nil }
        for drop in [0, 32] where written > drop {
            if let value = String(bytes: output[drop..<written], encoding: .utf8), NativeClaudeWebSessions.valid(value) { return value }
        }
        return nil
    }
}
