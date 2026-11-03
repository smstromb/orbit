import Foundation

@main struct VerifyWorktrees {
    static func main() {
        do { try verify() }
        catch { fputs("Worktree discovery failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func verify() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        precondition(GitWorktreeFinder.identity("git@example.invalid:Example/sample-repository.git") == "example.invalid/Example/sample-repository")
        precondition(GitWorktreeFinder.identity("https://example.invalid/Example/sample-repository.git/") == "example.invalid/Example/sample-repository")
        precondition(GitWorktreeFinder.identity("ssh://git@example.invalid/Example/sample-repository.git") == "example.invalid/Example/sample-repository")
        precondition(GitWorktreeFinder.identity("https://other.example.invalid/Example/sample-repository.git") != "example.invalid/Example/sample-repository")
        precondition(GitWorktreeFinder.identity("https://example.invalid/another-owner/sample-repository.git") != "example.invalid/Example/sample-repository")
        precondition(GitWorktreeFinder.identity("https://example.invalid/Example/sample-repository.git") != GitWorktreeFinder.identity("https://example.invalid/example/sample-repository.git"))
        precondition(GitWorktreeFinder.identity("https://github.com/Example/Sample.git") == GitWorktreeFinder.identity("https://github.com/example/sample.git"))
        func node(_ name: String, _ parent: Int?, _ kind: String) -> DiskNode {
            DiskNode(name: name, parent: parent, logical: 0, allocated: 0, kind: kind, files: 0, folders: 0, issues: 0)
        }
        let index = ScanResult(root: "/disk", elapsed: 0, workers: 1, engine: "fixture", nodes: [
            node("disk", nil, "folder"), node("arbitrary checkout", 0, "folder"), node(".git", 1, "file"),
            node("elsewhere", 0, "folder"), node("nested", 3, "folder"), node(".git", 4, "folder"), node("file.txt", 1, "file")])
        let extracted = try GitWorktreeFinder.candidates(in: index, run: WorktreeRun()).map(\.path)
        precondition(extracted == ["/disk/arbitrary checkout", "/disk/elsewhere/nested"])
        let canceled = WorktreeRun(); canceled.cancel()
        do { _ = try GitWorktreeFinder.candidates(in: index, run: canceled); preconditionFailure("Canceled search continued") }
        catch WorktreeError.canceled {}
        let processRun = WorktreeRun()
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try processRun.start(child); let cancellationStart = Date(); processRun.cancel(); child.waitUntilExit()
        precondition(!child.isRunning && Date().timeIntervalSince(cancellationStart) < 2)
        let result = try GitWorktreeFinder(run: WorktreeRun()).discover(anchor: URL(fileURLWithPath: args[0]), candidates: args.dropFirst().map { URL(fileURLWithPath: $0) })
        let entries: [[String: Any]] = result.entries.map { ["path": $0.url.path, "branch": $0.branch, "kind": $0.kind, "locked": $0.locked] }
        let data = try JSONSerialization.data(withJSONObject: ["entries": entries, "unavailable": result.unavailable], options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
