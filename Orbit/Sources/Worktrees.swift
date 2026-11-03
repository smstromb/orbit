import Foundation
import Combine

struct WorktreeEntry: Identifiable {
    var id: String { url.path }
    let url: URL
    let branch: String
    let kind: String
    let locked: Bool
    var logical: UInt64?
    var allocated: UInt64?
    var files: UInt64?
    var issues: UInt64?
    var error: String?
}

enum WorktreeError: LocalizedError {
    case canceled, invalidRepository, gitFailed, measurementFailed
    var errorDescription: String? {
        switch self {
        case .canceled: return "Stopped"
        case .invalidRepository: return "Choose a Git checkout with an origin remote URL."
        case .gitFailed: return "Git could not read this checkout's metadata."
        case .measurementFailed: return "This checkout could not be measured."
        }
    }
}

// Each refresh owns its cancellation scope. The small registry is shared only
// to terminate active child processes when the user stops or closes the app.
final class WorktreeRun {
    private let lock = NSLock()
    private var stopped = false
    private var processes: [ObjectIdentifier: Process] = [:]
    var canceled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func start(_ process: Process) throws {
        if canceled { throw WorktreeError.canceled }
        try process.run()
        lock.lock()
        if stopped {
            lock.unlock()
            if process.isRunning { process.terminate() }
            throw WorktreeError.canceled
        }
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
    }
    func finished(_ process: Process) {
        lock.lock(); processes.removeValue(forKey: ObjectIdentifier(process)); lock.unlock()
    }
    func cancel() {
        lock.lock(); stopped = true; let active = Array(processes.values); lock.unlock()
        for process in active where process.isRunning { process.terminate() }
    }
}

struct WorktreeDiscovery {
    let entries: [WorktreeEntry]
    let unavailable: Int
}

struct GitWorktreeFinder {
    let run: WorktreeRun

    static func identity(_ remote: String) -> String? {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String; var path: String
        if text.contains("://"), let url = URLComponents(string: text), let name = url.host {
            host = name; path = url.path
        } else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            host = String(text[..<colon].split(separator: "@").last ?? "")
            path = String(text[text.index(after: colon)...])
        } else { return nil }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.lowercased().hasSuffix(".git") { path.removeLast(4) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        let normalizedHost = host.lowercased()
        return normalizedHost + "/" + (normalizedHost == "github.com" ? path.lowercased() : path)
    }

