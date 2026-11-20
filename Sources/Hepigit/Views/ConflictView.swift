import SwiftUI

/// Resolves a conflicted file in place: pick a side per conflict, or one side for the whole file.
struct ConflictView: View {
    let repo: RepoModel
    let file: FileChange
    @State private var state: ConflictState?

    private struct Key: Equatable { let file: FileChange; let status: RepoStatus; let resolving: Bool }

    var body: some View {
        Group {
            if let s = state {
                VStack(spacing: 0) {
                    strip(s)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    if let doc = s.doc { blocks(doc) } else { done(s) }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .task(id: Key(file: file, status: repo.status, resolving: repo.busy.contains("resolve"))) {
            guard !repo.busy.contains("resolve") else { return }
            let s = await repo.conflict(file)
            withAnimation(.easeOut(duration: 0.16)) { state = s }
        }
    }

    // MARK: Top strip: progress plus whole-file choices

    private func strip(_ s: ConflictState) -> some View {
        let left = s.doc?.blocks.count ?? 0
        return HStack(spacing: 8) {
            Image(systemName: s.allPicked ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(s.allPicked ? Theme.olive : Theme.gold)
                .contentTransition(.symbolEffect(.replace))
            Text(s.allPicked ? "No conflicts left. Check the result, then mark it resolved."
                 : left > 0 ? "\(left) conflict\(left == 1 ? "" : "s") left" : "Pick a version")
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.numericText())
            Spacer()
            Button("Start over") { repo.restartConflict(file) }
                .buttonStyle(PressStyle()).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                .padding(.trailing, 6)
                .help("Bring the conflict markers back")
            if s.allPicked {
                PillButton(title: "Mark resolved", icon: "checkmark", primary: true) { repo.stage(file) }
                    .help("Stage this file as resolved")
            } else {
                Text("Whole file:").font(.system(size: 11)).foregroundStyle(Theme.text3)
                sideButton("Keep current", s.hasCurrent, current: true)
                sideButton("Keep incoming", s.hasIncoming, current: false)
            }
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(Theme.panel)
    }

    private func sideButton(_ title: String, _ exists: Bool, current: Bool) -> some View {
        SmallButton(title: exists ? title : (current ? "Keep current (deleted)" : "Keep incoming (deleted)"),
                    tint: current ? Theme.accent : Theme.gold) {
            repo.resolveFile(file, current: current, sideExists: exists)
        }
        .help(exists ? "Use this side for the whole file and mark it resolved" : "This side deleted the file; keeping it deletes the file")
    }

    // MARK: Nothing left to pick

    @ViewBuilder private func done(_ s: ConflictState) -> some View {
        if s.allPicked, let text = s.text {
            // Show the result, so it can be checked before marking it resolved.
            ScrollView { ContextText(text: text, top: false, bottom: false, collapse: false).padding(.vertical, 12) }
        } else {
            VStack(spacing: 10) {
                Text(!s.hasCurrent ? "The current side deleted this file"
                     : !s.hasIncoming ? "The incoming side deleted this file"
                     : "This file can't be compared line by line").font(Theme.serif)
                Text("Pick which version to keep above.").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Blocks

    private func blocks(_ doc: ConflictDoc) -> some View {
        var n = -1
        let items: [(id: Int, seg: ConflictDoc.Segment, block: Int?)] = doc.segments.enumerated().map { i, seg in
            if case .conflict = seg { n += 1; return (i, seg, n) }
            return (i, seg, nil)
        }
        let last = items.count - 1
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items, id: \.id) { item in
                    switch item.seg {
                    case .text(let t):
                        ContextText(text: t, top: item.id > 0, bottom: item.id < last)
                    case .conflict(let b):
                        BlockCard(block: b) { choice in repo.resolveBlock(file, item.block ?? 0, choice) }
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }
}

/// Unchanged lines around conflicts: only the few nearest lines are shown.
private struct ContextText: View {
    let text: String
    let top: Bool       // a conflict sits above
    let bottom: Bool    // a conflict sits below
    var collapse = true

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0).map(String.init)
        let keep = 3
        let head = top ? Array(lines.prefix(keep)) : []
        let tail = bottom ? Array(lines.suffix(keep)) : []
        let hidden = lines.count - head.count - tail.count
        VStack(alignment: .leading, spacing: 0) {
            if !collapse || hidden <= 2 {
                ForEach(Array(lines.enumerated()), id: \.offset) { CodeLine(text: $0.element) }
            } else {
                ForEach(Array(head.enumerated()), id: \.offset) { CodeLine(text: $0.element) }
                Text("⋯  \(hidden) unchanged line\(hidden == 1 ? "" : "s")")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    .padding(.horizontal, 18).padding(.vertical, 5)
                ForEach(Array(tail.enumerated()), id: \.offset) { CodeLine(text: $0.element) }
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct CodeLine: View {
    let text: String
    var body: some View {
        Text(text.isEmpty ? " " : text.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\r", with: ""))
            .font(Theme.mono).foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
    }
}

/// One conflict: current above incoming, each with its own "Keep" button, and "Keep both" underneath.
private struct BlockCard: View {
    let block: ConflictDoc.Block
    let pick: (ConflictDoc.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            side("Current", label: block.currentLabel, text: block.current, tint: Theme.accent, choice: .current)
            Rectangle().fill(Theme.line).frame(height: 1)
            side("Incoming", label: block.incomingLabel, text: block.incoming, tint: Theme.gold, choice: .incoming)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Spacer()
                SmallButton(title: "Keep both", tint: Theme.text) { pick(.both) }
                    .help("Current first, then incoming")
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Theme.panel)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func side(_ title: String, label: String, text: String, tint: Color, choice: ConflictDoc.Choice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(Self.shortLabel(label)).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                Spacer()
                SmallButton(title: "Keep \(title.lowercased())", tint: tint) { pick(choice) }
            }
            .padding(.horizontal, 10).frame(height: 32)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0).map(String.init)
            VStack(alignment: .leading, spacing: 0) {
                if lines.isEmpty {
                    Text("Nothing here (this side removed these lines)").font(.system(size: 11)).italic()
                        .foregroundStyle(Theme.text3).padding(.horizontal, 4).padding(.vertical, 3)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { line in
                    Text(line.element.isEmpty ? " " : line.element.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\r", with: ""))
                        .font(Theme.mono).foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .background(tint.opacity(0.07))
    }

    /// Commit hashes in markers are shortened; names like "HEAD" or "Stashed changes" stay.
    static func shortLabel(_ s: String) -> String {
        let first = s.split(separator: " ").first.map(String.init) ?? s
        let isHash = first.count >= 12 && first.allSatisfy(\.isHexDigit)
        return isHash ? String(first.prefix(7)) + s.dropFirst(first.count) : s
    }
}

struct SmallButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PressStyle())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.hover : Theme.raised))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}
