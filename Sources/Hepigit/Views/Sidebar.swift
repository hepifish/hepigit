import SwiftUI

struct Sidebar: View {
    let repo: RepoModel
    @State private var filter = ""
    @State private var collapsed: Set<String> = ["tags"]
    @FocusState private var filterFocused: Bool

    private func match(_ r: Ref) -> Bool { filter.isEmpty || r.name.localizedCaseInsensitiveContains(filter) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
                TextField("Filter branches", text: $filter).textFieldStyle(.plain).font(.system(size: 12))
                    .focused($filterFocused)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(filterFocused ? Theme.accent.opacity(0.6) : Theme.line))
            .padding(10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let locals = repo.locals.filter(match)
                    group("local", "Local", count: locals.count) {
                        ForEach(locals) { BranchRow(repo: repo, ref: $0) }
                        if locals.isEmpty { empty(filter.isEmpty ? "No branches yet" : "No match") }
                    }
                    ForEach(repo.remotes, id: \.self) { remote in
                        let list = repo.remoteBranches(remote).filter(match)
                        group("remote-\(remote)", remote, icon: "cloud", count: list.count) {
                            ForEach(list) { BranchRow(repo: repo, ref: $0) }
                            if list.isEmpty { empty(filter.isEmpty ? "Nothing fetched" : "No match") }
                        }
                    }
                    let tags = repo.tags.filter(match)
                    group("tags", "Tags", count: tags.count) {
                        ForEach(tags) { BranchRow(repo: repo, ref: $0) }
                        if tags.isEmpty { empty("No tags") }
                    }
                    group("stashes", "Stashes", count: repo.stashes.count) {
                        ForEach(repo.stashes) { StashRow(repo: repo, stash: $0) }
                        if repo.stashes.isEmpty { empty("Nothing stashed") }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.panel)
    }

    @ViewBuilder
    private func group<C: View>(_ id: String, _ title: String, icon: String? = nil, count: Int, @ViewBuilder content: () -> C) -> some View {
        let open = !collapsed.contains(id) || !filter.isEmpty
        Button {
            withAnimation(Theme.spring) { if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 10)
                if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.text3) }
                SectionLabel(text: title, count: count)
                Spacer()
            }
            .padding(.horizontal, 6).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        if open { content() }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text3).padding(.leading, 28).frame(height: 24)
    }
}

struct BranchRow: View {
    let repo: RepoModel
    let ref: Ref

    private var selected: Bool { repo.selection == .commit(ref.target) }

    var body: some View {
        HStack(spacing: 7) {
            icon.frame(width: 14)
            nameText.lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if ref.kind == .local { tracking }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 26)
        .contentShape(Rectangle())
        .hoverRow(selected: selected)
        .onTapGesture(count: 2) { repo.checkout(ref) }
        .simultaneousGesture(TapGesture().onEnded { repo.reveal(ref.target) })
        .draggable(ref.id)
        .contextMenu { RefMenu(repo: repo, ref: ref) }
        .help(ref.kind == .tag ? ref.name : "\(ref.name)  ·  double-click to check out")
    }

    @ViewBuilder private var icon: some View {
        switch ref.kind {
        case .local:
            if ref.isHead {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    .font(.system(size: 11)).transition(.scale)
            } else {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.text3).font(.system(size: 10.5))
            }
        case .remote: Image(systemName: "cloud").foregroundStyle(Theme.text3).font(.system(size: 10))
        case .tag: Image(systemName: "tag").foregroundStyle(Theme.text3).font(.system(size: 10))
        }
    }

    private var nameText: Text {
        let name = ref.kind == .remote ? ref.branch : ref.name
        let weight: Font.Weight = ref.isHead ? .semibold : .regular
        if let slash = name.lastIndex(of: "/") {
            return Text(name[...slash]).foregroundColor(Theme.text3).font(.system(size: 12.5, weight: weight))
                + Text(name[name.index(after: slash)...]).foregroundColor(Theme.text).font(.system(size: 12.5, weight: weight))
        }
        return Text(name).foregroundColor(ref.isHead ? Theme.text : Theme.text.opacity(0.9)).font(.system(size: 12.5, weight: weight))
    }

    @ViewBuilder private var tracking: some View {
        HStack(spacing: 4) {
            if ref.upstreamGone {
                Image(systemName: "cloud.slash").foregroundStyle(Theme.text3).help("Upstream branch was deleted")
            } else if ref.upstream == nil {
                Image(systemName: "icloud.slash").foregroundStyle(Theme.text3.opacity(0.6)).help("Not pushed yet")
            }
            if ref.behind > 0 { Text("↓\(ref.behind)").foregroundStyle(Theme.gold) }
            if ref.ahead > 0 { Text("↑\(ref.ahead)").foregroundStyle(Theme.olive) }
        }
        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
    }
}

struct RefMenu: View {
    let repo: RepoModel
    let ref: Ref

    var body: some View {
        let current = repo.status.branch
        if !(ref.kind == .local && ref.isHead) {
            Button(ref.kind == .tag ? "Check out tag (detached)" : "Check out \(ref.kind == .remote ? ref.branch : ref.name)") { repo.checkout(ref) }
        }
        if let current, ref.name != current, ref.kind != .tag {
            Button("Merge \(ref.name) into \(current)") { repo.merge(ref) }
            Button("Rebase \(current) onto \(ref.name)…") { repo.rebase(onto: ref) }
        }
        if ref.kind == .local {
            Divider()
            if ref.upstream != nil && ref.behind > 0 { Button("Fast-forward \(ref.name)") { repo.fastForward(ref) } }
            if ref.upstream == nil { Button("Push and track") { repo.pushBranch(ref) } }
            else if ref.isHead { Button("Push") { repo.push() } }
            Button("Rename…") { repo.rename(ref) }
        }
        if ref.kind == .tag {
            Divider()
            Button("Push tag") { repo.pushTag(ref) }
        }
        Divider()
        Button("New branch from here…") { repo.newBranch(at: ref.target) }
        Button("Copy name") { copy(ref.kind == .remote ? ref.branch : ref.name) }
        if !(ref.kind == .local && ref.isHead) {
            Divider()
            Button(ref.kind == .remote ? "Delete from \(ref.remote ?? "remote")…" : "Delete \(ref.name)…", role: .destructive) { repo.delete(ref) }
        }
    }
}

struct StashRow: View {
    let repo: RepoModel
    let stash: Stash
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "tray").font(.system(size: 10)).foregroundStyle(Theme.text3).frame(width: 14)
            Text(stash.message).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(RelTime.short(stash.date)).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 26)
        .contentShape(Rectangle())
        .hoverRow(selected: repo.selection == .stash(stash.hash))
        .onTapGesture { repo.select(.stash(stash.hash)) }
        .contextMenu {
            Button("Apply") { repo.applyStash(stash) }
            Button("Pop (apply and remove)") { repo.popStash(stash) }
            Divider()
            Button("Delete…", role: .destructive) { repo.dropStash(stash) }
        }
    }
}
