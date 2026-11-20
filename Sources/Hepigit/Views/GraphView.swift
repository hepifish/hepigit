import SwiftUI

enum GraphMetrics {
    static let rowHeight: CGFloat = 28
    static let lane: CGFloat = 15
    static let maxLanesShown = 8
    static let refsWidth: CGFloat = 190
}

struct GraphView: View {
    let repo: RepoModel
    @FocusState private var focused: Bool

    private var graphWidth: CGFloat {
        CGFloat(min(repo.maxLanes, GraphMetrics.maxLanesShown)) * GraphMetrics.lane + 12
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if repo.status.isDirty || repo.operation != nil {
                            WIPRow(repo: repo, graphWidth: graphWidth).id("wip")
                        }
                        ForEach(repo.commits) { c in
                            if let i = repo.indexByHash[c.id], i < repo.rows.count {
                                CommitRow(repo: repo, commit: c, row: repo.rows[i], graphWidth: graphWidth)
                                    .onAppear { if i == repo.commits.count - 1 { repo.loadMore() } }
                            }
                        }
                        if repo.hasMore {
                            ProgressView().controlSize(.small).padding(16)
                        } else if !repo.commits.isEmpty {
                            Text("Beginning of history").font(.system(size: 11)).foregroundStyle(Theme.text3).padding(18)
                        }
                        if repo.commits.isEmpty && repo.isLoaded {
                            VStack(spacing: 6) {
                                Text("No commits yet").font(Theme.serif)
                                Text("Stage your files on the right and make the first one.").font(.system(size: 12)).foregroundStyle(Theme.text2)
                            }.padding(.top, 80)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: repo.scrollRequest) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                    repo.scrollRequest = nil
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { repo.moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { repo.moveSelection(1); return .handled }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("BRANCH / TAG").frame(width: GraphMetrics.refsWidth, alignment: .trailing).padding(.trailing, 8)
            Text("GRAPH").frame(width: max(graphWidth, 50) + 6, alignment: .leading)
            Text("COMMIT MESSAGE").frame(maxWidth: .infinity, alignment: .leading)
            Text("AUTHOR").frame(width: 130, alignment: .leading)
            Text("WHEN").frame(width: 44, alignment: .trailing).padding(.trailing, 14)
        }
        .font(.system(size: 9.5, weight: .bold)).tracking(1)
        .foregroundStyle(Theme.text3)
        .frame(height: 26)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1) }
    }
}

// MARK: - Rows

struct WIPRow: View {
    let repo: RepoModel
    let graphWidth: CGFloat
    private var selected: Bool { repo.selection == .wip }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: GraphMetrics.refsWidth + 8)
            ZStack {
                Circle().strokeBorder(Theme.text2, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2.2]))
                    .frame(width: 12, height: 12)
            }
            .frame(width: max(graphWidth, 50), alignment: .leading)
            .padding(.leading, 4)
            HStack(spacing: 8) {
                Text("Uncommitted changes").font(.system(size: 12.5, weight: .medium)).italic()
                let s = repo.status
                HStack(spacing: 6) {
                    if !s.staged.isEmpty { Label("\(s.staged.count)", systemImage: "checkmark").foregroundStyle(Theme.olive) }
                    if !s.unstaged.isEmpty { Label("\(s.unstaged.count)", systemImage: "pencil").foregroundStyle(Theme.gold) }
                }
                .font(.system(size: 10.5, weight: .semibold)).labelStyle(CompactLabel())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: GraphMetrics.rowHeight)
        .background(selected ? Theme.accentDeep.opacity(0.7) : Theme.raised.opacity(0.35))
        .contentShape(Rectangle())
        .onTapGesture { repo.select(.wip) }
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon.font(.system(size: 8.5, weight: .bold)); configuration.title }
    }
}

struct CommitRow: View {
    let repo: RepoModel
    let commit: Commit
    let row: GraphRow
    let graphWidth: CGFloat
    @State private var hover = false
    @State private var dropTarget = false

