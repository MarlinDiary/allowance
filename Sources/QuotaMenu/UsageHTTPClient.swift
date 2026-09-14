import Foundation

protocol UsageHTTPClient: Sendable {
    func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
actor NativeUsageHTTPClient: UsageHTTPClient {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config, delegate: NoUsageRedirects(), delegateQueue: nil)
    }
    func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 2_000_000 else { throw LiveReadError.invalidResponse }
        return (data, response)
    }
}

enum UsageHTTPStatus {
    static func check(_ response: HTTPURLResponse, at now: Date = Date()) throws {
        switch response.statusCode {
        case 200: return
        case 401: throw LiveReadError.loginExpired
        case 429:
            let raw = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let delay = Double(raw) ?? parser.date(from: raw)?.timeIntervalSince(now) ?? 300
            throw LiveReadError.rateLimited(delay.isFinite ? max(60, delay) : 300)
        default: throw LiveReadError.http(response.statusCode)
        }
    }
}
