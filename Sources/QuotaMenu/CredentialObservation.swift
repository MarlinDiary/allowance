import AppKit
import Darwin
import Foundation

@MainActor
final class CredentialObservation {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private let changed: () -> Void
    private let refresh: () -> Void

    init(changed: @escaping () -> Void, refresh: @escaping () -> Void) {
        self.changed = changed
        self.refresh = refresh
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        // Watch the parent directories: CLI credential files are commonly replaced atomically.
        let paths = [codex, home, home.appendingPathComponent(".claude")]
        for path in paths {
            let fd = open(path.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.pending?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.changed() }
                self.pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.changed()
                self?.refresh()
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.changed()
                    self?.refresh()
                }
            }
    }

    func stop() {
        pending?.cancel()
        sources.forEach { $0.cancel() }
        sources.removeAll()
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
