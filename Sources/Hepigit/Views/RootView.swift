import SwiftUI

struct RootView: View {
    private var app: AppState { AppState.shared }
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            Rectangle().fill(Theme.line).frame(height: 1)
            ZStack {
                if let repo = app.active {
                    RepoView(repo: repo).id(repo.id)
                        .transition(.opacity)
                } else {
                    WelcomeView().transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: app.activeID)
        }
        .sheet(item: Binding(get: { app.scan }, set: { app.scan = $0 })) { scan in
            RepoPicker(scan: scan) { app.scan = nil }
                .presentationBackground(Theme.panel)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .padding(8).allowsHitTesting(false).transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { ToastStack() }
        .sheet(item: Binding(get: { app.modal }, set: { app.modal = $0 })) { m in
            ModalCard(modal: m) { app.modal = nil }
                .presentationBackground(Theme.panel)
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { for u in urls { await app.open(u) } }
            return true
        } isTargeted: { t in withAnimation(.easeOut(duration: 0.15)) { dropTargeted = t } }
        .frame(minWidth: 1000, minHeight: 620)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - Tabs

struct TabStrip: View {
    private var app: AppState { AppState.shared }
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 78)   // traffic lights
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(app.repos) { repo in
                        RepoTab(repo: repo, active: repo.id == app.activeID, ns: ns)
                    }
                    IconButton(icon: "plus", help: "Open repository (⌘O)", size: 26) { app.showOpenPanel() }
                        .padding(.leading, 4)
                }
                .padding(.vertical, 5)
            }
            Spacer(minLength: 40)
        }
        .frame(height: 40)
        .background(Theme.panel.gesture(WindowDragGesture()))
        .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
    }
}

private struct RepoTab: View {
    let repo: RepoModel
    let active: Bool
    let ns: Namespace.ID
    @State private var hover = false
    @State private var dropHover = false
    private var app: AppState { AppState.shared }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(repo.isLoaded && repo.status.isDirty ? Theme.gold : Theme.text3.opacity(0.5))
                .frame(width: 6, height: 6)
                .help(repo.isLoaded && repo.status.isDirty ? "Uncommitted changes" : "")
            Text(repo.name)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Theme.text : Theme.text2)
                .lineLimit(1)
            Button { app.close(repo) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(hover ? Theme.hover : .clear))
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(Theme.text3)
            .opacity(hover || active ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 30)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 8).fill(Theme.raised)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Theme.accent).frame(height: 2).padding(.horizontal, 10)
                    }
                    .matchedGeometryEffect(id: "tab", in: ns)
            } else if hover || dropHover {
                RoundedRectangle(cornerRadius: 8).fill(Theme.raised.opacity(0.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.spring) { app.activate(repo.id) } }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(repo.url.path)
        .draggable(repo.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            withAnimation(Theme.spring) { app.move(id, before: repo.id) }
            return true
        } isTargeted: { dropHover = $0 }
        .contextMenu {
            Button("Reveal in Finder") { repo.openInFinder() }
            Button("Open in Terminal") { repo.openInTerminal() }
            Button("Copy Path") { copy(repo.url.path) }
            Divider()
            Button("Close Tab") { app.close(repo) }
        }
    }
}

@MainActor func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    AppState.shared.toast(.success, "Copied", s.count > 60 ? String(s.prefix(60)) + "…" : s)
}

// MARK: - Welcome

struct WelcomeView: View {
    private var app: AppState { AppState.shared }
    @State private var appear = false

    var body: some View {
        VStack(spacing: 22) {
            GraphMark().frame(width: 110, height: 110)
                .scaleEffect(appear ? 1 : 0.85).opacity(appear ? 1 : 0)
            VStack(spacing: 8) {
                Text("hepigit").font(.system(size: 36, weight: .medium, design: .serif))
                Text("Your repositories, quietly in one place.")
                    .font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            .offset(y: appear ? 0 : 8).opacity(appear ? 1 : 0)
            HStack(spacing: 10) {
                PillButton(title: "Open repository", icon: "folder", primary: true) { app.showOpenPanel() }
                PillButton(title: "Clone", icon: "arrow.down.circle") { app.showClone() }
            }
            .opacity(appear ? 1 : 0)
            Text("or drop a repo, or a whole folder of them, anywhere  ·  ⌘O").font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) { appear = true } }
    }
}

