import SwiftUI
import AppKit

let appBackground = Color(red: 0.047, green: 0.055, blue: 0.075)
let panel = Color(red: 0.067, green: 0.078, blue: 0.102)
let muted = Color(red: 0.48, green: 0.53, blue: 0.62)
let accent = Color(red: 0.64, green: 0.70, blue: 1)
let palette: [Color] = [Color(red:0.98,green:0.40,blue:0.43), Color(red:0.99,green:0.65,blue:0.35), Color(red:0.88,green:0.77,blue:0.38), Color(red:0.38,green:0.76,blue:0.59), Color(red:0.29,green:0.70,blue:0.80), Color(red:0.38,green:0.53,blue:0.92), Color(red:0.63,green:0.48,blue:0.91), Color(red:0.85,green:0.43,blue:0.70)]
func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
func number(_ value: UInt64) -> String { value.formatted() }

struct Arc: Identifiable {
    let id: Int
    let node: Int
    var start: Double
    var end: Double
    var inner: Double
    var outer: Double
    var opacity: Double
    let color: Color
    let label: String
}
struct Layout {
    let arcs: [Arc]
    let children: [Int]
}

final class Explorer: ObservableObject {
    @Published var showingWorktrees = false
    @Published var result: ScanResult?
    @Published var current = 0
    @Published var hovered: Int?
    @Published var selected: Int?
    @Published var scanning = false
    @Published var progressFiles: UInt64 = 0
    @Published var progressBytes: UInt64 = 0
    @Published var progressAllocated: UInt64 = 0
    @Published var diskSpace: DiskSpace?
    @Published var progressPath = ""
    @Published var progressWorkers = 1
    @Published var waitingForFilesystem = false
    @Published var scanTarget = ""
    @Published var status = "Choose a folder to explore"
    @Published var error: String?
    @Published var allocated = true { didSet { if oldValue != allocated && !showingWorktrees { refreshLayout() } } }
    @Published var search = ""
    @Published var arcs: [Arc] = []
    @Published var oldArcs: [Arc] = []
    @Published var animation = 1.0
    @Published var children: [Int] = []
    @Published var layoutBusy = false
    private var spacePath: String?
    private var spaceRefreshID = UUID()
    private var process: Process?
    private var scanID = UUID()
    private var layoutID = UUID()
    var progressSize: UInt64 { allocated ? progressAllocated : progressBytes }
    var rootURL: URL? { result.map { URL(fileURLWithPath: $0.root) } }
    var node: DiskNode? { result?.nodes[current] }
    var inspection: DiskNode? { guard let r = result else { return nil }; return r.nodes[hovered ?? selected ?? current] }
    var filteredChildren: [Int] { guard let r = result else { return [] }; return search.isEmpty ? children : children.filter { r.nodes[$0].name.localizedCaseInsensitiveContains(search) } }
    var crumbs: [Int] { guard let r = result else { return [] }; var ids = [current]; while let p = r.nodes[ids.last!].parent { ids.append(p) }; return ids.reversed() }
    func url(_ id: Int) -> URL? {
        guard let r = result else { return nil }
        var parts: [String] = []; var i = id
        while let p = r.nodes[i].parent { parts.append(r.nodes[i].name); i = p }
        return parts.reversed().reduce(URL(fileURLWithPath: r.root)) { $0.appendingPathComponent($1) }
    }
    func color(_ id: Int) -> Color {
        guard let r = result else { return accent }
        return palette[r.nodes[id].branch % palette.count]
    }
    func chooseFolder() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false; picker.prompt = "Scan folder"; picker.message = "Choose a folder to map its storage."
        if picker.runModal() == .OK, let url = picker.url { scan(url) }
    }
    func cancel() {
        scanID = UUID(); process?.terminate(); process = nil; scanning = false
        status = result == nil ? "Scan canceled" : "Scan canceled · previous results shown"
    }
    func scan(_ url: URL, afterScan: ((ScanResult) -> Void)? = nil) {
        showingWorktrees = false
        cancel(); let token = UUID(); scanID = token; let scanStarted = Date()
        scanning = true; error = nil; progressFiles = 0; progressBytes = 0; progressAllocated = 0; waitingForFilesystem = false; progressPath = url.path; scanTarget = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
        status = "Reading storage metadata…"
        if result == nil { spacePath = url.path; refreshDiskSpace() }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("orbit-scan") else { return }
        let task = Process(); task.executableURL = executable; task.arguments = [url.path, "--binary"]
        let output = Pipe(); let errors = Pipe(); task.standardOutput = output; task.standardError = errors
        process = task
        do { try task.run() } catch { scanning = false; self.error = error.localizedDescription; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var completed: ScanResult?; var failure: String?
            do {
                var decoded = try readScanStream(output.fileHandleForReading) { update in
                    DispatchQueue.main.async {
                        guard let self, self.scanID == token else { return }
                        self.progressFiles = update.files; self.progressBytes = update.bytes; self.progressAllocated = update.allocated ?? 0
                        self.progressPath = update.path; self.progressWorkers = update.workers ?? 1
                        self.waitingForFilesystem = update.waiting ?? false
                    }
                }
                DispatchQueue.main.async { guard let self, self.scanID == token else { return }; self.progressPath = "Preparing map…"; self.waitingForFilesystem = false }
                for i in decoded.nodes.indices.dropFirst() { if let p = decoded.nodes[i].parent { decoded.nodes[p].children.append(i) } }
                let roots = decoded.nodes[0].children.sorted { decoded.nodes[$0].logical > decoded.nodes[$1].logical }
                for (rank, id) in roots.enumerated() { decoded.nodes[id].branch = rank }
                for i in decoded.nodes.indices.dropFirst() { if let p = decoded.nodes[i].parent { decoded.nodes[i].level = decoded.nodes[p].level + 1; if p != 0 { decoded.nodes[i].branch = decoded.nodes[p].branch } } }
                completed = decoded
            } catch { failure = error.localizedDescription; task.terminate() }
            task.waitUntilExit()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            let final = completed; let space = completed.flatMap { try? DiskSpace.read(path: $0.root) }; let message = failure ?? String(data: errorData, encoding: .utf8)
            DispatchQueue.main.async {
                guard let self, self.scanID == token else { return }
                self.scanning = false; self.process = nil
                guard task.terminationStatus == 0, let final else { self.error = message?.isEmpty == false ? message : "The folder could not be scanned."; self.status = "Scan failed"; return }
                self.layoutID = UUID()
                self.children = []; self.arcs = []; self.oldArcs = []
                self.current = 0; self.selected = nil; self.hovered = nil; self.search = ""
                self.spaceRefreshID = UUID()
                self.diskSpace = space; self.spacePath = final.root
                self.result = final
                self.status = "Mapped in \(String(format: "%.1f", Date().timeIntervalSince(scanStarted)))s · \(final.workers ?? 1) workers"
                if let afterScan { afterScan(final) } else { self.refreshLayout() }
            }
        }
    }
    func refreshDiskSpace() {
        guard let path = result?.root ?? spacePath else { return }
        let token = UUID(); spaceRefreshID = token
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let space = try? DiskSpace.read(path: path)
            DispatchQueue.main.async {
                guard let self, self.spaceRefreshID == token, (self.result?.root ?? self.spacePath) == path else { return }
                self.diskSpace = space
            }
        }
    }
    func navigate(_ id: Int) {
        guard let r = result else { return }
        if !r.nodes[id].isFolder { selected = id; reveal(id); return }
        guard id != current else { return }
        current = id; selected = nil; hovered = nil; search = ""; refreshLayout()
    }
    func up() { if let p = node?.parent { navigate(p) } }
    func reveal(_ id: Int) { if let target = url(id) { NSWorkspace.shared.activateFileViewerSelecting([target]) } }
    func copyPath(_ id: Int) { if let target = url(id) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(target.path, forType: .string) } }
    func refreshLayout() {
        guard let result else { return }
        let focus = current; let mode = allocated; let token = UUID(); layoutID = token; layoutBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let layout = Self.layout(result, focus: focus, allocated: mode)
            DispatchQueue.main.async {
                guard let self, self.layoutID == token else { return }
                self.oldArcs = self.arcs; self.arcs = layout.arcs; self.children = layout.children; self.animation = 0; self.layoutBusy = false
                DispatchQueue.main.async { withAnimation(.timingCurve(0.22, 0.68, 0.10, 1, duration: 0.58)) { self.animation = 1 } }
            }
        }
    }
    static func layout(_ result: ScanResult, focus: Int, allocated: Bool) -> Layout {
        let nodes = result.nodes
        func sorted(_ id: Int) -> [Int] { nodes[id].children.sorted { let a = nodes[$0].size(allocated), b = nodes[$1].size(allocated); return a == b ? nodes[$0].name < nodes[$1].name : a > b } }
        let total = Double(nodes[focus].size(allocated)); guard total > 0 else { return Layout(arcs: [], children: sorted(focus)) }
        var arcs: [Arc] = []
        func walk(_ parent: Int, _ start: Double, _ span: Double, _ depth: Int) {
            guard depth < 5, arcs.count < 3500 else { return }
            let amount = Double(nodes[parent].size(allocated)); guard amount > 0 else { return }
            var angle = start; var tinyStart: Double?; var tinySpan = 0.0; var tinyCount = 0
            let inner = 0.31 + Double(depth) * 0.136
            for id in sorted(parent) {
                let child = nodes[id]; let width = span * Double(child.size(allocated)) / amount
                guard width > 0 else { continue }
                if width < 0.006 || arcs.count >= 3500 {
                    if tinyStart == nil { tinyStart = angle }; tinySpan += width; tinyCount += 1
                } else {
                    let color = palette[child.branch % palette.count]
                    arcs.append(Arc(id: id, node: id, start: angle, end: angle + width, inner: inner, outer: inner + 0.13, opacity: max(0.5, 1 - Double(depth) * 0.095), color: color, label: child.name))
                    if child.isFolder { walk(id, angle, width, depth + 1) }
                }
                angle += width
            }
            if let tinyStart { arcs.append(Arc(id: -parent-1, node: parent, start: tinyStart, end: tinyStart + tinySpan, inner: inner, outer: inner + 0.13, opacity: 0.35, color: palette[nodes[parent].branch % palette.count], label: "\(tinyCount) smaller items")) }
        }
        walk(focus, -.pi / 2, .pi * 2, 0)
        return Layout(arcs: arcs, children: sorted(focus))
    }
}

