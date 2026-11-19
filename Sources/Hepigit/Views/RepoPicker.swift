import SwiftUI

/// Checklist of repositories found inside a folder. Nothing is preselected: you open the few you work on.
struct RepoPicker: View {
    let scan: FolderScan
    let close: () -> Void
    @State private var chosen: Set<String> = []
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    private var app: AppState { AppState.shared }

    private var visible: [FolderScan.Found] {
        filter.isEmpty ? scan.repos : scan.repos.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || ($0.remote ?? "").localizedCaseInsensitiveContains(filter)
        }
    }
    private func isOpen(_ r: FolderScan.Found) -> Bool { app.repos.contains { $0.id == r.id } }

    var body: some View {
        let selectable = visible.filter { !isOpen($0) }
        let allOn = !selectable.isEmpty && selectable.allSatisfy { chosen.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(scan.repos.count) repositories in \(scan.root.lastPathComponent)")
                    .font(.system(size: 18, weight: .medium, design: .serif))
                Text("Most recently used first. Pick the ones you want as tabs.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            .padding([.horizontal, .top], 22).padding(.bottom, 14)

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
                    TextField("Filter by name or remote", text: $filter).textFieldStyle(.plain).font(.system(size: 12))
                        .focused($filterFocused)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(filterFocused ? Theme.accent.opacity(0.6) : Theme.line))
                Button(allOn ? "Select none" : "Select all") {
                    withAnimation(.snappy(duration: 0.2)) {
                        if allOn { selectable.forEach { chosen.remove($0.id) } } else { selectable.forEach { chosen.insert($0.id) } }
                    }
                }
                .buttonStyle(PressStyle()).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text2)
                .disabled(selectable.isEmpty)
            }
            .padding(.horizontal, 22).padding(.bottom, 10)

            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(visible) { r in row(r) }
                    if visible.isEmpty {
                        Text("No match").font(.system(size: 12)).foregroundStyle(Theme.text3).padding(24)
                    }
                }
                .padding(8)
            }
            .frame(height: 380)
            Rectangle().fill(Theme.line).frame(height: 1)

            HStack {
                Spacer()
                PillButton(title: "Cancel") { close() }.keyboardShortcut(.cancelAction)
                PillButton(title: chosen.isEmpty ? "Choose repositories" : "Open \(chosen.count) \(chosen.count == 1 ? "repository" : "repositories")",
                           primary: true, disabled: chosen.isEmpty) {
                    let urls = scan.repos.filter { chosen.contains($0.id) }.map(\.url)
                    close()
                    app.openAll(urls)
                }
                .keyboardShortcut(.defaultAction)
                .animation(.snappy(duration: 0.2), value: chosen.count)
            }
            .padding(16)
        }
        .frame(width: 560)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
    }

    private func row(_ r: FolderScan.Found) -> some View {
        let open = isOpen(r)
        let on = open || chosen.contains(r.id)
        return HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? (open ? Theme.text3 : Theme.accent) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? .clear : Theme.text3, lineWidth: 1.2))
                .overlay { if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)) } }
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.name).font(.system(size: 13, weight: .medium))
                    if r.parent != scan.root.lastPathComponent {
                        Text(r.parent).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: r.remote == nil ? "icloud.slash" : "cloud").font(.system(size: 9))
                    Text(r.remote ?? "Local only, no remote").lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11)).foregroundStyle(r.remote == nil ? Theme.gold.opacity(0.8) : Theme.text3)
            }
            Spacer()
            if open {
                Text("Already open").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
            } else {
                Text(r.lastActive == .distantPast ? "" : RelTime.short(r.lastActive))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
                    .help(RelTime.full.string(from: r.lastActive))
            }
        }
        .padding(.horizontal, 12).frame(height: 46)
        .contentShape(Rectangle())
        .hoverRow(selected: false)
        .opacity(open ? 0.55 : 1)
        .onTapGesture {
            guard !open else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                if chosen.contains(r.id) { chosen.remove(r.id) } else { chosen.insert(r.id) }
            }
        }
    }
}