    var body: some View {
        let c = commit
        let selected = repo.selection == .commit(c.id)
        let isHead = c.id == repo.headHash
        HStack(spacing: 0) {
            RefPills(repo: repo, commit: c, color: Theme.lane(row.node))
                .frame(width: GraphMetrics.refsWidth, alignment: .trailing)
                .padding(.trailing, 8)
            GraphCell(row: row, isHead: isHead, isMerge: c.isMerge, highlight: hover || selected)
                .frame(width: max(graphWidth, 50), height: GraphMetrics.rowHeight, alignment: .leading)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .black.opacity(repo.maxLanes > GraphMetrics.maxLanesShown ? 0 : 1), location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .padding(.trailing, 6)
            Text(c.subject)
                .font(.system(size: 12.5, weight: isHead ? .semibold : .regular))
                .foregroundStyle(c.isMerge ? Theme.text2 : Theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Avatar(name: c.author, email: c.email, size: 17)
                Text(c.author).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
            Text(RelTime.short(c.date)).font(.system(size: 11)).foregroundStyle(Theme.text3).monospacedDigit()
                .frame(width: 44, alignment: .trailing).padding(.trailing, 14)
                .help(RelTime.full.string(from: c.date))
        }
        .frame(height: GraphMetrics.rowHeight)
        .opacity(repo.searchQuery.isEmpty || repo.searchHits.contains(c.id) || selected ? 1 : 0.3)
        .background {
            if selected { Theme.accentDeep.opacity(0.7) }
            else if dropTarget { Theme.accent.opacity(0.25) }
            else if hover { Theme.hover.opacity(0.55) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { repo.select(.commit(c.id)) }
        .contextMenu { CommitMenu(repo: repo, commit: c) }
        .dropDestination(for: String.self) { ids, _ in
            handleDrop(ids.first, on: c); return true
        } isTargeted: { t in withAnimation(.easeOut(duration: 0.12)) { dropTarget = t } }
    }

    /// Drag a branch onto the checked-out branch: merge or rebase, GitKraken-style.
    private func handleDrop(_ refID: String?, on c: Commit) {
        guard let refID, let dragged = repo.refs.first(where: { $0.id == refID }) else { return }
        guard let current = repo.currentBranch, current.target == c.id else {
            AppState.shared.toast(.info, "Drop onto the checked-out branch", "Merging and rebasing work on the branch you're on.")
            return
        }
        guard dragged.id != current.id else { return }
        var m = Modal(title: "\(dragged.name) → \(current.name)", message: "Choose how to bring the changes in.",
                      confirm: "Merge into \(current.name)", destructive: false) { _ in repo.merge(dragged) }
        m.secondary = (title: "Rebase instead", action: { repo.run("rebase", ["rebase", dragged.name], success: "Rebased onto \(dragged.name)") })
        AppState.shared.modal = m
    }
}

struct GraphCell: View {
    let row: GraphRow
    let isHead: Bool
    let isMerge: Bool
    let highlight: Bool

    var body: some View {
        Canvas { ctx, size in
            let h = size.height, mid = h / 2
            let style = StrokeStyle(lineWidth: 2, lineCap: .round)
            func x(_ i: Int) -> CGFloat { CGFloat(i) * GraphMetrics.lane + GraphMetrics.lane / 2 + 6 }

            for i in row.through {
                var p = Path(); p.move(to: CGPoint(x: x(i), y: 0)); p.addLine(to: CGPoint(x: x(i), y: h))
                ctx.stroke(p, with: .color(Theme.lane(i)), style: style)
            }
            let nx = x(row.node)
            if row.hasTop {
                var p = Path(); p.move(to: CGPoint(x: nx, y: 0)); p.addLine(to: CGPoint(x: nx, y: mid))
                ctx.stroke(p, with: .color(Theme.lane(row.node)), style: style)
            }
            for j in row.incoming {
                var p = Path(); p.move(to: CGPoint(x: x(j), y: 0))
                p.addCurve(to: CGPoint(x: nx, y: mid), control1: CGPoint(x: x(j), y: mid), control2: CGPoint(x: x(j), y: mid))
                ctx.stroke(p, with: .color(Theme.lane(j)), style: style)
            }
            for o in row.outgoing {
                var p = Path(); p.move(to: CGPoint(x: nx, y: mid))
                if o == row.node { p.addLine(to: CGPoint(x: nx, y: h)) }
                else { p.addCurve(to: CGPoint(x: x(o), y: h), control1: CGPoint(x: x(o), y: mid), control2: CGPoint(x: x(o), y: mid)) }
                ctx.stroke(p, with: .color(Theme.lane(o)), style: style)
            }

            let color = Theme.lane(row.node)
            let r: CGFloat = isMerge ? 3.5 : (highlight ? 6 : 5)
            let rect = CGRect(x: nx - r, y: mid - r, width: r * 2, height: r * 2)
            if isHead {
                let halo = rect.insetBy(dx: -4, dy: -4)
                ctx.fill(Path(ellipseIn: halo), with: .color(color.opacity(0.22)))
            }
            ctx.fill(Path(ellipseIn: rect), with: .color(color))
            if !isMerge {
                let inner = rect.insetBy(dx: 2.2, dy: 2.2)
                ctx.fill(Path(ellipseIn: inner), with: .color(isHead ? Theme.text : Theme.bg))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: highlight)
    }
}

// MARK: - Ref pills

/// Local + remote branches with the same name on the same commit collapse into one pill.
struct RefPills: View {
    let repo: RepoModel
    let commit: Commit
    let color: Color

    struct Pill: Identifiable {
        let id: String
        let ref: Ref
        let text: String
        let local: Bool
        let remote: Bool
        let tag: Bool
        let head: Bool
    }

    private var pills: [Pill] {
        guard let refs = repo.refsByTarget[commit.id] else { return [] }
        var out: [Pill] = []
        var usedRemotes = Set<String>()
        for l in refs where l.kind == .local {
            let twin = refs.first { $0.kind == .remote && $0.branch == l.name }
            if let twin { usedRemotes.insert(twin.id) }
            out.append(Pill(id: l.id, ref: l, text: l.name, local: true, remote: twin != nil, tag: false, head: l.isHead))
        }
        for r in refs where r.kind == .remote && !usedRemotes.contains(r.id) {
            out.append(Pill(id: r.id, ref: r, text: r.name, local: false, remote: true, tag: false, head: false))
        }
        for t in refs where t.kind == .tag {
            out.append(Pill(id: t.id, ref: t, text: t.name, local: false, remote: false, tag: true, head: false))
        }
        return out.sorted { ($0.head ? 0 : $0.local ? 1 : $0.tag ? 3 : 2) < ($1.head ? 0 : $1.local ? 1 : $1.tag ? 3 : 2) }
    }

    var body: some View {
        let all = pills
        HStack(spacing: 4) {
            if all.count > 1 {
                Text("+\(all.count - 1)")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
                    .help(all.dropFirst().map(\.text).joined(separator: "\n"))
            }
            if let first = all.first { PillView(repo: repo, pill: first, color: color) }
        }
    }
}

private struct PillView: View {
    let repo: RepoModel
    let pill: RefPills.Pill
    let color: Color
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            if pill.head { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)) }
            Text(pill.text).font(.system(size: 11, weight: pill.head ? .bold : .semibold)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 2) {
                if pill.local { Image(systemName: "laptopcomputer") }
                if pill.remote { Image(systemName: "cloud.fill") }
                if pill.tag { Image(systemName: "tag.fill") }
            }
            .font(.system(size: 8.5)).opacity(0.75)
        }
        .padding(.horizontal, 7).frame(height: 19)
        .foregroundStyle(pill.tag ? Theme.text2 : color)
        .background(Capsule().fill((pill.tag ? Theme.text3 : color).opacity(hover ? 0.32 : 0.18)))
        .overlay(Capsule().strokeBorder((pill.tag ? Theme.text3 : color).opacity(pill.head ? 0.9 : 0.35), lineWidth: 1))
        .scaleEffect(hover ? 1.04 : 1)
        .onHover { h in withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { hover = h } }
        .onTapGesture(count: 2) { repo.checkout(pill.ref) }
        .draggable(pill.ref.id) {
            Text(pill.text).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.4)))
        }
        .contextMenu { RefMenu(repo: repo, ref: pill.ref) }
        .help("\(pill.text)  ·  double-click to check out, drag onto your branch to merge")
    }
}