struct SunburstDrawing: View, Animatable {
    let previous: [Arc]
    let arcs: [Arc]
    let hovered: Int?
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) * 0.47
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let newIDs = Set(arcs.map(\.id))
            let all = arcs + previous.filter { !newIDs.contains($0.id) }
            for arc in all {
                let target = newIDs.contains(arc.id) ? arc : Arc(id:arc.id,node:arc.node,start:arc.start,end:arc.end,inner:arc.inner,outer:arc.outer,opacity:0,color:arc.color,label:arc.label)
                let source = old[arc.id] ?? Arc(id:arc.id,node:arc.node,start:arc.start,end:arc.end,inner:arc.inner * 0.92,outer:arc.outer * 0.92,opacity:0,color:arc.color,label:arc.label)
                func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
                let start = mix(source.start, target.start), end = mix(source.end, target.end)
                let inner = mix(source.inner, target.inner) * radius, outer = mix(source.outer, target.outer) * radius
                let opacity = mix(source.opacity, target.opacity)
                guard end - start > 0.001, opacity > 0.001 else { continue }
                let gap = min(0.009, (end - start) * 0.12)
                var path = Path()
                path.addArc(center: center, radius: outer, startAngle: .radians(start + gap), endAngle: .radians(end - gap), clockwise: false)
                path.addArc(center: center, radius: inner, startAngle: .radians(end - gap), endAngle: .radians(start + gap), clockwise: true)
                path.closeSubpath()
                let active = hovered == arc.node && arc.id >= 0
                context.fill(path, with: .color(arc.color.opacity(active ? min(1, opacity + 0.20) : opacity)))
                if active { context.stroke(path, with: .color(.white.opacity(0.72)), lineWidth: 1.25) }
                if arc.inner < 0.32 && end - start > 0.34 && progress > 0.85 {
                    let middle = (start + end) / 2, distance = (inner + outer) / 2
                    var labelContext = context
                    labelContext.translateBy(x: center.x + cos(middle) * distance, y: center.y + sin(middle) * distance)
                    var rotation = middle + .pi / 2
                    if sin(middle) > 0 { rotation += .pi }
                    labelContext.rotate(by: .radians(rotation))
                    let limit = max(4, min(17, Int((end - start) * distance / 7)))
                    let label = arc.label.count > limit ? String(arc.label.prefix(limit-1)) + "…" : arc.label
                    labelContext.draw(Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(.black.opacity(0.77)), at: .zero)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct Sunburst: View {
    @ObservedObject var model: Explorer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) * 0.47
            ZStack {
                ForEach(0..<3) { i in Circle().stroke(.white.opacity(0.022), lineWidth: 1).frame(width: radius * (1.37 + Double(i) * 0.34), height: radius * (1.37 + Double(i) * 0.34)) }
                SunburstDrawing(previous: model.oldArcs, arcs: model.arcs, hovered: model.hovered, progress: reduceMotion ? 1 : model.animation)
                VStack(spacing: 7) {
                    Text(model.allocated ? "ALLOC. ESTIMATE" : "LOGICAL BYTES").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1.7).foregroundStyle(muted)
                    Text(bytes(model.node?.size(model.allocated) ?? 0)).font(.system(size: min(35, radius * 0.12), weight: .medium, design: .rounded)).tracking(-1.5).contentTransition(.numericText())
                    Text(model.node?.name ?? "Orbit").font(.system(size: 11)).foregroundStyle(muted).lineLimit(1).frame(maxWidth: radius * 0.48)
                    if model.current != 0 { Image(systemName: "arrow.up").font(.system(size: 12)).foregroundStyle(accent).padding(.top, 2) }
                }
                .frame(width: radius * 0.56, height: radius * 0.56)
                .contentShape(Circle()).onTapGesture { model.up() }
                .help(model.current == 0 ? "Scanned file allocations, estimated from file blocks" : "Go to parent folder")
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let dx = point.x - geo.size.width / 2, dy = point.y - geo.size.height / 2
                    let distance = hypot(dx, dy) / radius
                    var angle = atan2(dy, dx); if angle < -.pi / 2 { angle += .pi * 2 }
                    let match = model.arcs.last { distance >= $0.inner && distance <= $0.outer && angle >= $0.start && angle <= $0.end }
                    if model.hovered != match?.node { model.hovered = match?.node }
                    if match != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                case .ended: if model.hovered != nil { model.hovered = nil }; NSCursor.arrow.set()
                }
            }
            .onTapGesture { if let id = model.hovered { model.navigate(id) } }
            .overlay(alignment: .bottom) {
                if let id = model.hovered, let node = model.result?.nodes[id] {
                    HStack(spacing: 10) {
                        Circle().fill(model.color(id)).frame(width: 7, height: 7)
                        Text(node.name).lineLimit(1)
                        Text(bytes(node.size(model.allocated))).foregroundStyle(.white).monospacedDigit()
                    }.font(.system(size: 12)).foregroundStyle(muted).padding(.horizontal, 15).padding(.vertical, 10)
                        .background(panel, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.07)))
                        .padding(.bottom, 4).allowsHitTesting(false)
                }
            }
        }
    }
}

