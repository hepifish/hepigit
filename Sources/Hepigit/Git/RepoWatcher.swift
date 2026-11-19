import Foundation
import CoreServices

/// Watches one repository with FSEvents (directory-level, coalesced by the kernel).
/// Only the active tab is watched, so 15 open repos cost one stream.
final class RepoWatcher {
    enum Change { case worktree, refs }

    private var stream: FSEventStreamRef?
    private let root: String
    private let onChange: (Change) -> Void
    private static let ignored = ["/node_modules/", "/.next/", "/.turbo/", "/DerivedData/", "/.build/", "/.git/objects/", "/.expo/", "/Pods/"]

    init(root: URL, onChange: @escaping (Change) -> Void) {
        self.root = root.path
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    private func start() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.handle(Array(arr.prefix(count)))
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, [root] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.35,
                                     UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ paths: [String]) {
        var refs = false, worktree = false
        for p in paths {
            let path = p.hasSuffix("/") ? p : p + "/"
            if Self.ignored.contains(where: path.contains) { continue }
            if path.contains("/.git/") {
                if path.hasSuffix(".lock/") { continue }
                refs = true
            } else {
                worktree = true
            }
        }
        if refs { DispatchQueue.main.async { self.onChange(.refs) } }
        else if worktree { DispatchQueue.main.async { self.onChange(.worktree) } }
    }
}
