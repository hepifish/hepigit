import Foundation

/// The repository state that local actions can change: refs, HEAD, index, working tree, stashes.
/// Remote-tracking refs are left out, so fetch and push never create undo entries.
struct Snapshot: Equatable {
    var head: String                    // "refs/heads/main" when on a branch, else a commit hash
    var refs: [String: String]          // refs/heads/* and refs/tags/* -> object
    var index: String                   // tree of the staging area
    var worktree: String                // tree of the working files, untracked included (ignored excluded)
    var stashes: [StashEntry]
    var inProgress: Bool                // merge, rebase, cherry-pick or revert under way
    var localExclude: String = ""       // .git/info/exclude: "ignore only on this Mac"

    struct StashEntry: Equatable { let hash: String; let message: String }
}

struct UndoEntry {
    let label: String
    let before: Snapshot
    let after: Snapshot
}

extension RepoModel {
    private static let maxUndo = 25

    /// nil when the state can't be captured exactly (unborn branch, or a conflict already in the index).
    func snapshot() async -> Snapshot? {
        guard let gitDir else { return nil }
        let headRef = (try? await git.text(["symbolic-ref", "-q", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let headHash = (try? await git.text(["rev-parse", "-q", "--verify", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !headHash.isEmpty else { return nil }
        // Index tree; fails while conflicts are unresolved, and then we can't restore exactly.
        guard let index = try? await git.text(["write-tree"]).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        // Working tree: stage everything into a throwaway copy of the index and write it as a tree.
        let tmp = gitDir.appendingPathComponent("hepigit-undo-index")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.copyItem(at: gitDir.appendingPathComponent("index"), to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let env = ["GIT_INDEX_FILE": tmp.path]
        guard (try? await git.run(["add", "-A"], env: env)) != nil,
              let worktree = try? await git.text(["write-tree"], env: env).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        var refs: [String: String] = [:]
        for line in ((try? await git.text(["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/tags"])) ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { refs[String(parts[1])] = String(parts[0]) }
        }
        let stashes = ((try? await git.text(["stash", "list", "--format=%H%x1f%gs"])) ?? "").split(separator: "\n").compactMap { l -> Snapshot.StashEntry? in
            let f = l.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            return f.count == 2 ? .init(hash: String(f[0]), message: String(f[1])) : nil
        }
        let fm = FileManager.default
        let inProgress = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"]
            .contains { fm.fileExists(atPath: gitDir.appendingPathComponent($0).path) }
        return Snapshot(head: headRef.isEmpty ? headHash : headRef, refs: refs, index: index, worktree: worktree,
                        stashes: stashes, inProgress: inProgress, localExclude: readExclude())
    }

    /// Pushes an entry when the action changed something local. Returns whether it can be undone.
    func recordUndo(_ before: Snapshot?, label: String) async -> Bool {
        guard let before, let after = await snapshotAllowingConflicts(), after != before else { return false }
        undoStack.append(UndoEntry(label: label, before: before, after: after))
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        return true
    }

    /// After a conflicted pop or merge the index can't be written as a tree; record it as "conflicted".
    private func snapshotAllowingConflicts() async -> Snapshot? {
        if let s = await snapshot() { return s }
        guard var s = await snapshotIgnoringIndex() else { return nil }
        s.index = "conflicted"
        return s
    }

    private func snapshotIgnoringIndex() async -> Snapshot? {
        guard let gitDir else { return nil }
        // Same as snapshot(), but the worktree tree comes from a fresh index so conflicts don't block it.
        let headRef = (try? await git.text(["symbolic-ref", "-q", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let headHash = (try? await git.text(["rev-parse", "-q", "--verify", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let tmp = gitDir.appendingPathComponent("hepigit-undo-index")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let env = ["GIT_INDEX_FILE": tmp.path]
        guard (try? await git.run(["read-tree", "HEAD"], env: env)) != nil,
              (try? await git.run(["add", "-A"], env: env)) != nil,
              let worktree = try? await git.text(["write-tree"], env: env).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var refs: [String: String] = [:]
        for line in ((try? await git.text(["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/tags"])) ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { refs[String(parts[1])] = String(parts[0]) }
        }
        let stashes = ((try? await git.text(["stash", "list", "--format=%H%x1f%gs"])) ?? "").split(separator: "\n").compactMap { l -> Snapshot.StashEntry? in
            let f = l.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            return f.count == 2 ? .init(hash: String(f[0]), message: String(f[1])) : nil
        }
        return Snapshot(head: headRef.isEmpty ? headHash : headRef, refs: refs, index: "", worktree: worktree, stashes: stashes,
                        inProgress: true, localExclude: readExclude())
    }

    var undoLabel: String? { undoStack.last?.label }

    func undo() {
        guard let entry = undoStack.last else { return }
        perform("undo", success: "Undone: \(entry.label)") { [weak self] in try await self?.undoLast() }
    }

    /// Restores the state from before the last action, only if nothing changed since it.
    func undoLast() async throws {
        guard let entry = undoStack.last else { return }
        guard let now = await snapshotAllowingConflicts() else {
            throw GitError(message: "Couldn't read the current state of the repository.")
        }
        guard now == entry.after else {
            undoStack.removeAll()
            throw GitError(message: "Files or branches changed after “\(entry.label)”. Undoing now would overwrite that newer work, so nothing was changed.")
        }
        try await restore(entry.before, from: now)
        undoStack.removeLast()
    }

    var excludeURL: URL? { gitDir?.appendingPathComponent("info/exclude") }

    private func readExclude() -> String {
        guard let url = excludeURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func restore(_ s: Snapshot, from now: Snapshot) async throws {

        // 1. Leave any merge, rebase, cherry-pick or revert that the action started.
        if now.inProgress {
            for cmd in ["rebase", "merge", "cherry-pick", "revert"] { _ = try? await git.run([cmd, "--quit"]) }
        }
        // 2. Branches and tags, in one transaction.
        var tx = ""
        for (ref, obj) in s.refs where now.refs[ref] != obj { tx += "update \(ref) \(obj)\n" }
        for ref in now.refs.keys where s.refs[ref] == nil { tx += "delete \(ref)\n" }
        if !tx.isEmpty { try await git.run(["update-ref", "--stdin"], input: Data(tx.utf8)) }
        // 3. HEAD.
        if s.head.hasPrefix("refs/") { try await git.run(["symbolic-ref", "HEAD", s.head]) }
        else { try await git.run(["update-ref", "--no-deref", "HEAD", s.head]) }
        // 4. Working files: move from the current tree to the saved one (adds, changes and removes files).
        try await git.run(["read-tree", now.worktree])
        _ = try? await git.run(["update-index", "-q", "--refresh"])
        try await git.run(["read-tree", "-m", "-u", now.worktree, s.worktree])
        // 5. Staging area.
        try await git.run(["read-tree", s.index])
        _ = try? await git.run(["update-index", "-q", "--refresh"])
        // 6. Local ignore rules last: while files are being put back they must keep the current rules.
        if s.localExclude != now.localExclude, let url = excludeURL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try s.localExclude.write(to: url, atomically: true, encoding: .utf8)
        }
        // 7. Stashes: rebuild the list in its original order. Every entry's commit is still in the
        //    object store (git keeps unreachable objects for weeks), and we hold all their hashes.
        if s.stashes != now.stashes {
            _ = try? await git.run(["stash", "clear"])
            for entry in s.stashes.reversed() {
                try await git.run(["stash", "store", "-m", entry.message, entry.hash])
            }
        }
    }

    static func actionName(_ key: String) -> String {
        switch key {
        case "stage": "Staging"
        case "discard": "Discard"
        case "pop": "Stash pop"
        case "stash": "Stash"
        case "drop": "Stash delete"
        case "checkout": "Checkout"
        case "branch": "New branch"
        case "delete": "Delete"
        case "merge": "Merge"
        case "rebase": "Rebase"
        case "reset": "Reset"
        case "pull": "Pull"
        case "continue": "Continue"
        case "abort": "Abort"
        case "ignore": "Ignore"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }
}
