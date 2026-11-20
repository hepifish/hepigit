import SwiftUI

struct Inspector: View {
    let repo: RepoModel

    var body: some View {
        ZStack {
            switch repo.selection {
            case .wip: WorkingPanel(repo: repo)
            case .commit(let h):
                if let c = repo.commits.first(where: { $0.id == h }) { CommitPanel(repo: repo, commit: c).id(h) }
            case .stash(let h):
                if let s = repo.stashes.first(where: { $0.hash == h }) { StashPanel(repo: repo, stash: s).id(h) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .animation(.easeOut(duration: 0.15), value: repo.selection)
    }
}

// MARK: - File rows

struct FileRow: View {
    let repo: RepoModel
    let file: FileChange
    let target: DiffTarget
    var actions: AnyView? = nil
    @State private var hover = false

    var body: some View {
        let selected = repo.diffTarget == target
        HStack(spacing: 8) {
            Image(systemName: Theme.statusGlyph(file.code))
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Theme.statusColor(file.code))
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.statusColor(file.code).opacity(0.16)))
            (Text(file.fileName).foregroundColor(Theme.text)
             + Text(file.directory.isEmpty ? "" : "  " + file.directory).foregroundColor(Theme.text3))
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            if hover, let actions { actions.transition(.opacity.combined(with: .move(edge: .trailing))) }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .contentShape(Rectangle())
        .hoverRow(selected: selected)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { repo.diffTarget = selected ? nil : target }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
        .contextMenu {
            Button("Open file") { repo.openFile(file.path) }
            Button("Reveal in Finder") { repo.reveal(path: file.path) }
            Button("Copy path") { copy(file.path) }
            if file.area != .commit {
                Divider()
                Button("Discard changes…", role: .destructive) { repo.discard(file) }
            }
        }
    }
}

// MARK: - Working tree

struct WorkingPanel: View {
    let repo: RepoModel
    @State private var summary = ""
    @State private var details = ""
    @State private var amend = false
    @FocusState private var summaryFocused: Bool

    var body: some View {
        let s = repo.status
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.isDirty ? "\(s.changeCount) file\(s.changeCount == 1 ? "" : "s") changed" : "Working tree clean")
                        .font(Theme.serif)
                        .contentTransition(.numericText())
                    Text(s.branch.map { "on \($0)" } ?? "detached HEAD").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                if s.isDirty {
                    IconButton(icon: "arrow.uturn.backward", help: "Discard all changes…", tint: Theme.text3, size: 26) { repo.discardAll() }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Unstaged", s.unstaged.count, action: "Stage all", enabled: !s.unstaged.isEmpty) { repo.stageAll() }
                    ForEach(s.unstaged) { f in
                        FileRow(repo: repo, file: f, target: DiffTarget(file: f, source: .unstaged), actions: AnyView(
                            HStack(spacing: 2) {
                                IconButton(icon: "arrow.uturn.backward", help: "Discard changes", tint: Theme.text3, size: 20) { repo.discard(f) }
                                IconButton(icon: "plus", help: f.isConflict ? "Mark resolved" : "Stage", tint: Theme.olive, size: 20) { repo.stage(f) }
                            }))
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                    if s.unstaged.isEmpty { emptyLine(s.staged.isEmpty ? "Edit a file and it shows up here." : "Everything is staged.") }

                    sectionHeader("Staged", s.staged.count, action: "Unstage all", enabled: !s.staged.isEmpty) { repo.unstageAll() }
                        .padding(.top, 10)
                    ForEach(s.staged) { f in
                        FileRow(repo: repo, file: f, target: DiffTarget(file: f, source: .staged), actions: AnyView(
                            IconButton(icon: "minus", help: "Unstage", tint: Theme.gold, size: 20) { repo.unstage(f) }))
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    if s.staged.isEmpty { emptyLine("Stage files to include them in the commit.") }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
                .animation(.snappy(duration: 0.25), value: s)
            }
            .scrollIndicators(.never)

            composer
        }
        .task(id: repo.operation) {
            if repo.operation == .merge, summary.isEmpty, let msg = readMergeMessage() { summary = msg }
        }
    }