/// The app's mark: an ichthys drawn as two branches leaving HEAD at the mouth and crossing at the tail.
/// Same geometry as the app icon (scripts/make-icon.swift).
struct GraphMark: View {
    var body: some View {
        Canvas { ctx, size in
            let w = min(size.width, size.height)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: w * y) }
            let m = p(0.79, 0.50)
            let up = [m, p(0.60, 0.15), p(0.33, 0.22), p(0.15, 0.71)]
            let dn = [m, p(0.60, 0.85), p(0.33, 0.78), p(0.15, 0.29)]
            func at(_ c: [CGPoint], _ t: CGFloat) -> CGPoint {
                let u = 1 - t, a = u * u * u, b = 3 * u * u * t, cc = 3 * u * t * t, d = t * t * t
                return CGPoint(x: a * c[0].x + b * c[1].x + cc * c[2].x + d * c[3].x,
                               y: a * c[0].y + b * c[1].y + cc * c[2].y + d * c[3].y)
            }
            func curve(_ c: [CGPoint]) -> Path {
                var path = Path(); path.move(to: c[0]); path.addCurve(to: c[3], control1: c[1], control2: c[2]); return path
            }
            let line = StrokeStyle(lineWidth: w * 0.046, lineCap: .round)
            ctx.stroke(curve(dn), with: .color(Theme.lane(1)), style: line)
            ctx.stroke(curve(up), with: .color(Theme.lane(0)), style: line)
            func circle(_ c: CGPoint, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
            func node(_ c: CGPoint, _ r: CGFloat, _ col: Color) {
                ctx.fill(circle(c, r), with: .color(col))
                ctx.fill(circle(c, r * 0.44), with: .color(Theme.bg))
            }
            ctx.fill(circle(m, w * 0.092), with: .color(Theme.lane(0).opacity(0.22)))
            node(m, w * 0.058, Theme.lane(0))
            node(at(up, 0.36), w * 0.05, Theme.lane(0))
            node(at(dn, 0.36), w * 0.05, Theme.lane(1))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Toasts

struct ToastStack: View {
    private var app: AppState { AppState.shared }
    var body: some View {
        VStack(spacing: 8) {
            ForEach(app.toasts) { t in
                ToastCard(toast: t)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                                            removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
        }
        .padding(.bottom, 22)
    }
}

private struct ToastCard: View {
    let toast: Toast
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .symbolEffect(.bounce, value: toast.id)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title).font(.system(size: 12.5, weight: .semibold))
                if let d = toast.detail, !d.isEmpty {
                    Text(d).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                        .lineLimit(toast.kind == .error ? 8 : 2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let a = toast.action {
                Button(a.title) { AppState.shared.dismiss(toast.id); a.run() }
                    .buttonStyle(PressStyle())
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.hover))
            }
            if hover && toast.kind == .error, let d = toast.detail {
                IconButton(icon: "doc.on.doc", help: "Copy error", size: 20) { copy(d) }
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3).padding(.vertical, 12)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .onHover { hover = $0 }
        .onTapGesture { AppState.shared.dismiss(toast.id) }
    }

    private var icon: String {
        switch toast.kind { case .success: "checkmark.circle.fill"; case .error: "exclamationmark.triangle.fill"; case .info: "info.circle.fill" }
    }
    private var tint: Color {
        switch toast.kind { case .success: Theme.olive; case .error: Theme.danger; case .info: Theme.info }
    }
}

// MARK: - Modal

struct ModalCard: View {
    let modal: Modal
    let close: () -> Void
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(modal.title).font(.system(size: 18, weight: .medium, design: .serif))
            if let msg = modal.message {
                Text(msg).font(.system(size: 12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            if let f = modal.field {
                TextField(f.placeholder, text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.line))
                    .focused($focused)
                    .onSubmit(submit)
            }
            HStack(spacing: 8) {
                if let s = modal.secondary {
                    PillButton(title: s.title) { close(); s.action() }
                }
                Spacer()
                PillButton(title: "Cancel") { close() }.keyboardShortcut(.cancelAction)
                PillButton(title: modal.confirm, primary: !modal.destructive, destructive: modal.destructive) { submit() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 420)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .onAppear {
            value = modal.field?.initial ?? ""
            DispatchQueue.main.async { focused = true }
        }
    }

    private func submit() {
        let action = modal.action, v = value
        close()
        action(v)
    }
}
