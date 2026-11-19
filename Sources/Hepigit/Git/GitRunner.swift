import Foundation

struct GitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct GitResult {
    let out: Data
    let err: String
    let code: Int32
    var text: String { String(decoding: out, as: UTF8.self) }
}

/// Resolves the user's real environment once (GUI apps launch with a bare PATH),
/// so hooks, LFS and Homebrew git behave exactly like in the terminal.
enum Shell {
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = loginPath() ?? ((env["PATH"] ?? "") + ":" + fallback)
        env["GIT_TERMINAL_PROMPT"] = "0"     // never hang waiting for a tty
        env["GIT_OPTIONAL_LOCKS"] = "0"      // reads never touch .git/index (no watcher feedback loops)
        env["GIT_PAGER"] = "cat"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }()

    static let gitPath: String = {
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs where dir != "/usr/bin" {
            let p = dir + "/git"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/git"
    }()

    private static func loginPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '__HG__%s__HG__' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = DispatchTime.now() + 4
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self)
        guard let a = s.range(of: "__HG__"), let b = s.range(of: "__HG__", range: a.upperBound..<s.endIndex) else { return nil }
        let path = String(s[a.upperBound..<b.lowerBound])
        return path.isEmpty ? nil : path
    }
}

struct Git {
    let root: URL

    /// Runs git and returns stdout. Throws with git's own stderr on failure.
    @discardableResult
    func run(_ args: [String], input: Data? = nil, okCodes: Set<Int32> = [0]) async throws -> Data {
        let r = await Git.exec(args, cwd: root, input: input)
        guard okCodes.contains(r.code) else {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: msg.isEmpty ? "git \(args.first ?? "") failed (\(r.code))" : msg)
        }
        return r.out
    }

    func text(_ args: [String], okCodes: Set<Int32> = [0]) async throws -> String {
        String(decoding: try await run(args, okCodes: okCodes), as: UTF8.self)
    }

    static func exec(_ args: [String], cwd: URL, input: Data? = nil) async -> GitResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Shell.gitPath)
                p.arguments = ["--literal-pathspecs", "-c", "core.quotepath=off", "-c", "color.ui=false"] + args
                p.currentDirectoryURL = cwd
                p.environment = Shell.environment
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = input == nil ? FileHandle.nullDevice : inp
                do { try p.run() } catch {
                    cont.resume(returning: GitResult(out: Data(), err: error.localizedDescription, code: -1))
                    return
                }
                if let input {
                    DispatchQueue.global().async {
                        inp.fileHandleForWriting.write(input)
                        try? inp.fileHandleForWriting.close()
                    }
                }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: GitResult(out: outData, err: String(decoding: errData, as: UTF8.self), code: p.terminationStatus))
            }
        }
    }
}