    private func git(_ root: URL, _ args: [String]) throws -> Data {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", root.path] + args
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] { environment.removeValue(forKey: key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_TERMINAL_PROMPT"] = "0"
        task.environment = environment
        let output = Pipe(); task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try run.start(task); defer { run.finished(task) }
        let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        if run.canceled { throw WorktreeError.canceled }
        guard task.terminationStatus == 0 else { throw WorktreeError.gitFailed }
        return data
    }
    private func gitLine(_ root: URL, _ args: [String]) throws -> String {
        var text = String(decoding: try git(root, args), as: UTF8.self)
        if text.last == "\n" { text.removeLast() }
        return text
    }
    private func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private func commonDirectory(_ root: URL) throws -> String {
        let path = try gitLine(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        return canonical(URL(fileURLWithPath: path)).path
    }
    private struct Registered {
        let url: URL
        let branch: String?
        let locked: Bool
    }
    private func registered(_ root: URL) throws -> [Registered] {
        let fields = String(decoding: try git(root, ["worktree", "list", "--porcelain", "-z"]), as: UTF8.self).components(separatedBy: "\0")
        var result: [Registered] = []; var path: String?; var branch: String?; var locked = false; var bare = false
        func finish() {
            if let path, !bare { result.append(Registered(url: URL(fileURLWithPath: path), branch: branch, locked: locked)) }
            path = nil; branch = nil; locked = false; bare = false
        }
        for field in fields {
            if field.isEmpty { finish() }
            else if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
            else if field.hasPrefix("branch refs/heads/") { branch = String(field.dropFirst(18)) }
            else if field == "detached" { branch = "Detached HEAD" }
            else if field == "locked" || field.hasPrefix("locked ") { locked = true }
            else if field == "bare" { bare = true }
        }
        finish(); return result
    }

    func discover(anchor: URL, candidates: [URL] = []) throws -> WorktreeDiscovery {
        guard FileManager.default.fileExists(atPath: anchor.appendingPathComponent(".git").path),
            try gitLine(anchor, ["rev-parse", "--show-prefix"]).isEmpty,
            let targetIdentity = Self.identity(try gitLine(anchor, ["remote", "get-url", "origin"])) else { throw WorktreeError.invalidRepository }
        let anchorCommon = try commonDirectory(anchor)
        var pending = try registered(anchor)
        pending += candidates.map { Registered(url: $0, branch: nil, locked: false) }
        var seen: Set<String> = []; var expanded: Set<String> = [anchorCommon]
        var entries: [WorktreeEntry] = []; var unavailable = 0; var position = 0
        while position < pending.count {
            if run.canceled { throw WorktreeError.canceled }
            let candidate = pending[position]; position += 1
            let root = canonical(candidate.url)
            guard seen.insert(root.path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
                if candidate.branch != nil { unavailable += 1 }; continue
            }
            do {
                guard try gitLine(root, ["rev-parse", "--show-prefix"]).isEmpty else { continue }
                let common = try commonDirectory(root)
                if common != anchorCommon {
                    guard Self.identity(try gitLine(root, ["remote", "get-url", "origin"])) == targetIdentity else { continue }
                }
                let branch = (try? gitLine(root, ["symbolic-ref", "--short", "HEAD"])) ?? "Detached HEAD"
                let gitDirectory = canonical(URL(fileURLWithPath: try gitLine(root, ["rev-parse", "--absolute-git-dir"])))
                let linked = gitDirectory.path != common
                let locked = linked && FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("locked").path)
                entries.append(WorktreeEntry(url: root, branch: branch,
                    kind: linked ? "Linked worktree" : common == anchorCommon ? "Main checkout" : "Clone checkout", locked: locked))
                if expanded.insert(common).inserted { pending += (try? registered(root)) ?? [] }
            } catch {
                if run.canceled { throw WorktreeError.canceled }
                if candidate.branch != nil { unavailable += 1 }
            }
        }
        return WorktreeDiscovery(entries: entries.sorted { $0.url.path < $1.url.path }, unavailable: unavailable)
    }

    static func candidates(in index: ScanResult, run: WorktreeRun) throws -> [URL] {
        var output: [URL] = []
        for id in index.nodes.indices {
            if id % 4096 == 0 && run.canceled { throw WorktreeError.canceled }
            guard index.nodes[id].name == ".git", var parent = index.nodes[id].parent else { continue }
            var parts: [String] = []
            while let p = index.nodes[parent].parent { parts.append(index.nodes[parent].name); parent = p }
            output.append(parts.reversed().reduce(URL(fileURLWithPath: index.root)) { $0.appendingPathComponent($1) })
        }
        return output
    }
}

final class WorktreeCatalog: ObservableObject {
    @Published var entries: [WorktreeEntry] = []
    @Published var busy = false
    @Published var status = "Choose a repository to find its worktrees"
    @Published var unavailable = 0
    @Published var searchedDisk = false
    @Published var diskIssues: UInt64 = 0
    @Published var error: String?
    @Published var search = ""
    private var generation = UUID()
    private var run = WorktreeRun()
    private var queue = OperationQueue()
    private var loaded = false
    var anchor: URL? {
        guard let path = UserDefaults.standard.string(forKey: "worktreeRepository"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
    var repositoryName: String { anchor?.lastPathComponent ?? "Choose a repository" }
    var partial: Int { entries.filter { ($0.issues ?? 0) > 0 }.count }
    var failed: Int { entries.filter { $0.error != nil }.count }
    var measured: Int { entries.filter { $0.allocated != nil || $0.error != nil }.count }
    func displayed(allocated: Bool) -> [WorktreeEntry] {
        entries.filter { search.isEmpty || $0.url.path.localizedCaseInsensitiveContains(search) || $0.branch.localizedCaseInsensitiveContains(search) }
            .sorted {
                let a = allocated ? $0.allocated : $0.logical, b = allocated ? $1.allocated : $1.logical
                if a != b { return (a ?? 0) > (b ?? 0) }
                return $0.url.path < $1.url.path
            }
    }
    func ensureLoaded(index: ScanResult?) { if !loaded && !busy { refresh(index: index) } }
    func stop() {
        generation = UUID(); run.cancel(); queue.cancelAllOperations(); busy = false
        status = loaded ? "Stopped · \(measured) of \(entries.count) sizes checked" : "Discovery stopped"
    }
    func selectRepository(_ url: URL, index: ScanResult?) {
        refresh(index: index, proposedAnchor: url)
    }
    func refresh(index: ScanResult?, proposedAnchor: URL? = nil) {
        stop(); let token = UUID(); generation = token
        let run = WorktreeRun(); self.run = run
        guard let anchor = proposedAnchor ?? self.anchor else {
            status = "Choose a repository to find its worktrees"; error = nil; return
        }
        busy = true; error = nil; status = "Reading Git worktree metadata…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let candidates = try index.map { try GitWorktreeFinder.candidates(in: $0, run: run) } ?? []
                let found = try GitWorktreeFinder(run: run).discover(anchor: anchor, candidates: candidates)
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if let proposedAnchor { UserDefaults.standard.set(found.entries.first(where: { $0.kind == "Main checkout" })?.url.path ?? proposedAnchor.path, forKey: "worktreeRepository") }
                    self.entries = found.entries; self.unavailable = found.unavailable
                    self.searchedDisk = index != nil; self.diskIssues = index?.nodes.first?.issues ?? 0
                    self.loaded = true
                    self.measure(token: token, run: run)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.busy = false; self.error = error.localizedDescription; self.status = "Could not read repository"
                }
            }
        }
    }
    private func measure(token: UUID, run: WorktreeRun) {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("orbit-scan") else { busy = false; return }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated
        self.queue = queue
        status = "Measuring 0 of \(entries.count) checkouts…"
        if entries.isEmpty { busy = false; status = "No matching checkouts found"; return }
        for entry in entries {
            queue.addOperation { [weak self] in
                if run.canceled { return }
                var stats: DiskNode?; var failure: String?
                let task = Process(); task.executableURL = executable
                task.arguments = [entry.url.path, "--summary", "--workers", "4"]
                let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
                do {
                    try run.start(task)
                    defer { run.finished(task) }
                    stats = try readScanStream(pipe.fileHandleForReading) { _ in }.nodes.first
                    task.waitUntilExit()
                    guard task.terminationStatus == 0 else { throw WorktreeError.measurementFailed }
                } catch {
                    if task.isRunning { task.terminate() }
                    stats = nil; failure = run.canceled ? nil : "Could not measure"
                }
                let result = stats; let message = failure
                DispatchQueue.main.async {
                    guard let self, self.generation == token, let id = self.entries.firstIndex(where: { $0.id == entry.id }) else { return }
                    self.entries[id].logical = result?.logical; self.entries[id].allocated = result?.allocated
                    self.entries[id].files = result?.files; self.entries[id].issues = result?.issues; self.entries[id].error = message
                    self.status = "Measuring \(self.measured) of \(self.entries.count) checkouts…"
                    if self.measured == self.entries.count { self.busy = false; self.status = "\(self.entries.count) checkouts · sizes checked" }
                }
            }
        }
    }
}
