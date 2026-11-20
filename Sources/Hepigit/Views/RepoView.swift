import SwiftUI

struct RepoView: View {
    let repo: RepoModel
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 236
    @AppStorage("inspectorWidth") private var inspectorWidth: Double = 360

    var body: some View {
        VStack(spacing: 0) {
            RepoToolbar(repo: repo)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                Sidebar(repo: repo).frame(width: sidebarWidth)
                ResizeHandle(width: $sidebarWidth, range: 180...420, sign: 1)
                VStack(spacing: 0) {
                    if let op = repo.operation { OperationBanner(repo: repo, op: op) }
                    ZStack {
                        if let target = repo.diffTarget {
                            DiffView(repo: repo, target: target)
                                .transition(.opacity.combined(with: .scale(scale: 0.99)))
                        } else {
                            GraphView(repo: repo).transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.16), value: repo.diffTarget)
                }
                .frame(maxWidth: .infinity)
                .background(Theme.bg)
                ResizeHandle(width: $inspectorWidth, range: 300...620, sign: -1)
                Inspector(repo: repo).frame(width: inspectorWidth)
            }
        }
        .overlay {
            if !repo.isLoaded {
                ProgressView().controlSize(.small).tint(Theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg.opacity(0.6))
            }
        }
    }
}

struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let sign: Double
    @State private var start: Double?
    @State private var hover = false

    var body: some View {
        Rectangle().fill(hover ? Theme.accent.opacity(0.6) : Theme.line)
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 7).contentShape(Rectangle())
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
                .pointerStyle(.columnResize)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if start == nil { start = width }
                        width = min(range.upperBound, max(range.lowerBound, (start ?? width) + sign * v.translation.width))
                    }
                    .onEnded { _ in start = nil }))
    }
}

struct OperationBanner: View {
    let repo: RepoModel
    let op: RepoOperation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(op.rawValue) in progress").font(.system(size: 12.5, weight: .semibold))
                let n = repo.status.conflicts.count
                Text(n > 0 ? "\(n) conflicted file\(n == 1 ? "" : "s"). Resolve them in your editor, then stage each one."
                           : "No conflicts left. Continue when ready.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            }
            Spacer()
            PillButton(title: "Abort") { repo.abortOperation() }
            PillButton(title: "Continue", primary: true, busy: repo.busy.contains("continue"),
                       disabled: !repo.status.conflicts.isEmpty) { repo.continueOperation() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.gold.opacity(0.09))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.gold.opacity(0.25)).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Toolbar

struct RepoToolbar: View {
    let repo: RepoModel

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.system(size: 17, weight: .medium, design: .serif)).lineLimit(1)
                BranchSwitcher(repo: repo)
            }
            .frame(minWidth: 170, alignment: .leading)
            .padding(.leading, 18)

            Spacer(minLength: 12)

            ToolButton(repo: repo, key: "undo", icon: "arrow.uturn.backward", label: "Undo",
                       help: repo.undoLabel.map { "Undo \($0) (⌥⌘Z)" } ?? "Nothing to undo yet") { repo.undo() }
                .disabled(repo.undoStack.isEmpty)
                .opacity(repo.undoStack.isEmpty ? 0.35 : 1)
                .animation(.easeOut(duration: 0.2), value: repo.undoStack.isEmpty)
            Rectangle().fill(Theme.line).frame(width: 1, height: 26).padding(.horizontal, 8)

            ToolButton(repo: repo, key: "fetch", icon: "arrow.triangle.2.circlepath", label: "Fetch", help: "Fetch all remotes (⇧⌘F)") { repo.fetch() }
            ToolButton(repo: repo, key: "pull", icon: "arrow.down", label: "Pull", badge: repo.status.behind,
                       help: "Pull (⇧⌘L). Merges only if needed.", menu: {
                Button("Pull (merge if needed)") { repo.pull(.merge) }
                Button("Pull (fast-forward only)") { repo.pull(.ffOnly) }
                Button("Pull (rebase)") { repo.pull(.rebase) }
            }) { repo.pull() }
            ToolButton(repo: repo, key: "push", icon: "arrow.up", label: "Push", badge: repo.status.ahead,
                       help: repo.status.upstream == nil ? "Push and set upstream (⇧⌘P)" : "Push (⇧⌘P)", menu: {
                Button("Push") { repo.push() }
                Button("Force push (with lease)…") { repo.confirmForcePush() }
            }) { repo.push() }

            Rectangle().fill(Theme.line).frame(width: 1, height: 26).padding(.horizontal, 8)

            ToolButton(repo: repo, key: "branch", icon: "arrow.triangle.branch", label: "Branch", help: "New branch here (⇧⌘B)") { repo.newBranch() }
            ToolButton(repo: repo, key: "stash", icon: "tray.and.arrow.down", label: "Stash", help: "Stash all changes (⇧⌘S)") { repo.stash() }
            ToolButton(repo: repo, key: "pop", icon: "tray.and.arrow.up", label: "Pop", badge: repo.stashes.count, badgeQuiet: true,
                       help: "Apply and remove the latest stash") { repo.popStash() }

            Spacer(minLength: 12)

            CommitSearch(repo: repo)
            IconButton(icon: "terminal", help: "Open in Terminal (⌥⌘T)", size: 28) { repo.openInTerminal() }
            IconButton(icon: "folder", help: "Reveal in Finder", size: 28) { repo.openInFinder() }
                .padding(.trailing, 14)
        }
        .frame(height: 58)
        .background(Theme.panel)
    }
}

