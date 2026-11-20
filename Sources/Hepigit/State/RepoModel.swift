import SwiftUI
import AppKit

enum Selection: Hashable {
    case wip
    case commit(String)
    case stash(String)
}

struct DiffTarget: Hashable {
    enum Source: Hashable {
        case unstaged, staged
        case commit(hash: String, parent: String?)
        case stash(ref: String, untracked: Bool)
    }
    let file: FileChange
    let source: Source
}

/// Immutable things (commit files, commit diffs) are cached by hash across tabs.
final class Box<T>: NSObject { let value: T; init(_ v: T) { value = v } }
enum Cache {
    static let files: NSCache<NSString, Box<[FileChange]>> = { let c = NSCache<NSString, Box<[FileChange]>>(); c.countLimit = 300; return c }()
    static let diffs: NSCache<NSString, Box<FileDiff>> = { let c = NSCache<NSString, Box<FileDiff>>(); c.countLimit = 120; return c }()
    static let bodies: NSCache<NSString, Box<String>> = { let c = NSCache<NSString, Box<String>>(); c.countLimit = 300; return c }()
}

@MainActor @Observable
final class RepoModel: Identifiable {
    nonisolated let url: URL
    let git: Git
    nonisolated var id: String { url.path }
    var name: String { url.lastPathComponent }

    // Loaded state
    var isLoaded = false
    var isLoading = false
    var commits: [Commit] = []
    var rows: [GraphRow] = []
    var maxLanes = 1
    var indexByHash: [String: Int] = [:]
    var refs: [Ref] = []
    var refsByTarget: [String: [Ref]] = [:]
    var remotes: [String] = []
    var stashes: [Stash] = []
    var status = RepoStatus()
    var headHash: String?
    var operation: RepoOperation?
    var hasMore = false

    // UI state
    var selection: Selection = .wip
    var diffTarget: DiffTarget?
    var scrollRequest: String?
    var busy: Set<String> = []
    var undoStack: [UndoEntry] = []
    var searchQuery = "" { didSet { updateSearch() } }
    var searchHits: Set<String> = []
    var searchOrder: [String] = []
    var searchCursor = 0
    var lastSuccess: String?

    @ObservationIgnored private var logLimit = 2000
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var watcher: RepoWatcher?
    @ObservationIgnored private(set) var gitDir: URL?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefs = false

    init(url: URL) {
        self.url = url
        self.git = Git(root: url)
    }

    var locals: [Ref] { refs.filter { $0.kind == .local } }
    var tags: [Ref] { refs.filter { $0.kind == .tag }.sorted { $0.date > $1.date } }
    func remoteBranches(_ remote: String) -> [Ref] { refs.filter { $0.kind == .remote && $0.remote == remote } }
    var currentBranch: Ref? { refs.first { $0.kind == .local && $0.isHead } }

    // MARK: Lifecycle

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        if gitDir == nil, let d = try? await git.text(["rev-parse", "--absolute-git-dir"]) {
            gitDir = URL(fileURLWithPath: d.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        await reload(force: true)
        isLoaded = true
        isLoading = false
    }

    func unload() {
        guard isLoaded else { return }
        commits = []; rows = []; indexByHash = [:]; refsByTarget = [:]
        diffTarget = nil
        signature = ""
        isLoaded = false
    }

    func setWatching(_ on: Bool) {
        if on, watcher == nil {
            watcher = RepoWatcher(root: url) { [weak self] change in self?.scheduleRefresh(refs: change == .refs) }
        } else if !on {
            watcher?.stop(); watcher = nil
        }
    }

    func refresh() { scheduleRefresh(refs: true) }

    /// Coalesces bursts of file events into one refresh.
    private func scheduleRefresh(refs: Bool) {
        pendingRefs = pendingRefs || refs
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.isLoaded, self.busy.isEmpty else { return }
            let full = self.pendingRefs
            self.pendingRefs = false
            if full { await self.reload(force: false) } else { await self.refreshStatus() }
        }
    }

