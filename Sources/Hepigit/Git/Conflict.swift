import Foundation

/// A conflicted file split at git's conflict markers.
/// "Current" is what was in place (HEAD, or the base during a rebase); "incoming" is what git tried to bring in.
struct ConflictDoc: Equatable {
    struct Block: Equatable {
        var current: String
        var base: String?          // only with merge.conflictStyle=diff3/zdiff3
        var incoming: String
        var currentLabel: String
        var incomingLabel: String
        var raw: String
    }
    enum Segment: Equatable { case text(String), conflict(Block) }
    enum Choice { case current, incoming, both }

    var segments: [Segment]
    var blocks: [Block] { segments.compactMap { if case .conflict(let b) = $0 { b } else { nil } } }

    /// nil when the text has no complete marker block (binary, or already edited by hand).
    static func parse(_ text: String) -> ConflictDoc? {
        var segments: [Segment] = []
        var plain = ""
        var block: Block?
        var part = 0   // 0 current, 1 base, 2 incoming

        func marker(_ line: Substring, _ m: String) -> String? {
            // Swift treats "\r\n" as one Character, so both endings are checked.
            var l = line
            if l.hasSuffix("\r\n") || l.hasSuffix("\n") { l = l.dropLast() }
            guard l.hasPrefix(m) else { return nil }
            let rest = l.dropFirst(m.count)
            if rest.isEmpty { return "" }
            return rest.first == " " ? String(rest.dropFirst()) : nil
        }

        for line in lines(text) {
            if var b = block {
                b.raw += line
                if part == 0, marker(line, "|||||||") != nil { part = 1; b.base = "" }
                else if part < 2, marker(line, "=======") == "" { part = 2 }
                else if part == 2, let label = marker(line, ">>>>>>>") {
                    b.incomingLabel = label
                    segments.append(.conflict(b)); block = nil; continue
                }
                else if part == 0 { b.current += line }
                else if part == 1 { b.base! += line }
                else { b.incoming += line }
                block = b
            } else if let label = marker(line, "<<<<<<<") {
                if !plain.isEmpty { segments.append(.text(plain)); plain = "" }
                block = Block(current: "", base: nil, incoming: "", currentLabel: label, incomingLabel: "", raw: String(line))
                part = 0
            } else {
                plain += line
            }
        }
        if block != nil { return nil }
        if !plain.isEmpty { segments.append(.text(plain)) }
        return segments.contains { if case .conflict = $0 { true } else { false } } ? ConflictDoc(segments: segments) : nil
    }

    /// The file text with conflict `index` (0-based among blocks) replaced by the chosen side.
    func resolving(_ index: Int, _ choice: Choice) -> String {
        var out = ""
        var n = 0
        for s in segments {
            switch s {
            case .text(let t): out += t
            case .conflict(let b):
                if n == index {
                    switch choice {
                    case .current: out += b.current
                    case .incoming: out += b.incoming
                    case .both: out += Self.joined(b.current, b.incoming)
                    }
                } else {
                    out += b.raw
                }
                n += 1
            }
        }
        return out
    }

    /// Both sides, making sure the second starts on its own line.
    private static func joined(_ a: String, _ b: String) -> String {
        a.isEmpty || a.hasSuffix("\n") || a.hasSuffix("\r\n") ? a + b : a + "\n" + b
    }

    /// Lines with their terminators kept, so the file is rewritten byte for byte.
    private static func lines(_ s: String) -> [Substring] {
        var out: [Substring] = []
        var start = s.startIndex
        while let nl = s.utf8[start...].firstIndex(of: 10) {
            let end = s.utf8.index(after: nl)
            out.append(s[start..<end]); start = end
        }
        if start < s.endIndex { out.append(s[start...]) }
        return out
    }
}

/// What the conflict view needs: the parsed markers, the raw text (nil when binary), and which sides still exist.
struct ConflictState {
    var doc: ConflictDoc?
    var text: String?
    var hasCurrent: Bool
    var hasIncoming: Bool
    /// Text with no markers left while both sides exist: every conflict was picked (here or in an editor).
    var allPicked: Bool { doc == nil && text != nil && hasCurrent && hasIncoming }
}
