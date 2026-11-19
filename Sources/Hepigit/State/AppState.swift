import SwiftUI
import AppKit

struct Toast: Identifiable, Equatable {
    enum Kind { case success, error, info }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String?
}

struct Modal: Identifiable {
    struct Field { var placeholder: String; var initial: String = "" }
    let id = UUID()
    var title: String
    var message: String? = nil
    var field: Field? = nil
    var confirm: String
    var destructive = false
    var secondary: (title: String, action: () -> Void)? = nil
    var action: (String) -> Void
}

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    var repos: [RepoModel] = []
    var activeID: String?
    var modal: Modal?
    var toasts: [Toast] = []
    var scan: FolderScan?

    private var recentlyUsed: [String] = []
    private let keepLoaded = 5
    private var fetchTimer: Timer?

    var active: RepoModel? { repos.first { $0.id == activeID } }

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: "openRepos") ?? []
        repos = paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { RepoModel(url: URL(fileURLWithPath: $0)) }
        let last = UserDefaults.standard.string(forKey: "activeRepo")
        if let id = repos.first(where: { $0.id == last })?.id ?? repos.first?.id { activate(id) }

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppState.shared.active?.refresh() }
        }
        // Quiet background fetch for the visible repo only.
        fetchTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in
                guard NSApp.isActive, let repo = AppState.shared.active else { return }
                await repo.backgroundFetch()
            }
        }
    }

    // MARK: Tabs

    func activate(_ id: String) {
        guard let repo = repos.first(where: { $0.id == id }) else { return }
        active?.setWatching(false)
        activeID = id
        recentlyUsed.removeAll { $0 == id }
        recentlyUsed.insert(id, at: 0)
        repo.setWatching(true)
        if repo.isLoaded { repo.refresh() } else { Task { await repo.load() } }
        // Free memory of tabs not touched recently; they reload in ~100 ms when revisited.
        for stale in recentlyUsed.dropFirst(keepLoaded) {
            repos.first { $0.id == stale }?.unload()
        }
        persist()
    }

    func close(_ repo: RepoModel) {
        repo.setWatching(false)
        repo.unload()
        guard let idx = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos.remove(at: idx)
        recentlyUsed.removeAll { $0 == repo.id }
        if activeID == repo.id {
            activeID = nil
            if !repos.isEmpty { activate(repos[min(idx, repos.count - 1)].id) }
        }
        persist()
    }

    func selectTab(offset: Int) {
        guard let i = repos.firstIndex(where: { $0.id == activeID }), !repos.isEmpty else { return }
        activate(repos[(i + offset + repos.count) % repos.count].id)
    }

    func move(_ id: String, before target: String) {
        guard let from = repos.firstIndex(where: { $0.id == id }),
              let to = repos.firstIndex(where: { $0.id == target }), from != to else { return }
        let r = repos.remove(at: from)
        repos.insert(r, at: to)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(repos.map(\.id), forKey: "openRepos")
        UserDefaults.standard.set(activeID, forKey: "activeRepo")
    }

    // MARK: Opening

    func open(_ url: URL) async {
        let r = await Git.exec(["rev-parse", "--show-toplevel"], cwd: url)
        guard r.code == 0 else {
            await scanFolder(url)
            return
        }
        let root = URL(fileURLWithPath: r.text.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL
        if !repos.contains(where: { $0.id == root.path }) {
            repos.append(RepoModel(url: root))
        }
        activate(root.path)
    }

    /// A folder that isn't a repo: look inside it (two levels) and let the user pick.
    private func scanFolder(_ url: URL) async {
        let found = await Task.detached(priority: .userInitiated) { FolderScan.find(in: url) }.value
        switch found.count {
        case 0: toast(.info, "No repositories in \(url.lastPathComponent)", "Looked two folders deep.")
        case 1: await open(found[0].url)
        default: scan = FolderScan(root: url, repos: found)
        }
    }

    func openAll(_ urls: [URL]) {
        for u in urls where !repos.contains(where: { $0.id == u.path }) { repos.append(RepoModel(url: u)) }
        if let last = urls.last { activate(last.path) }
        if urls.count > 1 { toast(.success, "Opened \(urls.count) repositories", nil) }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose repositories, or a folder that contains them"
        guard panel.runModal() == .OK else { return }
        Task { for url in panel.urls { await open(url) } }
    }

    func showClone() {
        modal = Modal(title: "Clone repository", message: "Paste an SSH or HTTPS URL. You'll pick the folder next.",
                      field: .init(placeholder: "git@github.com:owner/repo.git"), confirm: "Choose folder") { [weak self] url in
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async { self?.clone(trimmed) }
        }
    }

    private func clone(_ remote: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Clone here"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        var name = (remote as NSString).lastPathComponent
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        let dest = parent.appendingPathComponent(name)
        toast(.info, "Cloning \(name)…", nil)
        Task {
            let r = await Git.exec(["clone", "--progress", remote, dest.path], cwd: parent)
            if r.code == 0 {
                toast(.success, "Cloned \(name)", nil)
                await open(dest)
            } else {
                toast(.error, "Clone failed", r.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: Feedback

    func toast(_ kind: Toast.Kind, _ title: String, _ detail: String?) {
        let t = Toast(kind: kind, title: title, detail: detail)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toasts.append(t) }
        let delay: Double = kind == .error ? 9 : 2.6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.dismiss(t.id) }
    }

    func dismiss(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.25)) { toasts.removeAll { $0.id == id } }
    }

    func confirm(_ title: String, _ message: String?, confirm: String, destructive: Bool = true, _ action: @escaping () -> Void) {
        modal = Modal(title: title, message: message, confirm: confirm, destructive: destructive) { _ in action() }
    }

    func ask(_ title: String, _ message: String? = nil, placeholder: String, initial: String = "", confirm: String, _ action: @escaping (String) -> Void) {
        modal = Modal(title: title, message: message, field: .init(placeholder: placeholder, initial: initial), confirm: confirm) { value in
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { action(v) }
        }
    }
}
