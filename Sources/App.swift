import SwiftUI
import AppKit

func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
let ink = Color(red: 0.10, green: 0.17, blue: 0.16)
let paper = Color(red: 0.97, green: 0.97, blue: 0.95)

@MainActor final class Explorer: ObservableObject {
    @Published var result: ScanResult?
    @Published var path: [DiskItem] = []
    @Published var selected: DiskItem?
    @Published var expanded = Set<URL>()
    @Published var largest = false
    @Published var big: [DiskItem] = []
    @Published var progress = ScanProgress()
    @Published var pending: URL?
    @Published var message: String?
    @Published var confirm: DiskItem?
    @Published var moving: DiskItem?
    private var activeMonitor: ScanMonitor?
    private var job: Task<Void, Never>?
    var folder: DiskItem? { path.last }
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan folder"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func cancel() { activeMonitor = nil; job?.cancel(); job = nil; pending = nil }
    func load(_ url: URL) {
        cancel()
        progress = ScanProgress()
        pending = url
        let previous = path.map(\.url)
        job = Task {
            guard !Task.isCancelled else { return }
            let monitor = ScanMonitor()
            activeMonitor = monitor
            let sampler = Task {
                while !Task.isCancelled && self.activeMonitor === monitor {
                    self.progress = monitor.snapshot()
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { sampler.cancel() }
            let worker = Task.detached(priority: .userInitiated) {
                try scan(url, monitor: monitor)
            }
            do {
                let report = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                result = report
                path = [report.root]
                if previous.first == report.root.url {
                    for link in previous.dropFirst() {
                        guard let next = folder?.children?.first(where: { $0.url == link }) else { break }
                        path.append(next)
                    }
                } else { largest = false }
                selected = nil
                expanded = []
                big = report.largestFiles
                pending = nil
            } catch {
                if !Task.isCancelled { pending = nil; message = error.localizedDescription }
            }
        }
    }
    func enter(_ item: DiskItem) {
        selected = item
        guard item.isFolder, let current = folder else { return }
        let pieces = item.url.pathComponents.dropFirst(current.url.pathComponents.count)
        for name in pieces {
            guard let next = folder?.children?.first(where: { $0.name == name }) else { break }
            path.append(next)
        }
        selected = nil
        expanded = []
    }
    private func applyUpdate(_ report: ScanResult) {
        var navigation = [report.root]
        for ancestor in path.dropFirst() {
            guard let next = navigation.last?.children?.first(where: { $0.name == ancestor.name && $0.isFolder }) else { break }
            navigation.append(next)
        }
        result = report
        path = navigation
        big = report.largestFiles
        selected = nil
        moving = nil
    }

    func moveSelected() {
        guard let item = selected, !item.isFolder, let snapshot = result, moving == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Move “\(item.name)” to a folder"
        panel.prompt = "Move Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        moving = item
        Task {
            let (report, error) = await Task.detached(priority: .userInitiated) {
                let target = destination.appendingPathComponent(item.name)
                var failure: String?
                do { try moveFile(item, in: snapshot.root, to: destination) }
                catch { failure = error.localizedDescription }
                return (snapshot.updating(source: item, destination: target), failure)
            }.value
            applyUpdate(report)
            message = error
        }
    }

    func trash(_ item: DiskItem) {
        guard let snapshot = result, moving == nil else { return }
        moving = item
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try validateSource(item, in: snapshot.root)
                    var destination: NSURL?
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: &destination)
                    return snapshot.updating(source: item, destination: destination as URL?)
                }.value
                applyUpdate(report)
            } catch { moving = nil; message = error.localizedDescription }
        }
    }
}

struct BrowserRow: Identifiable {
    var item: DiskItem
    var depth: Int
    var id: URL { item.url }
}

struct Content: View {
    @StateObject var model = Explorer()
    
