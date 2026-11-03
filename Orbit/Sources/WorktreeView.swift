import SwiftUI
import AppKit

struct WorktreeView: View {
    @ObservedObject var catalog: WorktreeCatalog
    @Binding var allocated: Bool
    var open: (URL) -> Void
    var searchDisk: () -> Void
    var chooseRepository: () -> Void
    @State private var hovered: String?

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var rows: [WorktreeEntry] { catalog.displayed(allocated: allocated) }
    private func path(_ url: URL) -> String {
        url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
    var body: some View {
        let displayed = rows
        let largest = displayed.compactMap { allocated ? $0.allocated : $0.logical }.max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Worktrees").font(.system(size: 29, weight: .medium)).tracking(-0.9)
                    Text(catalog.repositoryName).font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer()
                SmallButton(icon: "magnifyingglass", text: "Search this Mac", action: searchDisk)
                Button(action: chooseRepository) { Image(systemName: "folder.badge.gearshape").font(.system(size: 14)).foregroundStyle(muted) }.buttonStyle(.plain).help("Choose the repository used to find linked worktrees")
            }.padding(.bottom, 22)
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(muted)
                    TextField("Filter by path or branch", text: $catalog.search).textFieldStyle(.plain).font(.system(size: 12))
                    if !catalog.search.isEmpty { Button { catalog.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(muted) }.buttonStyle(.plain) }
                }.padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                Picker("Size measurement", selection: $allocated) { Text("On disk").tag(true); Text("Logical").tag(false) }.labelsHidden().pickerStyle(.segmented).frame(width: 152)
            }.padding(.bottom, 18)
            HStack(spacing: 9) {
                if catalog.busy { ProgressView().controlSize(.small) }
                Text(catalog.status).font(.system(size: 11)).foregroundStyle(catalog.busy ? accent : muted)
                Spacer()
                Text(catalog.searchedDisk ? "Git metadata + disk search" : "Git worktree registry").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
            }.padding(.bottom, 13)
            if let error = catalog.error {
                HStack(spacing: 12) { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange); Text(error).font(.system(size: 12)); Spacer(); Button("Choose repository", action: chooseRepository).buttonStyle(.bordered) }.padding(.vertical, 15)
            }
            HStack {
                Text("Checkout / location").frame(maxWidth: .infinity, alignment: .leading)
                Text("Branch").frame(width: 225, alignment: .leading)
                Text(allocated ? "Allocated estimate ↓" : "Logical size ↓").frame(width: 126, alignment: .trailing)
                Spacer().frame(width: 29)
            }.font(.system(size: 10)).foregroundStyle(muted).padding(.horizontal, 12).padding(.bottom, 10)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayed) { entry in row(entry, largest: largest) }
                    if displayed.isEmpty && !catalog.busy && catalog.error == nil {
                        VStack(spacing: 11) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 34, weight: .light)).foregroundStyle(accent.opacity(0.6))
                            Text(catalog.search.isEmpty ? (catalog.anchor == nil ? "Choose a repository to get started" : "No matching checkouts found") : "No paths or branches match your filter").font(.system(size: 14))
                            if catalog.search.isEmpty {
                                if catalog.anchor == nil { Button("Choose repository", action: chooseRepository).buttonStyle(.bordered) }
                                else { Text("Search this Mac to inspect Git metadata in other folders.").font(.system(size: 12)).foregroundStyle(muted) }
                            }
                        }.padding(.top, 60)
                    }
                }
            }.frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.bottom, 9)
                Text("Click a checkout to explore it. Sizes include its files, dependencies, and build output.").font(.system(size: 11)).foregroundStyle(muted)
                Text(allocated ? "Each checkout is measured separately. Shared files and nested checkouts can overlap; sizes are not guaranteed space savings." : "Logical sizes include sparse capacity and repeated paths. Use On disk for allocation estimates.").font(.system(size: 10)).foregroundStyle(muted.opacity(0.8))
                if !catalog.searchedDisk { Text("Search this Mac also finds matching clones and worktrees missing from Git's registry.").font(.system(size: 10)).foregroundStyle(muted.opacity(0.8)) }
                if catalog.partial > 0 || catalog.failed > 0 {
                    Text("\(catalog.partial) partial sizes · \(catalog.failed) checkouts could not be measured").font(.system(size: 10)).foregroundStyle(Color.orange.opacity(0.8))
                }
                if catalog.unavailable > 0 || catalog.diskIssues > 0 {
                    Text("\(catalog.unavailable) missing or unavailable registered paths\(catalog.diskIssues > 0 ? " · \(number(catalog.diskIssues)) unreadable or excluded entries in the disk search" : "")").font(.system(size: 10)).foregroundStyle(Color.orange.opacity(0.8))
                }
            }.padding(.top, 14)
        }.padding(.horizontal, 29).padding(.top, 30).padding(.bottom, 24)
    }
    private func row(_ entry: WorktreeEntry, largest: UInt64) -> some View {
        let size = allocated ? entry.allocated : entry.logical
        return HStack(spacing: 0) {
            Button { open(entry.url) } label: {
                HStack(spacing: 15) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 12)).foregroundStyle(accent)
                            Text(entry.url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if entry.locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(muted).help("Git marks this worktree as locked") }
                            Text(entry.kind).font(.system(size: 9)).foregroundStyle(muted)
                        }
                        Text(path(entry.url)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle).frame(width: 225, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 7) {
                        if let size {
                            HStack(spacing: 6) {
                                Text(bytes(size)).font(.system(size: 12, weight: .medium, design: .monospaced))
                                if let issues = entry.issues, issues > 0 {
                                    Text("Partial").font(.system(size: 9)).foregroundStyle(.orange)
                                        .help("\(number(issues)) unreadable or excluded entries. This size may be incomplete.")
                                }
                            }
                        }
                        else { Text(entry.error ?? (catalog.busy ? "Measuring…" : "Not measured")).font(.system(size: 10)).foregroundStyle(entry.error == nil ? muted : .orange) }
                        if let size {
                            GeometryReader { geo in RoundedRectangle(cornerRadius: 1).fill(accent.opacity(0.6)).frame(width: geo.size.width * Double(size) / Double(max(1, largest)), height: 2) }.frame(width: 104, height: 2)
                        }
                    }.frame(width: 126, alignment: .trailing)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Explore \(entry.url.path)")
            Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 12)).foregroundStyle(muted).frame(width: 29, height: 38)
            }.buttonStyle(.plain).help("Reveal checkout in Finder")
        }.padding(.horizontal, 12).padding(.vertical, 14)
            .background(hovered == entry.id ? .white.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.035)).frame(height: 1) }
            .onHover { inside in hovered = inside ? entry.id : nil }
            .contextMenu {
                Button("Explore checkout") { open(entry.url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.url.path, forType: .string) }
            }
    }
}