struct SmallButton: View {
    let icon: String; let text: String; var action: () -> Void
    var body: some View { Button(action: action) { Label(text, systemImage: icon).font(.system(size: 12, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 4) }.buttonStyle(.bordered).tint(.white.opacity(0.12)) }
}

struct ExplorerView: View {
    @StateObject private var model = Explorer()
    @StateObject private var worktrees = WorktreeCatalog()
    @State private var showAbout = false
    @State private var showNotes = false
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var shell: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.035))
            HStack(spacing: 0) {
                sidebar.frame(width: 190)
                Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
                if model.showingWorktrees {
                    WorktreeView(catalog: worktrees, allocated: $model.allocated,
                        open: { model.scan($0) }, searchDisk: searchWorktreesOnDisk, chooseRepository: chooseWorktreeRepository)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
                    inspector.frame(width: 314)
                }
            }
            footer
        }
        .background(appBackground).preferredColorScheme(.dark).foregroundStyle(Color.white.opacity(0.91))
        .frame(minWidth: 1040, minHeight: 680)
    }
    var body: some View {
        shell
        .onAppear {
            if let path = ProcessInfo.processInfo.environment["ORBIT_SCAN_PATH"] { model.scan(URL(fileURLWithPath: path)) }
            else { model.scan(home.appendingPathComponent("Library/Caches")) }
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in model.refreshDiskSpace() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel(); worktrees.stop() }
        .background { Button("") { model.chooseFolder() }.keyboardShortcut("o").hidden() }
        .background { Button("") { model.up() }.keyboardShortcut(.upArrow, modifiers: .command).hidden() }
        .background { Button("") { refreshCurrentLocation() }.keyboardShortcut("r").hidden() }
        .alert("Unable to scan folder", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showNotes) { accountingNotes }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { model.scan(url) } } }; return true
        }
    }
    private var worktreeIndex: ScanResult? { model.result?.root == "/" ? model.result : nil }
    private func showWorktrees() {
        if model.scanning { model.cancel() }
        model.showingWorktrees = true
        worktrees.ensureLoaded(index: worktreeIndex)
    }
    private func refreshCurrentLocation() {
        if model.showingWorktrees { worktrees.refresh(index: worktreeIndex) }
        else if let url = model.rootURL { model.scan(url) }
    }
    private func searchWorktreesOnDisk() {
        guard worktrees.anchor != nil else { chooseWorktreeRepository(); return }
        worktrees.stop()
        model.scan(URL(fileURLWithPath: "/")) { result in
            model.showingWorktrees = true
            worktrees.refresh(index: result)
        }
    }
    private func chooseWorktreeRepository() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false; picker.prompt = "Use repository"
        picker.message = "Choose a Git checkout. Orbit uses its origin remote to find matching clones and worktrees."
        if picker.runModal() == .OK, let url = picker.url { worktrees.selectRepository(url, index: worktreeIndex) }
    }
    private var header: some View {
        HStack(spacing: 12) {
            ZStack { Circle().stroke(accent.opacity(0.75), lineWidth: 1.5).frame(width: 23, height: 23); Circle().fill(accent).frame(width: 5, height: 5).offset(x: 10, y: -5); Circle().fill(accent.opacity(0.8)).frame(width: 4, height: 4) }
            Text("Orbit").font(.system(size: 21, weight: .semibold)).tracking(-0.6)
            Text("DISK EXPLORER").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(muted).padding(.leading, 6)
            Spacer()
            if model.scanning || model.showingWorktrees && worktrees.busy { SmallButton(icon: "stop", text: "Stop scan") { model.cancel(); worktrees.stop() } }
            else if model.rootURL != nil || model.showingWorktrees { Button { refreshCurrentLocation() } label: { Image(systemName:"arrow.clockwise").font(.system(size: 13)) }.buttonStyle(.plain).foregroundStyle(muted).help("Rescan · ⌘R") }
            Button { model.chooseFolder() } label: { Label("Scan folder", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 9).foregroundStyle(appBackground).background(accent, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).padding(.leading, 10)
        }.padding(.horizontal, 24).frame(height: 67)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LOCATIONS").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.7).foregroundStyle(muted).padding(.bottom, 15)
            location("Home", icon: "house", url: home)
            location("Downloads", icon: "arrow.down.circle", url: home.appendingPathComponent("Downloads"))
            location("Applications", icon: "square.grid.2x2", url: URL(fileURLWithPath:"/Applications"))
            location("Library caches", icon: "externaldrive", url: home.appendingPathComponent("Library/Caches"))
            location("Macintosh HD", icon: "internaldrive", url: URL(fileURLWithPath:"/"))
            Button { showWorktrees() } label: {
                HStack(spacing: 11) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 13)).frame(width: 17)
                    Text("Worktrees").font(.system(size: 12))
                    Spacer()
                    if !worktrees.entries.isEmpty { Text("\(worktrees.entries.count)").font(.system(size: 10, design: .monospaced)) }
                }.foregroundStyle(model.showingWorktrees ? accent : Color.white.opacity(0.6)).padding(.horizontal, 10).frame(height: 37)
                    .background(model.showingWorktrees ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).padding(.horizontal, -10).padding(.bottom, 4)
            Spacer()
            if model.showingWorktrees {
                VStack(alignment: .leading, spacing: 9) {
                    Text("GIT CHECKOUTS").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(muted)
                    Text("\(worktrees.entries.count) checkouts").font(.system(size: 21, weight: .medium, design: .rounded)).tracking(-0.7)
                    Text("\(worktrees.measured) sizes checked").font(.system(size: 11)).foregroundStyle(muted)
                }.padding(.bottom, 24)
            } else if let r = model.result {
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Circle().fill(Color(red:0.44,green:0.79,blue:0.64)).frame(width: 5, height: 5); Text(model.allocated ? "FILE ALLOCATIONS" : "LOGICAL BYTES").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(muted) }
                    Text(bytes(r.nodes[0].size(model.allocated))).font(.system(size: 24, weight: .medium, design: .rounded)).tracking(-0.8)
                    Text("\(number(r.nodes[0].files)) files mapped").font(.system(size: 11)).foregroundStyle(muted)
                    Text("\(number(r.nodes[0].folders)) folders").font(.system(size: 11)).foregroundStyle(muted)
                }.padding(.bottom, 24)
            }
            Button { showNotes = true } label: { Label("About disk sizes", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(muted) }.buttonStyle(.plain)
        }.padding(.horizontal, 19).padding(.top, 27).padding(.bottom, 22).background(panel.opacity(0.45))
    }
    private func location(_ title: String, icon: String, url: URL) -> some View {
        let active = !model.showingWorktrees && model.result?.root == url.path
        return Button { model.scan(url) } label: {
            HStack(spacing: 11) { Image(systemName: icon).font(.system(size: 13)).frame(width: 17); Text(title).font(.system(size: 12)); Spacer(); if active { Circle().fill(accent).frame(width: 4, height: 4) } }
                .foregroundStyle(active ? accent : Color.white.opacity(0.6)).padding(.horizontal, 10).frame(height: 37)
                .background(active ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).padding(.horizontal, -10).padding(.bottom, 4)
    }
    private var diskOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let space = model.diskSpace {
                HStack(spacing: 6) {
                    Text("DISK").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1.5).padding(.trailing, 5)
                    Text(space.usedLabel).foregroundStyle(.white.opacity(0.88)).monospacedDigit()
                    Text("used  +")
                    Text(space.freeLabel).foregroundStyle(Color(red: 0.44, green: 0.79, blue: 0.64)).monospacedDigit()
                    Text("free  =")
                    Text(space.capacityLabel).foregroundStyle(.white.opacity(0.75)).monospacedDigit()
                    Text("capacity")
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).foregroundStyle(muted)
                .help("macOS: \(number(space.used)) bytes used + \(number(space.free)) bytes free = \(number(space.capacity)) bytes capacity. Displayed GB figures share one rounding calculation.")
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color(red: 0.44, green: 0.79, blue: 0.64).opacity(0.50))
                        Rectangle().fill(accent.opacity(0.62)).frame(width: geo.size.width * Double(space.used) / Double(space.capacity))
                    }.clipShape(RoundedRectangle(cornerRadius: 2))
                }.frame(height: 4)
                if model.result?.root == "/", let root = model.result?.nodes.first {
                    let match = space.reconciliation(scanned: root.allocated)
                    Text("\(match.scannedLabel) file allocations \(match.operation) \(match.adjustmentLabel) \(match.reason) = \(space.usedLabel) used")
                        .font(.system(size: 9)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        .help("The difference between scanned block estimates and macOS used space. Shared APFS blocks, inaccessible files, snapshots, filesystem overhead, and changes since the scan can contribute. Folder estimates are not rescaled.")
                } else {
                    Text(model.allocated ? "Disk totals are reported by macOS. The map shows this folder's file allocation estimates." : "Disk totals are reported by macOS. The map shows this folder's logical bytes.").font(.system(size: 9)).foregroundStyle(muted)
                }
            } else {
                Text("Disk capacity unavailable").font(.system(size: 10)).foregroundStyle(muted)
            }
            if !model.allocated {
                Text("Logical bytes include sparse capacity and repeated paths; they are not disk consumption.").font(.system(size: 10)).foregroundStyle(Color.orange.opacity(0.85))
            }
        }
    }
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { model.up() } label: { Image(systemName:"arrow.left").font(.system(size:13)) }.buttonStyle(.plain).disabled(model.current == 0).foregroundStyle(muted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(model.crumbs, id: \.self) { id in
                        if id != 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(muted.opacity(0.5)) }
                        Button(model.result?.nodes[id].name ?? "") { model.navigate(id) }.buttonStyle(.plain).font(.system(size: 11, weight: id == model.current ? .medium : .regular)).foregroundStyle(id == model.current ? .white.opacity(0.8) : muted)
                    }}
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 27).frame(height: 52)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.node?.name ?? "Your space, in perspective.").font(.system(size: 27, weight: .medium)).tracking(-0.9).lineLimit(1)
                    Text(model.result == nil ? "Mapping your files" : "\(number(model.node?.files ?? 0)) files · \(number(model.node?.folders ?? 0)) folders").font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                Picker("Size measurement", selection: $model.allocated) { Text("On disk").tag(true); Text("Logical").tag(false) }.labelsHidden().pickerStyle(.segmented).frame(width: 152).help("On disk estimates allocated file blocks. Logical includes sparse capacity and counts every file path; it can exceed the drive capacity.")
            }.padding(.horizontal, 29).padding(.top, 11)
            diskOverview.padding(.horizontal, 29).padding(.top, 17)
            ZStack {
                if model.result != nil && !model.arcs.isEmpty { Sunburst(model: model).padding(.horizontal, 10).padding(.top, 10) }
                else if model.scanning { scanningState }
                else {
                    VStack(spacing: 14) { Image(systemName:"circle.dotted.circle").font(.system(size: 70, weight: .ultraLight)).foregroundStyle(accent.opacity(0.45)); Text(model.result == nil ? "A new perspective on your disk" : "This folder has no measurable files").font(.system(size: 17, weight:.medium)); Text("Choose a folder or drop one into this window.").font(.system(size: 12)).foregroundStyle(muted); SmallButton(icon:"folder",text:"Choose folder") { model.chooseFolder() } }
                }
                if model.scanning && model.result != nil {
                    VStack { Spacer(); scanOverlay.padding(.bottom, 19) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 18) { Label("Click a folder to zoom",systemImage:"cursorarrow"); Label("Click the center to go back",systemImage:"arrow.up") }.font(.system(size:10)).foregroundStyle(muted.opacity(0.8)).frame(maxWidth:.infinity).padding(.bottom, 23)
        }
    }
    private var scanOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.waitingForFilesystem ? "Waiting for filesystem access" : "Scanning \(model.scanTarget)").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(model.progressWorkers) workers").font(.system(size: 9, design: .monospaced)).foregroundStyle(accent)
            }
            Text("\(number(model.progressFiles)) files · \(bytes(model.progressSize))").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
            if model.waitingForFilesystem { Text("Check macOS permission prompts. Protected folders may require Full Disk Access.").font(.system(size: 9)).foregroundStyle(Color.orange.opacity(0.8)) }
            Text(model.progressPath.replacingOccurrences(of: home.path, with: "~")).font(.system(size: 9)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
        }.padding(14).frame(width: 350).background(panel, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06)))
    }
    private var scanningState: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large).tint(accent)
            Text(model.waitingForFilesystem ? "Waiting for filesystem access" : "Mapping \(model.scanTarget)").font(.system(size:21,weight:.medium)).tracking(-0.4)
            Text("\(number(model.progressFiles)) files · \(bytes(model.progressSize)) · \(model.progressWorkers) workers").font(.system(size:12,design:.monospaced)).foregroundStyle(accent).contentTransition(.numericText())
            Text(model.progressPath.replacingOccurrences(of:home.path,with:"~")).font(.system(size:10)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle).frame(maxWidth:330)
        }
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("CONTENTS").font(.system(size:9,weight:.semibold,design:.monospaced)).tracking(1.7).foregroundStyle(muted); Spacer(); Text("\(model.children.count)").font(.system(size:10,design:.monospaced)).foregroundStyle(muted) }.padding(.top, 29).padding(.bottom, 20)
            HStack(spacing: 8) { Image(systemName:"magnifyingglass").foregroundStyle(muted); TextField("Filter this folder",text:$model.search).textFieldStyle(.plain).font(.system(size:11)); if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(muted) }.buttonStyle(.plain) } }.padding(9).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:6)).padding(.bottom, 17)
            HStack { Text("Name"); Spacer(); Text(model.allocated ? "Allocated ↓" : "Logical ↓") }.font(.system(size:10)).foregroundStyle(muted.opacity(0.8)).padding(.bottom, 9)
            Rectangle().fill(.white.opacity(0.06)).frame(height:1)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.filteredChildren, id: \.self) { id in row(id) }
                    if model.filteredChildren.isEmpty { Text(model.search.isEmpty ? "No files to display" : "No matching names").font(.system(size:12)).foregroundStyle(muted).padding(.top,35) }
                }.padding(.top, 7)
            }.frame(maxHeight: .infinity)
            selectionDetail.padding(.top, 15).padding(.bottom, 20)
        }.padding(.horizontal, 20).background(panel.opacity(0.35))
    }
    private func row(_ id: Int) -> some View {
        let node = model.result!.nodes[id]
        let total = max(1, model.node?.size(model.allocated) ?? 1)
        let fraction = Double(node.size(model.allocated)) / Double(total)
        let active = model.hovered == id || model.selected == id
        return Button { model.navigate(id) } label: {
            VStack(spacing: 8) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius:2).fill(model.color(id)).frame(width: 6,height: 6)
                    Image(systemName: node.kind == "link" ? "link" : node.isFolder ? "folder" : "doc").font(.system(size:12)).foregroundStyle(muted).frame(width:15)
                    Text(node.name).font(.system(size:11,weight:.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength:3)
                    Text(bytes(node.size(model.allocated))).font(.system(size:10,design:.monospaced)).foregroundStyle(muted).fixedSize()
                    if node.isFolder { Image(systemName:"chevron.right").font(.system(size:7)).foregroundStyle(muted.opacity(0.5)) }
                }
                GeometryReader { g in RoundedRectangle(cornerRadius:1).fill(model.color(id).opacity(0.55)).frame(width:max(1,g.size.width*fraction),height:2) }.frame(height:2).padding(.leading, 30)
            }.padding(.horizontal, 8).padding(.vertical, 11).background(active ? .white.opacity(0.055) : .clear,in:RoundedRectangle(cornerRadius:5))
        }.buttonStyle(.plain)
            .onHover { inside in if inside { model.hovered = id } else if model.hovered == id { model.hovered = nil } }
            .contextMenu { Button("Reveal in Finder") { model.reveal(id) }; Button("Copy path") { model.copyPath(id) }; if node.isFolder { Button("Scan this folder") { if let url = model.url(id) { model.scan(url) } } } }
            .help(model.url(id)?.path ?? node.name)
    }
    private var selectionDetail: some View {
        VStack(alignment: .leading, spacing: 11) {
            Rectangle().fill(.white.opacity(0.07)).frame(height:1).padding(.bottom, 5)
            if let inspected = model.inspection {
                HStack(spacing:8) { Image(systemName: inspected.isFolder ? "folder" : "doc").foregroundStyle(accent); Text(inspected.name).lineLimit(1).truncationMode(.middle).font(.system(size:12,weight:.medium)) }
                HStack { Text("Logical size"); Spacer(); Text(bytes(inspected.logical)).monospacedDigit() }.font(.system(size:11)).foregroundStyle(muted)
                HStack { Text("Allocated estimate"); Spacer(); Text(bytes(inspected.allocated)).monospacedDigit() }.font(.system(size:11)).foregroundStyle(muted)
                if inspected.issues > 0 { Label("\(number(inspected.issues)) unreadable or excluded entries",systemImage:"exclamationmark.circle").font(.system(size:10)).foregroundStyle(Color.orange.opacity(0.85)).help("Protected folders, other volumes, duplicate directory entries, and unsupported filenames are excluded. Totals may be incomplete.") }
                Button { model.reveal(model.hovered ?? model.selected ?? model.current) } label: { Label("Reveal in Finder",systemImage:"arrow.up.forward.square").font(.system(size:11)).foregroundStyle(accent) }.buttonStyle(.plain).padding(.top,2)
            } else { Text("Hover a segment to inspect it.").font(.system(size:11)).foregroundStyle(muted) }
        }
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(model.scanning || model.showingWorktrees && worktrees.busy ? Color.orange : Color(red:0.43,green:0.75,blue:0.6)).frame(width:5,height:5)
            Text(model.showingWorktrees ? worktrees.status : model.status).font(.system(size:10)).foregroundStyle(muted)
            if !model.showingWorktrees, let count = model.result?.nodes.first?.issues, count > 0 { Text("· \(number(count)) unreadable or excluded").font(.system(size:10)).foregroundStyle(Color.orange.opacity(0.75)) }
            Spacer()
            Text("All scans stay on this Mac").font(.system(size:10)).foregroundStyle(muted.opacity(0.7))
            Text("⌘O  Open").font(.system(size:9,design:.monospaced)).foregroundStyle(muted).padding(.leading,15)
        }.padding(.horizontal,22).frame(height:34).background(panel.opacity(0.7)).overlay(alignment:.top) { Rectangle().fill(.white.opacity(0.06)).frame(height:1) }
    }
    private var accountingNotes: some View {
        VStack(alignment:.leading,spacing:19) {
            Text("Understanding disk sizes").font(.system(size:23,weight:.medium)).tracking(-0.6)
            Text("The disk summary uses macOS capacity and free-space counters. Used + free = capacity. These are the physical disk figures; APFS volumes share the same container space.")
            Text("On disk is the default map. It estimates file allocations from disk blocks. Logical counts file bytes, including unallocated sparse capacity and repeated hard-link paths, so it can exceed the drive capacity.")
            Text("Hard links are counted once in allocated estimates. APFS clones can share blocks, so adding file allocations can exceed physical used space. Whole-disk scans show the adjustment explicitly; folder estimates are never silently scaled. Missing files, snapshots, filesystem overhead, and changes since the scan also contribute to the difference.")
            Text("Orbit reads metadata only. It does not follow symbolic links, cross into other mounted devices, or delete files. Restricted folders and excluded entries are reported. Snapshots, purgeable space, and filesystem overhead are not measured.")
            Text("For protected folders, you can grant Orbit Full Disk Access in System Settings → Privacy & Security, then rescan.")
            HStack { Spacer(); Button("Done") { showNotes = false }.keyboardShortcut(.defaultAction) }
        }.font(.system(size:13)).foregroundStyle(.white.opacity(0.8)).lineSpacing(4).padding(32).frame(width:550).background(panel)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps:true) }
}

@main struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Orbit") { ExplorerView() }
            .defaultSize(width: 1240, height: 810)
            .windowStyle(.hiddenTitleBar)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