    /// Refs + HEAD + stashes + status in parallel; the log is re-read only if refs moved.
    func reload(force: Bool) async {
        async let refData = try? git.run(["for-each-ref", Parse.refFormat, "refs/heads", "refs/remotes", "refs/tags"])
        async let headText = try? git.text(["rev-parse", "-q", "--verify", "HEAD"])
        async let stashData = try? git.run(["stash", "list", "--format=%H%x1f%gs%x1f%at%x1e"])
        async let remoteText = try? git.text(["remote"])
        async let statusData = try? git.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"])

        let (r, h, s, rm, st) = await (refData ?? Data(), headText ?? "", stashData ?? Data(), remoteText ?? "", statusData)
        let head = h.trimmingCharacters(in: .whitespacesAndNewlines)
        let sig = "\(r.hashValue)|\(head)|\(s.hashValue)"

        if force || sig != signature || commits.isEmpty {
            signature = sig
            let parsedRefs = Parse.refs(r)
            refs = parsedRefs
            refsByTarget = Dictionary(grouping: parsedRefs, by: \.target)
            headHash = head.isEmpty ? nil : head
            stashes = Parse.stashes(s)
            remotes = rm.split(separator: "\n").map(String.init)
            await loadLog()
        }
        if let st { applyStatus(Parse.status(st)) }
        detectOperation()
    }

