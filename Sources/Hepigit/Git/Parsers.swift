import Foundation

enum Parse {
    static let logFormat = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1e"

    static func commits(_ data: Data) -> [Commit] {
        var result: [Commit] = []
        result.reserveCapacity(data.count / 120)
        for record in data.split(separator: 0x1e) {
            let f = record.split(separator: 0x1f, omittingEmptySubsequences: false)
            guard f.count >= 6 else { continue }
            let hash = str(f[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { continue }
            let parents = str(f[1]).split(separator: " ").map(String.init)
            result.append(Commit(
                id: hash, parents: parents, author: str(f[2]), email: str(f[3]),
                date: Date(timeIntervalSince1970: Double(str(f[4])) ?? 0),
                subject: str(f[5])))
        }
        return result
    }

    static let refFormat = "--format=%(refname)%1f%(objectname)%1f%(*objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)%1f%(creatordate:unix)"

    static func refs(_ data: Data) -> [Ref] {
        var refs: [Ref] = []
        for line in data.split(separator: 0x0a) {
            let f = line.split(separator: 0x1f, omittingEmptySubsequences: false).map(str)
            guard f.count >= 7 else { continue }
            let full = f[0]
            let kind: Ref.Kind
            let name: String
            if full.hasPrefix("refs/heads/") { kind = .local; name = String(full.dropFirst(11)) }
            else if full.hasPrefix("refs/remotes/") {
                kind = .remote; name = String(full.dropFirst(13))
                if name.hasSuffix("/HEAD") { continue }
            } else if full.hasPrefix("refs/tags/") { kind = .tag; name = String(full.dropFirst(10)) }
            else { continue }
            let track = f[4]
            refs.append(Ref(
                id: full, kind: kind, name: name,
                target: f[2].isEmpty ? f[1] : f[2],
                upstream: f[3].isEmpty ? nil : f[3],
                ahead: number(after: "ahead ", in: track),
                behind: number(after: "behind ", in: track),
                upstreamGone: track == "gone",
                isHead: f[5] == "*",
                date: Date(timeIntervalSince1970: Double(f[6]) ?? 0)))
        }
        return refs
    }

    static func stashes(_ data: Data) -> [Stash] {
        data.split(separator: 0x1e).enumerated().compactMap { i, rec in
            let f = rec.split(separator: 0x1f, omittingEmptySubsequences: false).map(str)
            guard f.count >= 3, !f[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var msg = f[1]
            // "WIP on main: abc123 subject" / "On main: message" -> keep the human part
            if let r = msg.range(of: ": "), msg.hasPrefix("On ") { msg = String(msg[r.upperBound...]) }
            if msg.trimmingCharacters(in: .whitespaces).isEmpty { msg = "Untitled stash" }
            return Stash(hash: f[0].trimmingCharacters(in: .whitespacesAndNewlines), index: i, message: msg,
                         date: Date(timeIntervalSince1970: Double(f[2]) ?? 0))
        }
    }

    /// `git status --porcelain=v2 -z --branch`
    static func status(_ data: Data) -> RepoStatus {
        var s = RepoStatus()
        let parts = data.split(separator: 0, omittingEmptySubsequences: false).map(str)
        var i = 0
        while i < parts.count {
            let line = parts[i]; i += 1
            guard let kind = line.first else { continue }
            switch kind {
            case "#":
                if line.hasPrefix("# branch.head ") {
                    let b = String(line.dropFirst(14)); s.branch = b == "(detached)" ? nil : b
                } else if line.hasPrefix("# branch.upstream ") {
                    s.upstream = String(line.dropFirst(18))
                } else if line.hasPrefix("# branch.ab ") {
                    let ab = line.dropFirst(12).split(separator: " ")
                    if ab.count == 2 { s.ahead = abs(Int(ab[0]) ?? 0); s.behind = abs(Int(ab[1]) ?? 0) }
                }
            case "1", "2":
                let fields = line.split(separator: " ", maxSplits: kind == "1" ? 8 : 9, omittingEmptySubsequences: false)
                guard fields.count >= (kind == "1" ? 9 : 10) else { continue }
                let xy = Array(fields[1])
                let path = String(fields[kind == "1" ? 8 : 9])
                var old: String? = nil
                if kind == "2", i < parts.count { old = parts[i]; i += 1 }
                if xy[0] != "." { s.staged.append(FileChange(path: path, oldPath: old, code: xy[0], area: .staged)) }
                if xy[1] != "." { s.unstaged.append(FileChange(path: path, oldPath: nil, code: xy[1], area: .unstaged)) }
            case "u":
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if let p = fields.last { s.unstaged.append(FileChange(path: String(p), oldPath: nil, code: "U", area: .unstaged)) }
            case "?":
                s.unstaged.append(FileChange(path: String(line.dropFirst(2)), oldPath: nil, code: "?", area: .unstaged))
            default: break
            }
        }
        s.unstaged.sort { ($0.isConflict ? 0 : 1, $0.path) < ($1.isConflict ? 0 : 1, $1.path) }
        s.staged.sort { $0.path < $1.path }
        return s
    }

    /// `--name-status -z` output
    static func nameStatus(_ data: Data) -> [FileChange] {
        let parts = data.split(separator: 0, omittingEmptySubsequences: true).map(str)
        var out: [FileChange] = []
        var i = 0
        while i < parts.count {
            let st = parts[i]; i += 1
            guard let c = st.first, i < parts.count else { break }
            if c == "R" || c == "C", i + 1 < parts.count {
                out.append(FileChange(path: parts[i + 1], oldPath: parts[i], code: c, area: .commit)); i += 2
            } else {
                out.append(FileChange(path: parts[i], oldPath: nil, code: c, area: .commit)); i += 1
            }
        }
        return out
    }

    static let maxDiffLines = 6000

    /// Parses a unified diff from raw bytes. Patches keep the original bytes (CRLF, Latin-1, ...),
    /// only the display text is decoded. For a rename, `path` replaces the rename header so a single
    /// hunk can be applied or reversed without touching the rename itself.
    static func diff(_ data: Data, path: String? = nil) -> FileDiff {
        var d = FileDiff()
        var header: [Data] = []
        var hunkHeader = Data()
        var hunkRaw: [Data] = []
        var lines: [DiffLine] = []
        var oldNo = 0, newNo = 0, total = 0
        var inHunk = false
        let nl = Data([0x0a])

        func text(_ b: Data.SubSequence) -> String {
            var s = String(decoding: b, as: UTF8.self)
            if s.hasSuffix("\r") { s.removeLast() }
            return s
        }
        func flush() {
            guard inHunk else { return }
            var patch = Data()
            let head: [Data] = path.map { p in ["diff --git a/\(p) b/\(p)", "--- a/\(p)", "+++ b/\(p)"].map { Data($0.utf8) } } ?? header
            for part in head + [hunkHeader] + hunkRaw { patch.append(part); patch.append(nl) }
            d.hunks.append(Hunk(id: d.hunks.count, header: text(hunkHeader[...]), lines: lines, patch: patch))
            lines = []; hunkRaw = []; inHunk = false
        }

        var rows = data.split(separator: 0x0a, omittingEmptySubsequences: false)
        if rows.last?.isEmpty == true { rows.removeLast() }
        for raw in rows {
            let first = raw.first
            if raw.starts(with: [0x40, 0x40]) {            // "@@"
                flush()
                inHunk = true
                hunkHeader = Data(raw)
                let nums = text(raw).split(separator: " ")
                if nums.count > 2 {
                    oldNo = Int(nums[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newNo = Int(nums[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                continue
            }
            if !inHunk || raw.starts(with: Array("diff --git".utf8)) {
                if inHunk { flush(); header = [] }
                let t = text(raw)
                if t.hasPrefix("Binary files") || t.hasPrefix("GIT binary patch") { d.isBinary = true }
                if t.hasPrefix("diff --git") { header = [] }
                if !raw.isEmpty { header.append(Data(raw)) }
                continue
            }
            total += 1
            if total > maxDiffLines { d.truncated = true; break }
            let body = text(raw.dropFirst())
            switch first {
            case 0x2b: lines.append(DiffLine(kind: .add, text: body, oldNo: nil, newNo: newNo)); newNo += 1; d.added += 1
            case 0x2d: lines.append(DiffLine(kind: .del, text: body, oldNo: oldNo, newNo: nil)); oldNo += 1; d.removed += 1
            case 0x5c: lines.append(DiffLine(kind: .note, text: text(raw.dropFirst(2)), oldNo: nil, newNo: nil))
            case 0x20: lines.append(DiffLine(kind: .context, text: body, oldNo: oldNo, newNo: newNo)); oldNo += 1; newNo += 1
            default: continue
            }
            hunkRaw.append(Data(raw))
        }
        flush()
        return d
    }

    private static func str<S: Collection>(_ s: S) -> String where S.Element == UInt8 { String(decoding: s, as: UTF8.self) }
    private static func number(after key: String, in s: String) -> Int {
        guard let r = s.range(of: key) else { return 0 }
        return Int(s[r.upperBound...].prefix { $0.isNumber }) ?? 0
    }
}