struct BranchSwitcher: View {
    let repo: RepoModel
    var body: some View {
        Menu {
            ForEach(repo.locals) { r in
                Button { repo.checkout(r) } label: {
                    if r.isHead { Label(r.name, systemImage: "checkmark") } else { Text(r.name) }
                }
            }
            Divider()
            Button("New branch…") { repo.newBranch() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: repo.status.branch == nil ? "smallcircle.filled.circle" : "arrow.triangle.branch")
                    .font(.system(size: 9.5, weight: .bold))
                Text(repo.status.branch ?? "detached at \(repo.headHash?.prefix(7) ?? "?")")
                    .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .foregroundStyle(Theme.text2)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch branch")
    }
}

struct ToolButton<M: View>: View {
    let repo: RepoModel
    let key: String
    let icon: String
    let label: String
    var badge: Int = 0
    var badgeQuiet = false
    let help: String
    @ViewBuilder var menu: () -> M
    let action: () -> Void
    @State private var hover = false

    init(repo: RepoModel, key: String, icon: String, label: String, badge: Int = 0, badgeQuiet: Bool = false,
         help: String, @ViewBuilder menu: @escaping () -> M = { EmptyView() }, action: @escaping () -> Void) {
        self.repo = repo; self.key = key; self.icon = icon; self.label = label; self.badge = badge
        self.badgeQuiet = badgeQuiet; self.help = help; self.menu = menu; self.action = action
    }

    private var busy: Bool { repo.busy.contains(key) }
    private var done: Bool { repo.lastSuccess == key }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                VStack(spacing: 4) {
                    ZStack {
                        if busy {
                            ProgressView().controlSize(.small).scaleEffect(0.75).tint(Theme.text)
                        } else if done {
                            Image(systemName: "checkmark").foregroundStyle(Theme.olive)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        } else {
                            Image(systemName: icon).transition(.opacity)
                        }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22, height: 18)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)").font(.system(size: 9, weight: .bold)).monospacedDigit()
                                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 14)
                                .background(Capsule().fill(badgeQuiet ? Theme.hover : Theme.accent))
                                .foregroundStyle(Theme.text)
                                .offset(x: 11, y: -7)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    Text(label).font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(hover ? Theme.text : Theme.text2)
                .frame(width: 54, height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .disabled(busy)
            .help(help)

            if M.self != EmptyView.self {
                Menu { menu() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 14, height: 46)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize()
                .help("More \(label.lowercased()) options")
            }
        }
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.hover.opacity(0.8) : .clear))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: busy)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: done)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: badge)
    }
}

struct CommitSearch: View {
    @Bindable var repo: RepoModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
            TextField("Search commits", text: $repo.searchQuery)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($focused)
                .onSubmit { repo.nextSearchHit() }
                .onKeyPress(.escape) { repo.searchQuery = ""; focused = false; return .handled }
            if !repo.searchQuery.isEmpty {
                Text(verbatim: repo.searchOrder.isEmpty ? "0" : "\(repo.searchCursor + 1)/\(repo.searchOrder.count)")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text3)
                    .contentTransition(.numericText())
                Button { repo.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(width: focused || !repo.searchQuery.isEmpty ? 230 : 170, height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.line))
        .animation(Theme.spring, value: focused)
        .padding(.trailing, 6)
        .help("Search by message, author or SHA. Return jumps to the next match. (⌘F)")
        .background(Button("") { focused = true }.keyboardShortcut("f").opacity(0))
    }
}