    func refreshStatus() async {
        if let st = try? await git.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]) {
            applyStatus(Parse.status(st))
        }
        detectOperation()
    }

    private func applyStatus(_ s: RepoStatus) {
        guard s != status else { return }
        withAnimation(.snappy(duration: 0.25)) { status = s }
        if case .unstaged = diffTarget?.source, !s.unstaged.contains(where: { $0.path == diffTarget?.file.path }) { diffTarget = nil }
        if case .staged = diffTarget?.source, !s.staged.contains(where: { $0.path == diffTarget?.file.path }) { diffTarget = nil }
    }

    private func loadLog() async {
        let limit = logLimit
        let data = (try? await git.run(["log", "--exclude=refs/stash", "--all", "--date-order", "-n", "\(limit + 1)", Parse.logFormat])) ?? Data()
        let (list, layout, index, more) = await Task.detached(priority: .userInitiated) { () -> ([Commit], [GraphRow], [String: Int], Bool) in
            var list = Parse.commits(data)
            let more = list.count > limit
            if more { list.removeLast(list.count - limit) }
            let layout = GraphLayout.compute(list)
            var index: [String: Int] = [:]
            index.reserveCapacity(list.count)
            for (i, c) in list.enumerated() { index[c.id] = i }
            return (list, layout, index, more)
        }.value
        hasMore = more
        commits = list
        rows = layout
        indexByHash = index
        maxLanes = max(1, layout.lazy.map(\.width).max() ?? 1)
        if case .commit(let h) = selection, index[h] == nil { selection = .wip }
        if case .stash(let h) = selection, !stashes.contains(where: { $0.hash == h }) { selection = .wip }
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        logLimit += 3000
        isLoading = true
        Task { await loadLog(); isLoading = false }
    }

    private func detectOperation() {
        guard let d = gitDir else { return }
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: d.appendingPathComponent(p).path) }
        let op: RepoOperation? =
            has("rebase-merge") || has("rebase-apply") ? .rebase :
            has("MERGE_HEAD") ? .merge :
            has("CHERRY_PICK_HEAD") ? .cherryPick :
            has("REVERT_HEAD") ? .revert : nil
        if op != operation { withAnimation(.snappy) { operation = op } }
    }

    // MARK: Selection

    func select(_ s: Selection) {
        if selection != s { diffTarget = nil }
        selection = s
    }

    func reveal(_ hash: String) {
        guard indexByHash[hash] != nil else {
            AppState.shared.toast(.info, "Commit not in loaded history", "Scroll to the bottom to load more.")
            return
        }
        select(.commit(hash))
        scrollRequest = hash
    }

    func moveSelection(_ delta: Int) {
        let current: Int
        switch selection {
        case .commit(let h): current = indexByHash[h] ?? -1
        default: current = -1
        }
        let next = max(0, min(commits.count - 1, current + delta))
        guard commits.indices.contains(next) else { return }
        if current == 0 && delta < 0 && status.isDirty { select(.wip); scrollRequest = "wip"; return }
        select(.commit(commits[next].id))
        scrollRequest = commits[next].id
    }

    // MARK: Search

    private func updateSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = []; searchOrder = []; return }
        let lower = q.lowercased()
        searchOrder = commits.lazy.filter {
            $0.id.hasPrefix(lower) || $0.subject.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q)
        }.map(\.id)
        searchHits = Set(searchOrder)
        searchCursor = 0
        if let first = searchOrder.first { select(.commit(first)); scrollRequest = first }
    }

    func nextSearchHit(_ delta: Int = 1) {
        guard !searchOrder.isEmpty else { return }
        searchCursor = (searchCursor + delta + searchOrder.count) % searchOrder.count
        let id = searchOrder[searchCursor]
        select(.commit(id)); scrollRequest = id
    }

    // MARK: Running actions

    /// Runs a git action with busy state, a toast on failure, a short success pulse and a refresh.
    /// Every local change records a before/after snapshot, so it can be undone (see Undo.swift).
    func perform(_ key: String, success: String? = nil, _ work: @escaping () async throws -> Void) {
        guard !busy.contains(key) else { return }
        withAnimation(.snappy) { _ = busy.insert(key) }
        Task {
            let before = key == "undo" ? nil : await snapshot()
            do {
                try await work()
                let undoable = await recordUndo(before, label: success ?? Self.actionName(key))
                if let success {
                    AppState.shared.toast(.success, success, nil, action: undoable ? ("Undo", { [weak self] in self?.undo() }) : nil)
                }
                withAnimation(.snappy) { lastSuccess = key }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    if self?.lastSuccess == key { withAnimation(.easeOut) { self?.lastSuccess = nil } }
                }
            } catch {
                // A failed pop or merge can still leave conflicts behind: make that undoable too.
                let undoable = await recordUndo(before, label: Self.actionName(key))
                AppState.shared.toast(.error, Self.failureTitle(key), error.localizedDescription,
                                      action: undoable ? ("Undo", { [weak self] in self?.undo() }) : nil)
            }
            withAnimation(.snappy) { _ = busy.remove(key) }
            await reload(force: false)
        }
    }

    func run(_ key: String, _ args: [String], success: String? = nil) {
        perform(key, success: success) { [git] in try await git.run(args) }
    }

    private static func failureTitle(_ key: String) -> String {
        let k = key.split(separator: ":").first.map(String.init) ?? key
        return "\(k.prefix(1).uppercased())\(k.dropFirst()) failed"
    }

    // MARK: Remote

    func fetch() { run("fetch", ["fetch", "--all", "--prune", "--tags"], success: "Fetched") }

    func backgroundFetch() async {
        guard busy.isEmpty else { return }
        _ = await Git.exec(["fetch", "--all", "--prune", "--quiet"], cwd: url)
        await reload(force: false)
    }

    enum PullMode: String { case merge = "--no-rebase", ffOnly = "--ff-only", rebase = "--rebase" }

    func pull(_ mode: PullMode = .merge) {
        guard let branch = status.branch else { return noBranch() }
        guard status.upstream != nil else {
            AppState.shared.toast(.info, "\(branch) has no upstream yet", "Push it first to create one.")
            return
        }
        run("pull", ["pull", mode.rawValue], success: "Pulled \(branch)")
    }

    func push(force: Bool = false) {
        guard let branch = status.branch else { return noBranch() }
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        if status.upstream == nil {
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            args += ["-u", remote, branch]
        }
        run("push", args, success: force ? "Force pushed \(branch)" : "Pushed \(branch)")
    }

    func confirmForcePush() {
        guard let branch = status.branch else { return noBranch() }
        AppState.shared.confirm("Force push \(branch)?",
            "Overwrites the remote branch with your local history. Uses --force-with-lease, so it stops if someone else pushed meanwhile.",
            confirm: "Force push") { [weak self] in self?.push(force: true) }
    }

    private func noBranch() {
        AppState.shared.toast(.info, "You're on a detached HEAD", "Create a branch here first.")
    }

    // MARK: Branches

    func checkout(_ ref: Ref) {
        switch ref.kind {
        case .local:
            run("checkout", ["switch", ref.name], success: "Switched to \(ref.name)")
        case .remote:
            if locals.contains(where: { $0.name == ref.branch }) {
                run("checkout", ["switch", ref.branch], success: "Switched to \(ref.branch)")
            } else {
                run("checkout", ["switch", "--track", ref.name], success: "Switched to \(ref.branch)")
            }
        case .tag:
            checkoutDetached(ref.target)
        }
    }

    func checkoutDetached(_ hash: String) {
        run("checkout", ["switch", "--detach", hash], success: "Checked out \(hash.prefix(7))")
    }

    func newBranch(at hash: String? = nil) {
        AppState.shared.ask("New branch", hash.map { "Starts at \($0.prefix(7))." } ?? "Starts at the current commit.",
                            placeholder: "feature/name", confirm: "Create and switch") { [weak self] name in
            var args = ["switch", "-c", name]
            if let hash { args.append(hash) }
            self?.run("branch", args, success: "Created \(name)")
        }
    }

    func merge(_ ref: Ref) {
        let into = status.branch ?? "HEAD"
        run("merge", ["merge", ref.name], success: "Merged \(ref.name) into \(into)")
    }

    func rebase(onto ref: Ref) {
        let current = status.branch ?? "HEAD"
        AppState.shared.confirm("Rebase \(current) onto \(ref.name)?", "Rewrites the commits of \(current). Pushed commits will need a force push.",
                                confirm: "Rebase", destructive: false) { [weak self] in
            self?.run("rebase", ["rebase", ref.name], success: "Rebased onto \(ref.name)")
        }
    }

    func rename(_ ref: Ref) {
        AppState.shared.ask("Rename branch", nil, placeholder: ref.name, initial: ref.name, confirm: "Rename") { [weak self] name in
            guard name != ref.name else { return }
            self?.run("branch", ["branch", "-m", ref.name, name], success: "Renamed to \(name)")
        }
    }

    func delete(_ ref: Ref) {
        switch ref.kind {
        case .local:
            AppState.shared.confirm("Delete \(ref.name)?", "Deletes the local branch only. The remote stays.", confirm: "Delete") { [weak self] in
                guard let self else { return }
                self.perform("delete", success: "Deleted \(ref.name)") { [git] in
                    do { try await git.run(["branch", "-d", ref.name]) }
                    catch let e as GitError where e.message.contains("not fully merged") {
                        await MainActor.run {
                            AppState.shared.confirm("\(ref.name) isn't merged", "Its commits will only survive in the reflog.", confirm: "Delete anyway") {
                                self.run("delete", ["branch", "-D", ref.name], success: "Deleted \(ref.name)")
                            }
                        }
                        throw GitError(message: "Not merged; waiting for your confirmation.")
                    }
                }
            }
        case .remote:
            AppState.shared.confirm("Delete \(ref.name) on \(ref.remote ?? "remote")?", "Removes the branch from the server for everyone.", confirm: "Delete remote branch") { [weak self] in
                self?.run("delete", ["push", ref.remote ?? "origin", "--delete", ref.branch], success: "Deleted \(ref.name)")
            }
        case .tag:
            AppState.shared.confirm("Delete tag \(ref.name)?", "Deletes the local tag. Pushed copies stay on remotes.", confirm: "Delete tag") { [weak self] in
                self?.run("delete", ["tag", "-d", ref.name], success: "Deleted tag \(ref.name)")
            }
        }
    }

    func pushBranch(_ ref: Ref) {
        let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
        run("push", ["push", "-u", remote, ref.name], success: "Pushed \(ref.name)")
    }

    func pushTag(_ ref: Ref) {
        let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
        run("push", ["push", remote, "refs/tags/\(ref.name)"], success: "Pushed tag \(ref.name)")
    }

    func fastForward(_ ref: Ref) {
        guard let up = ref.upstream else { return }
        if ref.isHead { pull(.ffOnly); return }
        let parts = up.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        run("pull", ["fetch", parts[0], "\(parts[1]):\(ref.name)"], success: "Fast-forwarded \(ref.name)")
    }

    // MARK: Commits

    func newTag(at hash: String) {
        AppState.shared.ask("New tag", "On \(hash.prefix(7)).", placeholder: "v1.0.0", confirm: "Create tag") { [weak self] name in
            self?.run("tag", ["tag", name, hash], success: "Tagged \(name)")
        }
    }

    func cherryPick(_ hash: String) {
        var args = ["cherry-pick", hash]
        if commits.first(where: { $0.id == hash })?.isMerge == true { args.insert(contentsOf: ["-m", "1"], at: 1) }
        run("cherry-pick", args, success: "Cherry-picked \(hash.prefix(7))")
    }

    func revert(_ hash: String) {
        let c = commits.first { $0.id == hash }
        var args = ["revert", "--no-edit", hash]
        if c?.isMerge == true { args.insert(contentsOf: ["-m", "1"], at: 1) }
        run("revert", args, success: "Reverted \(hash.prefix(7))")
    }

    enum ResetMode: String, CaseIterable { case soft, mixed, hard }

    func reset(to hash: String, _ mode: ResetMode) {
        let branch = status.branch ?? "HEAD"
        let detail: String = switch mode {
        case .soft: "Keeps all changes staged."
        case .mixed: "Keeps all changes, unstaged."
        case .hard: "Discards every uncommitted change. This can't be undone."
        }
        AppState.shared.confirm("Reset \(branch) to \(hash.prefix(7)) (\(mode.rawValue))?", detail,
                                confirm: "Reset \(mode.rawValue)", destructive: mode == .hard) { [weak self] in
            self?.run("reset", ["reset", "--\(mode.rawValue)", hash], success: "Reset to \(hash.prefix(7))")
        }
    }

    func undoLastCommit() {
        guard let head = commits.first(where: { $0.id == headHash }), !head.parents.isEmpty else { return }
        AppState.shared.confirm("Undo last commit?", "“\(head.subject)” goes back to your staged changes.", confirm: "Undo commit", destructive: false) { [weak self] in
            self?.run("reset", ["reset", "--soft", "HEAD~1"], success: "Commit undone")
        }
    }

    func continueOperation() {
        guard let op = operation else { return }
        let cmd = op == .rebase ? "rebase" : op == .merge ? "merge" : op == .cherryPick ? "cherry-pick" : "revert"
        perform("continue", success: "\(op.rawValue) continued") { [git] in
            try await git.run(["-c", "core.editor=true", cmd, "--continue"])
        }
    }

    func abortOperation() {
        guard let op = operation else { return }
        let cmd = op == .rebase ? "rebase" : op == .merge ? "merge" : op == .cherryPick ? "cherry-pick" : "revert"
        AppState.shared.confirm("Abort \(op.rawValue.lowercased())?", "Returns everything to how it was before.", confirm: "Abort") { [weak self] in
            self?.run("abort", [cmd, "--abort"], success: "\(op.rawValue) aborted")
        }
    }

    // MARK: Conflicts

    /// The conflicted file's text and which sides git still has for it (a side is missing when it deleted the file).
    func conflict(_ f: FileChange) async -> ConflictState {
        let stages = (try? await git.text(["ls-files", "-u", "-z", "--", f.path])) ?? ""
        let nums = Set(stages.split(separator: "\0").compactMap { $0.split(separator: " ").dropFirst(2).first?.first })
        let data = (try? Data(contentsOf: url.appendingPathComponent(f.path))) ?? Data()
        let text = data.contains(0) ? nil : String(data: data, encoding: .utf8)
        return ConflictState(doc: text.flatMap(ConflictDoc.parse), text: text, hasCurrent: nums.contains("2"), hasIncoming: nums.contains("3"))
    }

    /// Replaces one conflict block in the file with the chosen side. Staging stays a separate, visible step.
    func resolveBlock(_ f: FileChange, _ index: Int, _ choice: ConflictDoc.Choice) {
        let file = url.appendingPathComponent(f.path)
        perform("resolve") {
            let data = try Data(contentsOf: file)
            guard let text = String(data: data, encoding: .utf8), let doc = ConflictDoc.parse(text),
                  index < doc.blocks.count else { throw GitError(message: "The file changed on disk. Reopen it and try again.") }
            try Data(doc.resolving(index, choice).utf8).write(to: file, options: .atomic)
        }
    }

    /// Takes one side for the whole file and marks it resolved. A side that deleted the file deletes it here too.
    func resolveFile(_ f: FileChange, current: Bool, sideExists: Bool) {
        let side = current ? "--ours" : "--theirs"
        perform("resolve", success: "Resolved \(f.fileName)") { [git] in
            if sideExists {
                try await git.run(["checkout", side, "--", f.path])
                try await git.run(["add", "--", f.path])
            } else {
                try await git.run(["rm", "-q", "--", f.path])
            }
        }
    }

    /// Brings the conflict markers back, discarding picks made in this file.
    func restartConflict(_ f: FileChange) {
        AppState.shared.confirm("Start over on \(f.fileName)?", "The conflict markers come back and the picks you made in this file are discarded.",
                                confirm: "Start over") { [weak self] in
            self?.run("resolve", ["checkout", "-m", "--", f.path])
        }
    }

    // MARK: Working tree

    func stage(_ f: FileChange) { run("stage", ["add", "-A", "--", f.path]) }
    func unstage(_ f: FileChange) {
        var paths = [f.path]
        if let o = f.oldPath { paths.append(o) }
        run("stage", headHash == nil ? ["rm", "--cached", "-q", "--"] + paths : ["restore", "--staged", "--"] + paths)
    }
    func stageAll() { run("stage", ["add", "-A"]) }
    func unstageAll() { run("stage", headHash == nil ? ["rm", "-r", "--cached", "-q", "."] : ["reset", "-q"]) }

    func discard(_ f: FileChange) {
        AppState.shared.confirm("Discard changes in \(f.fileName)?", "This can't be undone.", confirm: "Discard") { [weak self] in
            guard let self else { return }
            if f.isUntracked {
                self.run("discard", ["clean", "-fdq", "--", f.path])
            } else if f.area == .staged && f.code == "A" {
                self.run("discard", ["rm", "-fq", "--", f.path])
            } else if f.area == .staged {
                self.run("discard", ["restore", "--source=HEAD", "--staged", "--worktree", "--", f.path])
            } else {
                self.run("discard", ["restore", "--worktree", "--", f.path])
            }
        }
    }

    func discardAll() {
        AppState.shared.confirm("Discard all changes?", "Every uncommitted change and untracked file goes away. This can't be undone.", confirm: "Discard all") { [weak self] in
            guard let git = self?.git else { return }
            self?.perform("discard", success: "Working tree clean") {
                try await git.run(["reset", "--hard", "-q"])
                try await git.run(["clean", "-fdq"])
            }
        }
    }

    enum HunkAction { case stage, unstage, discard }

    func apply(_ hunk: Hunk, _ action: HunkAction) {
        let args: [String] = switch action {
        case .stage: ["apply", "--cached", "--whitespace=nowarn", "-"]
        case .unstage: ["apply", "--cached", "--reverse", "--whitespace=nowarn", "-"]
        case .discard: ["apply", "--reverse", "--whitespace=nowarn", "-"]
        }
        let git = self.git
        let doIt: () -> Void = { [weak self] in
            self?.perform("stage") { try await git.run(args, input: hunk.patch) }
        }
        if action == .discard {
            AppState.shared.confirm("Discard this hunk?", "This can't be undone.", confirm: "Discard hunk", doIt)
        } else { doIt() }
    }

    func commit(summary: String, body: String, amend: Bool) async -> Bool {
        var message = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { message += "\n\n" + b }
        var args = ["commit", "-F", "-"]
        if amend { args.append("--amend") }
        withAnimation(.snappy) { _ = busy.insert("commit") }
        defer { withAnimation(.snappy) { _ = busy.remove("commit") } }
        let before = await snapshot()
        do {
            try await git.run(args, input: Data(message.utf8))
            let undoable = await recordUndo(before, label: amend ? "Amend" : "Commit “\(summary)”")
            await reload(force: false)
            AppState.shared.toast(.success, amend ? "Commit amended" : "Committed", summary,
                                  action: undoable ? ("Undo", { [weak self] in self?.undo() }) : nil)
            return true
        } catch {
            AppState.shared.toast(.error, "Commit failed", error.localizedDescription)
            await reload(force: false)
            return false
        }
    }

    func lastCommitMessage() async -> (String, String) {
        let text = (try? await git.text(["log", "-1", "--format=%B"])) ?? ""
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let summary = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, body)
    }

    // MARK: Ignore

    enum IgnoreScope { case file, ext(String), folder(String) }

    /// New and untracked files can simply be ignored; tracked ones must also leave the index,
    /// or git keeps tracking them despite the rule.
    func isTracked(_ f: FileChange) -> Bool { !f.isUntracked && !(f.code == "A") }

    func ignore(_ f: FileChange, _ scope: IgnoreScope, localOnly: Bool = false) {
        let pattern: String
        let what: String
        switch scope {
        case .file: pattern = "/" + Self.escapeIgnore(f.path); what = f.fileName
        case .ext(let e): pattern = "*." + Self.escapeIgnore(e); what = "*.\(e) files"
        case .folder(let d): pattern = "/" + Self.escapeIgnore(d); what = d
        }
        let untrack = isTracked(f) || f.code == "A"
        let doIt = { [weak self] in
            guard let self else { return }
            let target = localOnly ? self.excludeURL : self.url.appendingPathComponent(".gitignore")
            self.perform("ignore", success: localOnly ? "Ignored \(what) on this Mac" : "Ignored \(what)") { [git] in
                guard let target else { throw GitError(message: "Couldn't find the repository's git folder.") }
                try Self.appendIgnore(pattern, to: target)
                if untrack { try await git.run(["rm", "-r", "-q", "--cached", "--", f.path]) }
            }
        }
        if isTracked(f) {
            AppState.shared.confirm("Stop tracking \(f.fileName)?",
                "The file stays on your disk, but the next commit removes it from the repository for everyone, and git ignores it from then on.",
                confirm: "Stop tracking and ignore", destructive: false, doIt)
        } else {
            doIt()
        }
    }

    private static func appendIgnore(_ pattern: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(pattern) else { return }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += pattern + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Escapes characters that .gitignore would read as syntax, so the rule matches the name literally.
    static func escapeIgnore(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\*?[".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        if let first = out.first, first == "#" || first == "!" { out = "\\" + out }
        if out.hasSuffix(" ") { out = String(out.dropLast()) + "\\ " }
        return out
    }

    // MARK: Stashes

    func stash() {
        guard status.isDirty else {
            AppState.shared.toast(.info, "Nothing to stash", "The working tree is clean.")
            return
        }
        // A message is optional here, so build the modal directly instead of `ask`.
        AppState.shared.modal = Modal(title: "Stash changes", message: "Includes untracked files. The name is optional.",
                                      field: .init(placeholder: "What are you parking?"), confirm: "Stash") { [weak self] msg in
            let m = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.run("stash", ["stash", "push", "--include-untracked"] + (m.isEmpty ? [] : ["-m", m]), success: "Changes stashed")
        }
    }

    func popStash(_ s: Stash? = nil) {
        guard let s = s ?? stashes.first else {
            AppState.shared.toast(.info, "No stashes", nil); return
        }
        run("pop", ["stash", "pop", "--index", s.ref], success: "Stash applied and removed")
    }

    func applyStash(_ s: Stash) { run("pop", ["stash", "apply", "--index", s.ref], success: "Stash applied") }

    func dropStash(_ s: Stash) {
        AppState.shared.confirm("Delete stash?", "“\(s.message)” will be gone.", confirm: "Delete stash") { [weak self] in
            self?.run("drop", ["stash", "drop", s.ref], success: "Stash deleted")
        }
    }

    // MARK: Reading

    func files(of hash: String) async -> [FileChange] {
        if let c = Cache.files.object(forKey: hash as NSString) { return c.value }
        let commit = commits.first { $0.id == hash }
        let args: [String] = if let p = commit?.parents.first {
            ["diff", "--no-ext-diff", "-M", "--name-status", "-z", p, hash]
        } else {
            ["diff-tree", "--no-commit-id", "--root", "-r", "-M", "--name-status", "-z", hash]
        }
        let list = Parse.nameStatus((try? await git.run(args)) ?? Data())
        Cache.files.setObject(Box(list), forKey: hash as NSString)
        return list
    }

    func body(of hash: String) async -> String {
        if let c = Cache.bodies.object(forKey: hash as NSString) { return c.value }
        let text = (try? await git.text(["show", "-s", "--format=%b", hash])) ?? ""
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Cache.bodies.setObject(Box(body), forKey: hash as NSString)
        return body
    }

    func files(of s: Stash) async -> [FileChange] {
        let key = "stash-\(s.hash)" as NSString
        if let c = Cache.files.object(forKey: key) { return c.value }
        var list = Parse.nameStatus((try? await git.run(["diff", "--no-ext-diff", "-M", "--name-status", "-z", "\(s.hash)^1", s.hash])) ?? Data())
        if let u = try? await git.run(["ls-tree", "-r", "--name-only", "-z", "\(s.hash)^3"]) {
            list += u.split(separator: 0).map { FileChange(path: String(decoding: $0, as: UTF8.self), oldPath: nil, code: "?", area: .commit) }
        }
        Cache.files.setObject(Box(list), forKey: key)
        return list
    }

    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    func diff(_ t: DiffTarget) async -> FileDiff {
        let base = ["diff", "--no-ext-diff", "--no-color", "-M", "--src-prefix=a/", "--dst-prefix=b/"]
        var paths = ["--", t.file.path]
        if let o = t.file.oldPath { paths.append(o) }
        var cacheKey: NSString?
        let args: [String]
        var ok: Set<Int32> = [0]
        switch t.source {
        case .unstaged:
            if t.file.isUntracked { args = base + ["--no-index", "--", "/dev/null", t.file.path]; ok = [0, 1] }
            else { args = base + paths }
        case .staged:
            args = base + ["--cached"] + paths
        case .commit(let hash, let parent):
            cacheKey = "\(hash)-\(t.file.path)" as NSString
            args = base + [parent ?? Self.emptyTree, hash] + paths
        case .stash(let ref, let untracked):
            cacheKey = "\(ref)-\(t.file.path)" as NSString
            args = untracked ? base + [Self.emptyTree, "\(ref)^3"] + paths : base + ["\(ref)^1", ref] + paths
        }
        if let k = cacheKey, let c = Cache.diffs.object(forKey: k) { return c.value }
        let raw = (try? await git.run(args, okCodes: ok)) ?? Data()
        let renamed: String? = t.file.oldPath == nil ? nil : t.file.path
        let d = await Task.detached { Parse.diff(raw, path: renamed) }.value
        if let k = cacheKey { Cache.diffs.setObject(Box(d), forKey: k) }
        return d
    }

    // MARK: Finder / editor

    func reveal(path: String) { NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent(path)]) }
    func openFile(_ path: String) { NSWorkspace.shared.open(url.appendingPathComponent(path)) }
    func openInFinder() { NSWorkspace.shared.open(url) }
    func openInTerminal() {
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
    }
}
