import Foundation

/// Finds Git repositories inside a folder without spawning git: a `.git` entry marks a repo.
/// Reads the remote from `.git/config` and the last activity from file dates, so 70 repos scan in milliseconds.
struct FolderScan: Identifiable {
    struct Found: Identifiable, Hashable {
        let url: URL
        let remote: String?      // "github.com/owner/repo"
        let lastActive: Date
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        var parent: String { url.deletingLastPathComponent().lastPathComponent }
    }

    let id = UUID()
    let root: URL
    let repos: [Found]

    private static let skip: Set<String> = ["node_modules", "Pods", "DerivedData", "build", "dist", "vendor", "Library"]

    static func find(in root: URL, depth: Int = 2) -> [Found] {
        var out: [Found] = []
        walk(root, depth: depth, into: &out)
        return out.sorted { $0.lastActive > $1.lastActive }
    }

    private static func walk(_ dir: URL, depth: Int, into out: inout [Found]) {
        let fm = FileManager.default
        guard depth > 0, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !skip.contains(item.lastPathComponent) else { continue }
            let dotGit = item.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) {
                out.append(describe(item, dotGit: dotGit))
            } else {
                walk(item, depth: depth - 1, into: &out)
            }
        }
    }

    private static func describe(_ repo: URL, dotGit: URL) -> Found {
        let fm = FileManager.default
        var gitDir = dotGit
        // Worktrees and submodules: `.git` is a file pointing at the real git dir.
        if let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") {
            let path = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = URL(fileURLWithPath: path, relativeTo: repo).standardizedFileURL
        }
        var remote: String?
        if let config = try? String(contentsOf: gitDir.appendingPathComponent("config"), encoding: .utf8),
           let line = config.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("url = ") }) {
            remote = shorten(String(line.split(separator: "=", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces))
        }
        let dates = ["index", "HEAD", "FETCH_HEAD"].compactMap {
            (try? fm.attributesOfItem(atPath: gitDir.appendingPathComponent($0).path))?[.modificationDate] as? Date
        }
        return Found(url: repo.standardizedFileURL, remote: remote, lastActive: dates.max() ?? .distantPast)
    }

    /// git@github.com:owner/repo.git, https://github.com/owner/repo.git -> github.com/owner/repo
    static func shorten(_ url: String) -> String {
        var s = url
        for prefix in ["ssh://", "https://", "http://", "git://"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        if let at = s.firstIndex(of: "@"), s[..<at].allSatisfy({ $0 != "/" }) { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") { s.replaceSubrange(colon...colon, with: "/") }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }
}