    var rows: [BrowserRow] {
        if model.largest { return model.big.map { BrowserRow(item: $0, depth: 0) } }
        var list = [BrowserRow]()
        func append(_ items: [DiskItem], _ depth: Int) {
            for item in items {
                list.append(BrowserRow(item: item, depth: depth))
                if model.expanded.contains(item.url), let children = item.children { append(children, depth + 1) }
            }
        }
        append(model.folder?.children ?? [], 0)
        return list
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("FoxDisk", systemImage: "internaldrive.fill").font(.system(size: 24, weight: .bold)).padding(.bottom, 22)
            Text("WORKSPACE").font(.caption2.weight(.bold)).tracking(1.5).opacity(0.65)
            ForEach([false,true], id: \.self) { big in
                Button {
                    model.largest = big
                    model.selected = nil
                } label: {
                    Label(big ? "Largest files" : "Disk explorer", systemImage: big ? "chart.bar.xaxis" : "square.grid.2x2")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(model.largest == big ? .white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).disabled(model.result == nil && big)
            }
            Spacer()
            Button { model.choose() } label: { Label("Choose folder…", systemImage: "folder.badge.plus") }.buttonStyle(.plain)
        }.padding(20).frame(width: 192).frame(maxHeight: .infinity).foregroundStyle(.white).background(ink)
    }
    @ViewBuilder var footer: some View {
                    Divider()
                    HStack {
                        Text(model.selected?.name ?? "\(model.result!.files) files scanned").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder") { if let item = model.selected { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }.disabled(model.selected == nil)
                        Button("Move to Folder…") { model.moveSelected() }.disabled(model.selected?.isFolder != false)
                        Button("Move to Trash…") { model.confirm = model.selected }.disabled(model.selected == nil)
                    }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.disabled(model.moving != nil)
            VStack(alignment: .leading, spacing: 16) {
                if let item = model.moving {
                    ProgressView("Moving \(item.name)…").frame(maxWidth: .infinity)
                } else if let target = model.pending {
                    Spacer()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scanning \(target.lastPathComponent)").font(.title2.bold())
                        ProgressView(value: Double(model.progress.completed), total: Double(max(1, model.progress.total)))
                            .progressViewStyle(.linear)
                        Text(model.progress.total == 0 ? "Reading folder contents…" : "\(model.progress.completed) of \(model.progress.total) top-level items finished")
                        Text("\(model.progress.files) files · \(model.progress.folders) folders · \(sizeText(model.progress.bytes)) · \(model.progress.skipped) skipped")
                            .monospacedDigit()
                        Text(model.progress.directory.isEmpty ? target.path : model.progress.directory)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Cancel scan") { model.cancel() }
                    }.frame(maxWidth: 540, alignment: .leading)
                    Spacer()
                } else if let folder = model.folder {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.largest ? "Largest files" : folder.name).font(.largeTitle.bold()).lineLimit(1)
                            Text(model.largest ? "Top \(model.big.count) files in \(model.result!.root.name)" : folder.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if !model.largest && model.path.count > 1 {
                            Button { model.path.removeLast(); model.selected = nil; model.expanded = [] } label: { Image(systemName: "arrow.up") }.help("Parent folder")
                        }
                        Button { model.load(model.result!.root.url) } label: { Image(systemName: "arrow.clockwise") }.help("Rescan folder")
                    }
                    if !model.largest {
                        HStack { Text("Storage map").font(.headline); Spacer(); Text(sizeText(folder.bytes)).font(.system(.headline, design: .monospaced)) }
                        StorageMap(items: folder.children ?? [], selected: model.selected?.url, select: { model.selected = $0 }, open: model.enter)
                            .frame(minHeight: 110, idealHeight: 200, maxHeight: 240)
                        StorageMapLegend()
                    }
                    HStack { Text(model.largest ? "File" : "File tree").font(.headline); Spacer(); Text("Size ↓").font(.caption.weight(.semibold)) }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(rows) { row in
                                    HStack(spacing: 8) {
                                        if row.item.isFolder {
                                            Button {
                                                if !model.expanded.insert(row.id).inserted { model.expanded.remove(row.id) }
                                            } label: { Image(systemName: model.expanded.contains(row.id) ? "chevron.down" : "chevron.right").frame(width: 14, height: 24) }.buttonStyle(.plain)
                                        } else { Color.clear.frame(width: 14, height: 1) }
                                        Image(systemName: row.item.isFolder ? "folder.fill" : "doc.fill").foregroundStyle(FileKind(row.item).color)
                                        VStack(alignment: .leading) {
                                            Text(row.item.name).lineLimit(1)
                                            if model.largest { Text(row.id.deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                        }
                                        Spacer()
                                        Text(sizeText(row.item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                    }.padding(.leading, CGFloat(min(row.depth, 10)) * 12 + 4).padding(.trailing, 8).padding(.vertical, 4)
                                    .background(model.selected?.url == row.id ? FileKind.folders.color.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                    .contentShape(Rectangle()).onTapGesture(count: 2) { model.enter(row.item) }.onTapGesture { model.selected = row.item }.id(row.id)
                                }
                            }
                        }.onChange(of: model.selected?.url) { id in if let id { proxy.scrollTo(id) } }
                    }
                    footer
                    if let missed = model.result?.skipped, missed > 0 { Text("\(missed) unreadable items, special files, or mounted volumes skipped").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Spacer()
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 6).fill(FileKind.folders.color).frame(width: 56)
                            VStack(spacing: 4) { RoundedRectangle(cornerRadius: 4).fill(FileKind.media.color); RoundedRectangle(cornerRadius: 4).fill(FileKind.documents.color) }.frame(width: 33)
                        }.frame(height: 57)
                        Text("Explore your storage").font(.system(size: 38, weight: .bold))
                        Text("Choose a folder to map its contents and find your largest files.").foregroundStyle(.secondary)
                        Button("Choose folder…") { model.choose() }.controlSize(.large).buttonStyle(.borderedProminent).tint(ink)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(36)
                    Spacer()
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(paper)
        }.preferredColorScheme(.light).frame(minWidth: 800, minHeight: 590)
        .alert("Move item to Trash?", isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } }), presenting: model.confirm) { item in
            Button("Move to Trash", role: .destructive) { model.trash(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in Text("\(item.url.path)\n\(sizeText(item.bytes))\(item.isFolder ? " including folder contents" : "")\(item.skippedDescendants > 0 ? "\nSome contents were skipped during scanning. This moves the entire folder to Trash." : "")") }
        .alert("FoxDisk", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) { Button("OK") {} } message: { Text(model.message ?? "") }
    }
}

@main struct FoxDiskApp: App {
    var body: some Scene {
        Window("FoxDisk", id: "explorer") { Content() }.defaultSize(width: 1080, height: 760)
    }
}
