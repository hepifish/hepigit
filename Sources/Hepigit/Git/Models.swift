import Foundation

struct Commit: Identifiable, Hashable {
    let id: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let subject: String
    var short: String { String(id.prefix(7)) }
    var isMerge: Bool { parents.count > 1 }
}

struct Ref: Identifiable, Hashable {
    enum Kind: Int { case local, remote, tag }
    let id: String          // full refname
    let kind: Kind
    let name: String        // short name, e.g. main, origin/main, v1.0
    let target: String      // commit hash (peeled for annotated tags)
    let upstream: String?
    let ahead: Int
    let behind: Int
    let upstreamGone: Bool
    let isHead: Bool
    let date: Date

    /// For remotes: "origin". For others: nil.
    var remote: String? { kind == .remote ? String(name.split(separator: "/", maxSplits: 1).first ?? "") : nil }
    /// For remotes: branch without remote prefix.
    var branch: String {
        kind == .remote ? String(name.split(separator: "/", maxSplits: 1).dropFirst().first ?? "") : name
    }
}

struct FileChange: Identifiable, Hashable {
    enum Area { case staged, unstaged, commit }
    let path: String
    let oldPath: String?
    let code: Character     // M A D R C U ?
    let area: Area
    var id: String { "\(area)-\(path)" }
    var isUntracked: Bool { code == "?" }
    var isConflict: Bool { code == "U" }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? "" : d + "/"
    }
}

struct Stash: Identifiable, Hashable {
    let hash: String
    let index: Int
    let message: String
    let date: Date
    var id: String { hash }
    var ref: String { "stash@{\(index)}" }
}

struct RepoStatus: Equatable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []
    var isDirty: Bool { !staged.isEmpty || !unstaged.isEmpty }
    var changeCount: Int { Set(staged.map(\.path) + unstaged.map(\.path)).count }
    var conflicts: [FileChange] { unstaged.filter(\.isConflict) }
}

enum RepoOperation: String {
    case merge = "Merge", rebase = "Rebase", cherryPick = "Cherry-pick", revert = "Revert"
}

// MARK: Diff

struct DiffLine: Hashable {
    enum Kind { case context, add, del, note }
    let kind: Kind
    let text: String
    let oldNo: Int?
    let newNo: Int?
}

struct Hunk: Identifiable, Hashable {
    let id: Int
    let header: String
    let lines: [DiffLine]
    let patch: Data         // file header + this hunk, byte-exact, ready for `git apply`
}

struct FileDiff {
    var hunks: [Hunk] = []
    var isBinary = false
    var truncated = false
    var added = 0
    var removed = 0
}
