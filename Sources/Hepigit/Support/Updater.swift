import AppKit

/// Checks GitHub Releases for a newer version and installs it in place.
/// The download comes through URLSession, so it carries no quarantine flag:
/// updates open without the right-click > Open dance.
@MainActor
enum Updater {
    private static let lastCheckKey = "lastUpdateCheck"

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    private static var repo: String? { Bundle.main.infoDictionary?["HepigitUpdateRepo"] as? String }
    private static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    /// At most once a day, quietly.
    static func checkOnLaunch() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        Task { await check(silent: true) }
    }

    static func check(silent: Bool) async {
        guard isBundled, let repo, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            if !silent { AppState.shared.toast(.info, "Updates aren't set up for this build", nil) }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Hepigit-Updater", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                if !silent { AppState.shared.toast(.error, "Couldn't check for updates", "No published release found at github.com/\(repo).") }
                return
            }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard isNewer(latest, than: currentVersion),
                  let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                if !silent { AppState.shared.toast(.success, "You're up to date", "Hepigit \(currentVersion) is the latest.") }
                return
            }
            offer(latest, notes: release.body, dmg: dmg.browser_download_url)
        } catch {
            if !silent { AppState.shared.toast(.error, "Couldn't check for updates", error.localizedDescription) }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func offer(_ version: String, notes: String?, dmg: URL) {
        let summary = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        AppState.shared.modal = Modal(
            title: "Hepigit \(version) is ready",
            message: (summary.isEmpty ? "" : summary + "\n\n") + "You have \(currentVersion). Your tabs and settings stay as they are.",
            confirm: "Install and restart", destructive: false) { _ in
                Task { await install(version, from: dmg) }
            }
    }

    private static func install(_ version: String, from url: URL) async {
        let app = AppState.shared
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            app.toast(.info, "Opening the download instead", "\(parent.path) isn't writable, so drag the new version in by hand.")
            NSWorkspace.shared.open(url)
            return
        }
        app.toast(.info, "Downloading Hepigit \(version)…", nil)
        do {
            let (file, _) = try await URLSession.shared.download(from: url)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("hepigit-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmgPath = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: file, to: dmgPath)
            let mount = work.appendingPathComponent("mnt")
            let staged = parent.appendingPathComponent(".Hepigit-\(version).app")
            try await shell("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmgPath.path])
            defer { Task { try? await shell("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) } }
            try? FileManager.default.removeItem(at: staged)
            try await shell("/usr/bin/ditto", [mount.appendingPathComponent("Hepigit.app").path, staged.path])

            // Swap the bundle once this process has exited, then relaunch.
            let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(target.path)" && mv "\(staged.path)" "\(target.path)"
            open "\(target.path)"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            app.toast(.error, "Update failed", error.localizedDescription)
        }
    }

    private static func shell(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { cont.resume() }
                else {
                    let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    cont.resume(throwing: GitError(message: msg.isEmpty ? "\(tool) failed" : msg))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