// MARK: - Commit menu

struct CommitMenu: View {
    let repo: RepoModel
    let commit: Commit

    var body: some View {
        let branch = repo.status.branch ?? "HEAD"
        Button("New branch here…") { repo.newBranch(at: commit.id) }
        Button("New tag here…") { repo.newTag(at: commit.id) }
        Button("Check out this commit") { repo.checkoutDetached(commit.id) }
        Divider()
        if commit.id != repo.headHash {
            Button("Cherry-pick onto \(branch)") { repo.cherryPick(commit.id) }
        }
        Button("Revert this commit") { repo.revert(commit.id) }
        Menu("Reset \(branch) to here") {
            Button("Soft: keep changes staged") { repo.reset(to: commit.id, .soft) }
            Button("Mixed: keep changes unstaged") { repo.reset(to: commit.id, .mixed) }
            Button("Hard: discard all changes…") { repo.reset(to: commit.id, .hard) }
        }
        if commit.id == repo.headHash && !commit.parents.isEmpty {
            Button("Undo this commit…") { repo.undoLastCommit() }
        }
        Divider()
        Button("Copy SHA") { copy(commit.id) }
        Button("Copy message") { copy(commit.subject) }
        if let refs = repo.refsByTarget[commit.id], !refs.isEmpty {
            Divider()
            ForEach(refs) { r in
                Menu(r.name) { RefMenu(repo: repo, ref: r) }
            }
        }
    }
}
