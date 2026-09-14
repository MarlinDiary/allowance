import AppKit
import Foundation
import QuotaCore
import UserNotifications

@MainActor
final class ResetMonitor: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let defaults: UserDefaults
    private let key = "allowance.reset-notices.v1"
    private var state: ResetNoticeState
    private var polling = ResetPollPolicy()
    private var cached: ResetStatus?
    private var etag: String?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var inFlight = false
    private var stopped = false
    private let onConfirmed: () -> Void
    private let session: URLSession
    private(set) var lastHTTPStatus: Int?
    private(set) var acceptedNotices = 0
    private var lastError: [String: Any]?

    init(defaults: UserDefaults = .standard, onConfirmed: @escaping () -> Void) {
        self.defaults = defaults
        self.state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ResetNoticeState.self, from: $0) } ?? ResetNoticeState()
        self.onConfirmed = onConfirmed
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        self.session = URLSession(configuration: config)
        super.init()
    }

    func start() {
        center.delegate = self
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            await poll()
        }
        timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        timer?.tolerance = 15
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        session.invalidateAndCancel()
    }

    func poll() async {
        guard !stopped, !inFlight, Date() >= polling.nextAttempt else { return }
        inFlight = true
        defer {
            inFlight = false
            if let i = CommandLine.arguments.firstIndex(of: "--reset-evidence"), CommandLine.arguments.indices.contains(i + 1) {
                Task { await self.writeEvidence(to: CommandLine.arguments[i + 1]) }
            }
        }
        var request = URLRequest(url: URL(string: "https://codex-resets.com/api/v1/status")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Allowance/0.6.9", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (bytes, response) = try await session.data(for: request)
            guard !stopped, let http = response as? HTTPURLResponse else { return }
            lastHTTPStatus = http.statusCode
            lastError = nil
            guard http.url?.scheme == "https", http.url?.host == "codex-resets.com" else {
                polling.finish(status: nil, retryAfter: nil, at: Date()); return
            }
            let retry = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: Date())
            if http.statusCode == 200 {
                guard bytes.count <= 512_000, let status = try? JSONDecoder().decode(ResetStatus.self, from: bytes) else {
                    polling.finish(status: nil, retryAfter: retry, at: Date()); return
                }
                cached = status
                etag = http.value(forHTTPHeaderField: "ETag").flatMap { $0.count <= 256 ? $0 : nil }
            } else if http.statusCode != 304 {
                polling.finish(status: http.statusCode, retryAfter: retry, at: Date()); return
            }
            polling.finish(status: http.statusCode, retryAfter: nil, at: Date())
            // A 304 still retries an uncommitted delivery from the cached payload.
            if let cached { await deliver(cached) }
        } catch {
            if !stopped {
                let e = error as NSError
                lastError = ["domain": e.domain, "code": e.code]
                polling.finish(status: nil, retryAfter: nil, at: Date())
            }
        }
    }

    private func deliver(_ status: ResetStatus) async {
        let notices = ResetNoticePolicy.notices(status: status, state: &state, now: Date())
        persist() // commit bootstrap even when system notification access is denied
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for notice in notices {
            guard !stopped else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            if notice.kind == .announced {
                if let date = notice.scheduledFor {
                    content.body = "Tibo announced a Codex reset for \(date.formatted(date: .abbreviated, time: .shortened))."
                } else { content.body = "Tibo announced an upcoming Codex reset. Timing is not confirmed." }
            } else {
                content.body = notice.observed ? "A global Codex reset was observed. Check your current allowance."
                    : "Tibo confirmed the global Codex reset. Check your current allowance."
            }
            content.sound = .default
            content.userInfo = ["sourceURL": notice.sourceURL.absoluteString]
            do {
                try await center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
                ResetNoticePolicy.record(notice.identifier, in: &state)
                persist(); acceptedNotices += 1
                if notice.kind == .confirmed { onConfirmed() }
            } catch { /* retry on the next allowed poll, including a 304 */ }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }

    nonisolated static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    func writeEvidence(to path: String) async {
        let settings = await center.notificationSettings()
        let record: [String: Any] = ["notificationAuthorization": settings.authorizationStatus.rawValue,
            "resetFeedHTTPStatus": lastHTTPStatus as Any? ?? NSNull(),
            "feedError": lastError as Any? ?? NSNull(),
            "baselineEstablished": state.initialized, "acceptedNoticesThisRun": acceptedNotices,
            "nextPollAt": polling.nextAttempt.timeIntervalSince1970, "etagInUse": etag != nil,
            "bankedResetNotifications": false, "forecastNotifications": false,
            "executedResetRequiresLatestReset": true]
        if let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Explicit diagnostic only; never pretends to be an actual Tibo announcement.
    func notificationTest(to path: String) async {
        let settings = await center.notificationSettings()
        var record: [String: Any] = ["mode": "notification-test", "authorization": settings.authorizationStatus.rawValue,
            "alertSetting": settings.alertSetting.rawValue, "alertStyle": settings.alertStyle.rawValue,
            "notificationCenterSetting": settings.notificationCenterSetting.rawValue,
            "soundSetting": settings.soundSetting.rawValue,
            "scheduledDeliverySetting": settings.scheduledDeliverySetting.rawValue,
            "deliveredBySystem": false]
        if settings.authorizationStatus == .authorized {
            let content = UNMutableNotificationContent()
            content.title = "Allowance notification test"
            content.body = "Reset notifications are connected. This is a test, not a Codex reset."
            let identifier = "allowance.notification-test"
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                record["requestAccepted"] = true
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let delivered = await center.deliveredNotifications()
                    if delivered.contains(where: { $0.request.identifier == identifier }) {
                        record["deliveredBySystem"] = true; break
                    }
                }
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
            } catch { record["requestAccepted"] = false }
        } else { record["requestAccepted"] = false }
        if let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let raw = response.notification.request.content.userInfo["sourceURL"] as? String {
            let url = ResetNoticePolicy.trustedURL(raw)
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
