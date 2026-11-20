import XCTest
@testable import Hepigit

final class ConflictParseTests: XCTestCase {
    let two = "top\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> abc123 msg\nmid\n<<<<<<< HEAD\nA\n=======\n>>>>>>> abc123 msg\nend\n"

    func testParsesBlocksAndLabels() throws {
        let d = try XCTUnwrap(ConflictDoc.parse(two))
        XCTAssertEqual(d.blocks.count, 2)
        XCTAssertEqual(d.blocks[0].current, "mine\n")
        XCTAssertEqual(d.blocks[0].incoming, "theirs\n")
        XCTAssertEqual(d.blocks[0].currentLabel, "HEAD")
        XCTAssertEqual(d.blocks[0].incomingLabel, "abc123 msg")
        XCTAssertEqual(d.blocks[1].incoming, "")
    }

    func testResolvingRewritesOnlyThatBlock() throws {
        let d = try XCTUnwrap(ConflictDoc.parse(two))
        let first = d.resolving(0, .both)
        XCTAssertTrue(first.hasPrefix("top\nmine\ntheirs\nmid\n<<<<<<< HEAD\n"))
        let all = try XCTUnwrap(ConflictDoc.parse(first)).resolving(0, .incoming)
        XCTAssertEqual(all, "top\nmine\ntheirs\nmid\nend\n")
        XCTAssertNil(ConflictDoc.parse(all), "no markers left")
        XCTAssertEqual(d.resolving(0, .current), "top\nmine\nmid\n<<<<<<< HEAD\nA\n=======\n>>>>>>> abc123 msg\nend\n")
    }

    func testDiff3BaseAndCRLF() throws {
        let t = "<<<<<<< ours\r\nx\r\n||||||| base\r\nb\r\n=======\r\ny\r\n>>>>>>> theirs\r\nz\r\n"
        let d = try XCTUnwrap(ConflictDoc.parse(t))
        XCTAssertEqual(d.blocks[0].current, "x\r\n")
        XCTAssertEqual(d.blocks[0].base, "b\r\n")
        XCTAssertEqual(d.blocks[0].incoming, "y\r\n")
        XCTAssertEqual(d.resolving(0, .both), "x\r\ny\r\nz\r\n")
    }

    func testUnfinishedOrLookalikeMarkersAreNotConflicts() {
        XCTAssertNil(ConflictDoc.parse("<<<<<<< HEAD\nonly\n"))
        XCTAssertNil(ConflictDoc.parse("<<<<<<<<< not a marker\n========\n"))
        XCTAssertNil(ConflictDoc.parse("plain text\n"))
    }
}

/// End to end against real git, reusing UndoTests' temp repo helpers.
extension UndoTests {
    /// Pati's case: both sides appended different lines to the end of .gitignore.
    func makeGitignoreConflict() async {
        sh("printf 'node_modules\\n' > .gitignore && git add -A && git commit -qm base && git checkout -qb other")
        sh("printf 'node_modules\\n.gstack/\\n' > .gitignore && git commit -qam theirs && git checkout -q main")
        sh("printf 'node_modules\\n/.DS_Store\\n' > .gitignore && git commit -qam mine && git merge -q other")
        await repo.refreshStatus()
    }

    func testResolveBlockKeepBothThenMarkResolved() async throws {
        await makeGitignoreConflict()
        let f = try XCTUnwrap(repo.status.conflicts.first)
        XCTAssertEqual(f.path, ".gitignore")
        let c = await repo.conflict(f)
        XCTAssertEqual(c.doc?.blocks.count, 1)
        XCTAssertTrue(c.hasCurrent && c.hasIncoming)
        repo.resolveBlock(f, 0, .both); await waitIdle(); await repo.refreshStatus()
        XCTAssertEqual(read(".gitignore"), "node_modules\n/.DS_Store\n.gstack/\n")
        XCTAssertFalse(repo.status.conflicts.isEmpty, "picking doesn't stage on its own")
        repo.stage(f); await waitIdle(); await repo.refreshStatus()
        XCTAssertTrue(repo.status.conflicts.isEmpty)
        XCTAssertEqual(repo.operation, .merge, "merge still waits for Continue")
    }

    func testResolveWholeFileTakesIncoming() async throws {
        await makeGitignoreConflict()
        let f = try XCTUnwrap(repo.status.conflicts.first)
        repo.resolveFile(f, current: false, sideExists: true); await waitIdle(); await repo.refreshStatus()
        XCTAssertEqual(read(".gitignore"), "node_modules\n.gstack/\n")
        XCTAssertTrue(repo.status.conflicts.isEmpty)
    }

    func testDeletedOnOneSide() async throws {
        sh("git checkout -qb other && git rm -q f.txt && git commit -qm gone && git checkout -q main")
        sh("echo changed >> f.txt && git commit -qam edit && git merge -q other")
        await repo.refreshStatus()
        let f = try XCTUnwrap(repo.status.conflicts.first)
        let c = await repo.conflict(f)
        XCTAssertNil(c.doc)
        XCTAssertTrue(c.hasCurrent); XCTAssertFalse(c.hasIncoming)
        repo.resolveFile(f, current: false, sideExists: c.hasIncoming); await waitIdle(); await repo.refreshStatus()
        XCTAssertNil(read("f.txt"), "keeping the deleting side deletes the file")
        XCTAssertTrue(repo.status.conflicts.isEmpty)
    }

    func testStashPopConflictShowsWithoutOperation() async throws {
        sh("echo stash-line >> f.txt && git stash push -qm mine && echo committed >> f.txt && git commit -qam other && git stash pop")
        await repo.refreshStatus()
        XCTAssertNil(repo.operation)
        let f = try XCTUnwrap(repo.status.conflicts.first)
        let popped = await repo.conflict(f)
        let doc = try XCTUnwrap(popped.doc)
        XCTAssertEqual(doc.blocks[0].incomingLabel, "Stashed changes")
        repo.resolveBlock(f, 0, .both); await waitIdle(); await repo.refreshStatus()
        XCTAssertEqual(read("f.txt"), "a\nb\nc\ncommitted\nstash-line\n")
    }
}
