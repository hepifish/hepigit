import XCTest
@testable import Hepigit

/// Runs real git scenarios through RepoModel's undo and checks the repo comes back byte for byte.
@MainActor
final class UndoTests: XCTestCase {
    var dir: URL!
    var repo: RepoModel!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hepigit-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sh("git init -q -b main && git config user.email t@t && git config user.name t")
        write("f.txt", "a\nb\nc\n"); sh("git add -A && git commit -qm init")
        repo = RepoModel(url: dir)
        await repo.load()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: helpers

    @discardableResult
    func sh(_ cmd: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try! p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    func write(_ name: String, _ text: String) { try! text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

    /// Everything a user could lose: files on disk, index, refs, HEAD, stashes.
    func fingerprint() -> String {
        sh("git status --porcelain=v2 --untracked-files=all; git rev-parse HEAD; git symbolic-ref -q HEAD; git for-each-ref refs/heads refs/tags; git stash list --format=%H; git diff; git diff --cached; for f in $(git ls-files -co --exclude-standard); do echo \"== $f\"; cat \"$f\"; done")
    }

    /// Takes a snapshot, runs `action` (as git commands), records it, undoes, and checks nothing drifted.
    func assertUndoRestores(_ action: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = fingerprint()
        let snap = await repo.snapshot()
        XCTAssertNotNil(snap, "snapshot failed", file: file, line: line)
        sh(action)
        XCTAssertNotEqual(fingerprint(), before, "the action changed nothing; bad test", file: file, line: line)
        let recorded = await repo.recordUndo(snap, label: "test")
        XCTAssertTrue(recorded, file: file, line: line)
        try await repo.undoLast()
        XCTAssertEqual(fingerprint(), before, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/MERGE_HEAD").path), file: file, line: line)
    }

    // MARK: scenarios

    func testPopWithConflict() async throws {
        sh("echo stash-line >> f.txt && echo new > u.txt && git stash push -qu -m mine && echo committed >> f.txt && git commit -qam other")
        try await assertUndoRestores("git stash pop --index")
        XCTAssertEqual(sh("git stash list --format=%gs").trimmingCharacters(in: .whitespacesAndNewlines), "On main: mine")
    }

    func testPopHalfAppliedOverDirtyFile() async throws {
        sh("echo stash-line >> f.txt && echo new > u.txt && git stash push -qu -m mine && echo my-wip >> f.txt")
        try await assertUndoRestores("git stash pop")
        XCTAssertNil(read("u.txt"), "the half-applied untracked file must be gone again")
        XCTAssertTrue(read("f.txt")!.contains("my-wip"))
    }

    func testCleanPop() async throws {
        sh("echo x >> f.txt && echo new > u.txt && git stash push -qu -m mine")
        try await assertUndoRestores("git stash pop")
    }

    func testCommitAndAmend() async throws {
        sh("echo more >> f.txt && echo staged > s.txt && git add s.txt")
        try await assertUndoRestores("git commit -qam next")
        try await assertUndoRestores("git commit -q --amend -m renamed")
    }

    func testDiscardIsUndoable() async throws {
        sh("echo precious >> f.txt && echo new > u.txt")
        try await assertUndoRestores("git restore f.txt && git clean -fdq")
        XCTAssertTrue(read("f.txt")!.contains("precious"))
    }

    func testHardReset() async throws {
        sh("echo 1 >> f.txt && git commit -qam one && echo dirty >> f.txt")
        try await assertUndoRestores("git reset -q --hard HEAD~1")
    }

    func testMergeConflict() async throws {
        sh("git switch -qc side && echo side >> f.txt && git commit -qam side && git switch -q main && echo main >> f.txt && git commit -qam main")
        try await assertUndoRestores("git merge side")
    }

    func testBranchDeleteAndCheckout() async throws {
        sh("git switch -qc feature && echo f >> f.txt && git commit -qam feat && git switch -q main")
        try await assertUndoRestores("git branch -D feature")
        try await assertUndoRestores("git switch -q feature")
    }

    func testStashDropAndPush() async throws {
        sh("echo a1 >> f.txt && git stash push -q -m one && echo a2 >> f.txt && git stash push -q -m two")
        try await assertUndoRestores("git stash drop -q stash@{1}")
        sh("echo wip >> f.txt")
        try await assertUndoRestores("git stash push -q -m three")
    }

    func testRefusesWhenSomethingChangedAfterwards() async throws {
        sh("echo wip >> f.txt")
        let snap = await repo.snapshot()
        sh("git commit -qam next")
        _ = await repo.recordUndo(snap, label: "commit")
        write("f.txt", "edited afterwards\n")
        let before = fingerprint()
        do { try await repo.undoLast(); XCTFail("undo must refuse") } catch {}
        XCTAssertEqual(fingerprint(), before, "a refused undo must not touch anything")
    }

    func testFetchLikeActionsRecordNothing() async throws {
        let snap = await repo.snapshot()
        sh("git update-ref refs/remotes/origin/main HEAD")
        let recorded = await repo.recordUndo(snap, label: "fetch")
        XCTAssertFalse(recorded)
    }
}
