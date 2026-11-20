import SwiftUI

struct DiffView: View {
    let repo: RepoModel
    let target: DiffTarget
    @State private var diff: FileDiff?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            if isConflict { ConflictView(repo: repo, file: target.file) } else { content }
        }
        .task(id: TaskKey(target: target, status: repo.status)) {
            let d = await repo.diff(target)
            withAnimation(.easeOut(duration: 0.12)) { diff = d }
        }
        .onKeyPress(.escape) { repo.diffTarget = nil; return .handled }
    }

    private var isConflict: Bool { target.file.isConflict && target.source == .unstaged }

    /// Working-tree diffs reload when status changes; commit diffs are immutable.
    private struct TaskKey: Equatable {
        let target: DiffTarget
        let status: RepoStatus?
        init(target: DiffTarget, status: RepoStatus) {
            self.target = target
            switch target.source { case .unstaged, .staged: self.status = status; default: self.status = nil }
        }
    }

    private var header: some View {
        let f = target.file
        return HStack(spacing: 10) {
            Image(systemName: Theme.statusGlyph(f.code)).font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.statusColor(f.code))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.statusColor(f.code).opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(f.fileName).font(.system(size: 13, weight: .semibold))
                let sub = f.oldPath.map { "renamed from \($0)" } ?? f.directory
                if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1) }
            }
            if !isConflict, let d = diff, !d.isBinary {
                HStack(spacing: 6) {
                    Text("+\(d.added)").foregroundStyle(Theme.olive)
                    Text("−\(d.removed)").foregroundStyle(Theme.danger)
                }
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            Spacer()
            fileActions
            IconButton(icon: "arrow.up.forward.square", help: "Open file", size: 26) { repo.openFile(f.path) }
            IconButton(icon: "xmark", help: "Close diff (Esc)", size: 26) { repo.diffTarget = nil }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).frame(height: 50)
        .background(Theme.panel)
    }

    @ViewBuilder private var fileActions: some View {
        switch target.source {
        case .unstaged:
            // Conflicts are marked resolved inside ConflictView, once no markers are left.
            if !target.file.isConflict { PillButton(title: "Stage file", icon: "plus") { repo.stage(target.file) } }
        case .staged:
            PillButton(title: "Unstage file", icon: "minus") { repo.unstage(target.file) }
        default: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        if let d = diff {
            if d.isBinary {
                placeholder("Binary file", "No text diff to show.")
            } else if d.hunks.isEmpty {
                placeholder("No changes to show", target.file.code == "D" ? "The file was deleted." : "Only mode or whitespace changed.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(d.hunks) { hunk in
                            Section {
                                // IDs must be unique across all hunks, or the lazy stack reuses rows and shows blanks.
                                ForEach(hunk.lines.indices.map { hunk.id * 1_000_000 + $0 }, id: \.self) { key in
                                    LineView(line: hunk.lines[key % 1_000_000])
                                }
                            } header: {
                                HunkHeader(repo: repo, hunk: hunk, source: target.source, conflict: target.file.isConflict || target.file.isUntracked)
                            }
                        }
                        if d.truncated {
                            Text("Diff truncated after \(Parse.maxDiffLines) lines. Open the file to see the rest.")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.text3).padding(16)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .background(Theme.bg)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.serif)
            Text(sub).font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HunkHeader: View {
    let repo: RepoModel
    let hunk: Hunk
    let source: DiffTarget.Source
    let conflict: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(hunk.header).font(Theme.mono).foregroundStyle(Theme.text3).lineLimit(1)
            Spacer()
            if !conflict {
                switch source {
                case .unstaged:
                    smallButton("Discard hunk", Theme.text3) { repo.apply(hunk, .discard) }
                    smallButton("Stage hunk", Theme.olive) { repo.apply(hunk, .stage) }
                case .staged:
                    smallButton("Unstage hunk", Theme.gold) { repo.apply(hunk, .unstage) }
                default: EmptyView()
                }
            }
        }
        .padding(.horizontal, 14).frame(height: 30)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1) }
    }

    private func smallButton(_ title: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PressStyle())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).frame(height: 21)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
    }
}

private struct LineView: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNo.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
            Text(line.newNo.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
            Text(sign).frame(width: 22).foregroundStyle(signColor)
            Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                .foregroundStyle(line.kind == .note ? Theme.text3 : Theme.text)
                .italic(line.kind == .note)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.trailing, 12)
        }
        .font(Theme.mono)
        .foregroundStyle(Theme.text3)
        .padding(.vertical, 1.5)
        .background(bg)
    }

    private var sign: String { line.kind == .add ? "+" : line.kind == .del ? "−" : "" }
    private var signColor: Color { line.kind == .add ? Theme.olive : Theme.danger }
    private var bg: Color {
        switch line.kind {
        case .add: Theme.olive.opacity(0.11)
        case .del: Theme.danger.opacity(0.11)
        default: .clear
        }
    }
}
