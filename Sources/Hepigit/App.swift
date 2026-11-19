import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Warm up the login-shell PATH lookup off the main thread.
        DispatchQueue.global(qos: .utility).async { _ = Shell.gitPath }
        Task { @MainActor in Updater.checkOnLaunch() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct HepigitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private var app: AppState { AppState.shared }

    var body: some Scene {
        Window("Hepigit", id: "main") {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.check(silent: false) } }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { app.showOpenPanel() }.keyboardShortcut("o")
                Button("Clone Repository…") { app.showClone() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { if let r = app.active { app.close(r) } }.keyboardShortcut("w")
            }
            CommandMenu("Repository") {
                Button("Refresh") { app.active?.refresh() }.keyboardShortcut("r")
                Divider()
                Button("Fetch") { app.active?.fetch() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Pull") { app.active?.pull() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Push") { app.active?.push() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Force Push…") { app.active?.confirmForcePush() }
                Divider()
                Button("New Branch…") { app.active?.newBranch() }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Stash Changes…") { app.active?.stash() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Pop Stash") { app.active?.popStash() }.keyboardShortcut("s", modifiers: [.command, .option, .shift])
                Divider()
                Button("Undo Last Commit…") { app.active?.undoLastCommit() }
                Button("Show Changes") { app.active?.select(.wip) }.keyboardShortcut("0")
                Divider()
                Button("Open in Terminal") { app.active?.openInTerminal() }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("Reveal in Finder") { app.active?.openInFinder() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Next Tab") { app.selectTab(offset: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { app.selectTab(offset: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                ForEach(1..<10) { n in
                    Button("Tab \(n)") {
                        if app.repos.indices.contains(n - 1) { app.activate(app.repos[n - 1].id) }
                    }.keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }
            }
        }
    }
}
