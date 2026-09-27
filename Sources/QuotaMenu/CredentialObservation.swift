import AppKit
import Darwin
import Foundation

@MainActor
final class CredentialObservation {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileWatches: [String: (inode: ino_t, source: DispatchSourceFileSystemObject)] = [:]
    private let files: [URL]
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private let changed: () -> Void
    private let refresh: () -> Void

    /// The CLI login files where an account switch lands, and the directories that hold them.
    nonisolated static var loginLocations: (directories: [URL], files: [URL]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let claude = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        return ([codex, home, claude], [codex.appendingPathComponent("auth.json"), ClaudeAccountContext.fileURL,
                                        claude.appendingPathComponent(".credentials.json")])
    }

    init(directories: [URL] = CredentialObservation.loginLocations.directories,
         files: [URL] = CredentialObservation.loginLocations.files,
         changed: @escaping () -> Void, refresh: @escaping () -> Void) {
        self.files = files
        self.changed = changed
        self.refresh = refresh
        // Directories see login files replaced atomically; each file's own events see a login
        // rewritten in place, which never touches its directory.
        for path in directories {
            let fd = open(path.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in self?.noticeChange() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        watchFiles()
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

    private func noticeChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watchFiles()
            self.changed()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // Follows each login file to its current inode, so a replaced or newly created file
    // stays watched and a removed one stops holding a descriptor.
    private func watchFiles() {
        for file in files {
            var info = stat()
            let inode = stat(file.path, &info) == 0 ? info.st_ino : nil
            if let watch = fileWatches[file.path], watch.inode == inode { continue }
            fileWatches.removeValue(forKey: file.path)?.source.cancel()
            guard let inode else { continue }
            let fd = open(file.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.noticeChange() }
            source.setCancelHandler { close(fd) }
            source.resume()
            fileWatches[file.path] = (inode, source)
        }
    }

    func stop() {
        pending?.cancel()
        sources.forEach { $0.cancel() }
        sources.removeAll()
        fileWatches.values.forEach { $0.source.cancel() }
        fileWatches.removeAll()
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