    private var composer: some View {
        let s = repo.status
        let canCommit = (!s.staged.isEmpty || amend) && !summary.trimmingCharacters(in: .whitespaces).isEmpty && s.conflicts.isEmpty
        let busy = repo.busy.contains("commit")
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Commit")
                Spacer()
                Button {
                    amend.toggle()
                    if amend { Task { let (a, b) = await repo.lastCommitMessage(); if summary.isEmpty { summary = a; details = b } } }
                } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(amend ? Theme.accent : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(amend ? Theme.accent : Theme.text3, lineWidth: 1.2))
                            .overlay { if amend { Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)) } }
                            .frame(width: 13, height: 13)
                        Text("Amend last commit").font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.text2)
                }
                .buttonStyle(PressStyle())
                .animation(.spring(response: 0.2), value: amend)
            }
            HStack(spacing: 0) {
                TextField("Summary", text: $summary).textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    .focused($summaryFocused)
                Text("\(72 - summary.count)").font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(summary.count > 72 ? Theme.danger : Theme.text3)
                    .opacity(summary.isEmpty ? 0 : 1)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(summaryFocused ? Theme.accent.opacity(0.6) : Theme.line))

            ZStack(alignment: .topLeading) {
                if details.isEmpty {
                    Text("Description (optional)").font(.system(size: 12)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                TextEditor(text: $details).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .writingToolsBehavior(.disabled)
                    .padding(.horizontal, 5).padding(.vertical, 6)
            }
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))

            Button { commit() } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini).tint(.white) }
                    Text(commitLabel(canCommit)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity).frame(height: 34)
                .foregroundStyle(canCommit ? Color.white : Theme.text3)
                .background(RoundedRectangle(cornerRadius: 9).fill(canCommit ? Theme.accent : Theme.raised))
            }
            .buttonStyle(PressStyle())
            .disabled(!canCommit || busy)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Commit (⌘↩)")
            .animation(.easeOut(duration: 0.15), value: canCommit)
        }
        .padding(14)
        .background(Theme.raised.opacity(0.35))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func commitLabel(_ can: Bool) -> String {
        let s = repo.status
        if !s.conflicts.isEmpty { return "Resolve conflicts first" }
        if s.staged.isEmpty && !amend { return "Stage files to commit" }
        if summary.trimmingCharacters(in: .whitespaces).isEmpty { return "Write a summary" }
        let n = s.staged.count
        let where_ = s.branch.map { " to \($0)" } ?? ""
        return amend ? "Amend commit\(where_)" : "Commit \(n) file\(n == 1 ? "" : "s")\(where_)"
    }

    private func commit() {
        Task {
            if await repo.commit(summary: summary, body: details, amend: amend) {
                withAnimation(.snappy) { summary = ""; details = ""; amend = false }
            }
        }
    }

    private func readMergeMessage() -> String? {
        guard let r = repo.gitDir?.appendingPathComponent("MERGE_MSG") else { return nil }
        guard let text = try? String(contentsOf: r, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { !$0.hasPrefix("#") }.map(String.init)
    }

    private func sectionHeader(_ title: String, _ count: Int, action: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        HStack {
            SectionLabel(text: title, count: count)
            Spacer()
            if enabled {
                Button(action, action: run).buttonStyle(PressStyle())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8).frame(height: 30)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text3).padding(.horizontal, 8).padding(.vertical, 4)
    }
}

// MARK: - Commit details

struct CommitPanel: View {
    let repo: RepoModel
    let commit: Commit
    @State private var files: [FileChange]?
    @State private var body_: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Button { copy(commit.id) } label: {
                        HStack(spacing: 4) {
                            Text(commit.short).font(Theme.mono)
                            Image(systemName: "doc.on.doc").font(.system(size: 9))
                        }
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
                    }
                    .buttonStyle(PressStyle()).help("Copy full SHA")
                    if !commit.parents.isEmpty {
                        Text(commit.isMerge ? "parents" : "parent").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                        ForEach(commit.parents, id: \.self) { p in
                            Button(String(p.prefix(7))) { repo.reveal(p) }
                                .buttonStyle(.plain).font(Theme.mono).foregroundStyle(Theme.accent)
                                .help("Jump to parent")
                        }
                    }
                    Spacer()
                    IconButton(icon: "arrow.triangle.branch", help: "New branch here") { repo.newBranch(at: commit.id) }
                    IconButton(icon: "tag", help: "New tag here") { repo.newTag(at: commit.id) }
                    IconButton(icon: "arrow.uturn.left", help: "Revert this commit") { repo.revert(commit.id) }
                }
                Text(commit.subject).font(.system(size: 16, weight: .medium, design: .serif))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !body_.isEmpty {
                    Text(body_).font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .lineLimit(14)
                }
                HStack(spacing: 8) {
                    Avatar(name: commit.author, email: commit.email, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(commit.author).font(.system(size: 12, weight: .medium))
                        Text(RelTime.full.string(from: commit.date)).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
            .padding(14)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                SectionLabel(text: "Files", count: files?.count)
                if commit.isMerge { Text("vs first parent").font(.system(size: 10)).foregroundStyle(Theme.text3) }
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 32)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(files ?? []) { f in
                        FileRow(repo: repo, file: f, target: DiffTarget(file: f, source: .commit(hash: commit.id, parent: commit.parents.first)))
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .overlay { if files == nil { ProgressView().controlSize(.small) } }
        }
        .task {
            async let f = repo.files(of: commit.id)
            async let b = repo.body(of: commit.id)
            let (ff, bb) = await (f, b)
            withAnimation(.easeOut(duration: 0.15)) { files = ff; body_ = bb }
        }
    }
}

// MARK: - Stash

struct StashPanel: View {
    let repo: RepoModel
    let stash: Stash
    @State private var files: [FileChange]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full").foregroundStyle(Theme.gold)
                    Text(stash.ref).font(Theme.mono).foregroundStyle(Theme.text3)
                    Spacer()
                    Text(RelTime.full.string(from: stash.date)).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
                Text(stash.message).font(.system(size: 16, weight: .medium, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PillButton(title: "Pop", icon: "tray.and.arrow.up", primary: true, busy: repo.busy.contains("pop")) { repo.popStash(stash) }
                        .help("Apply and remove the stash")
                    PillButton(title: "Apply", busy: false) { repo.applyStash(stash) }
                        .help("Apply and keep the stash")
                    Spacer()
                    IconButton(icon: "trash", help: "Delete stash", tint: Theme.text3, size: 28) { repo.dropStash(stash) }
                }
            }
            .padding(14)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack { SectionLabel(text: "Files", count: files?.count); Spacer() }
                .padding(.horizontal, 16).frame(height: 32)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(files ?? []) { f in
                        FileRow(repo: repo, file: f, target: DiffTarget(file: f, source: .stash(ref: stash.hash, untracked: f.isUntracked)))
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
        }
        .task { let f = await repo.files(of: stash); withAnimation { files = f } }
    }
}
