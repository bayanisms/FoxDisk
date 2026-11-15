import Foundation

struct DiskItem: Identifiable {
    let parentPath: String
    let name: String
    var path: String { name == "/" ? "/" : (parentPath == "/" ? "/" + name : parentPath + "/" + name) }
    var url: URL { URL(fileURLWithPath: path, isDirectory: isFolder) }
    let bytes: Int64
    let children: [DiskItem]?
    let identity: DiskIdentity
    var skippedDescendants = 0
    var id: URL { url }
    var isFolder: Bool { children != nil }
}

enum FileKind: String, CaseIterable {
    case folders = "Folders", media = "Media", documents = "Documents", archives = "Archives", other = "Other"
    init(_ item: DiskItem) {
        if item.isFolder { self = .folders; return }
        switch item.url.pathExtension.lowercased() {
        case "jpg","jpeg","heic","png","gif","mov","mp4","mkv","mp3","wav","webp","tiff","m4a": self = .media
        case "pdf","txt","md","doc","docx","xls","xlsx","csv","pages","pptx","rtf": self = .documents
        case "zip","gz","dmg","tar","7z","rar","pkg","bz2": self = .archives
        default: self = .other
        }
    }
}

struct DiskIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

private func metadata(_ path: String) throws -> stat {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path]) }
    return info
}

func diskIdentity(_ url: URL) throws -> DiskIdentity {
    DiskIdentity(try metadata(url.path))
}

struct ScanProgress {
    var completed = 0
    var total = 0
    var files = 0
    var folders = 0
    var skipped = 0
    var bytes: Int64 = 0
    var directory = ""
}

// The UI samples the latest snapshot. Large scans never queue per-file UI updates.
final class ScanMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ScanProgress()
    func update(_ value: ScanProgress) { lock.withLock { current = value } }
    func snapshot() -> ScanProgress { lock.withLock { current } }
}

struct ScanResult {
    let root: DiskItem
    let skipped: Int
    let files: Int
    let largestFiles: [DiskItem]
}

func scan(_ root: URL, monitor: ScanMonitor? = nil) throws -> ScanResult {
    let fm = FileManager.default
    var progress = ScanProgress()
    var candidates = [DiskItem]()
    func rankCandidates() {
        candidates.sort { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
        if candidates.count > 100 { candidates.removeLast(candidates.count - 100) }
    }
    var rootDevice: dev_t?
    func visit(parent: String, name: String, path: String, isRoot: Bool) throws -> DiskItem? {
        try Task.checkCancellation()
        let info = try metadata(path)
        let identity = DiskIdentity(info)
        if isRoot { rootDevice = identity.device }
        guard identity.device == rootDevice else { progress.skipped += 1; return nil }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFDIR {
            progress.folders += 1
            progress.directory = path
            monitor?.update(progress)
            let skippedBefore = progress.skipped
            let names = try fm.contentsOfDirectory(atPath: path)
            if isRoot { progress.total = names.count; monitor?.update(progress) }
            var entries = [DiskItem]()
            entries.reserveCapacity(names.count)
            let prefix = path == "/" ? "/" : path + "/"
            for childName in names {
                do {
                    if let child = try visit(parent: path, name: childName, path: prefix + childName, isRoot: false) {
                        entries.append(child)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { progress.skipped += 1 }
                progress.directory = path
                if isRoot { progress.completed += 1 }
                monitor?.update(progress)
            }
            try Task.checkCancellation()
            entries.sort { $0.bytes == $1.bytes ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.bytes > $1.bytes }
            return DiskItem(parentPath: parent, name: name, bytes: entries.reduce(0) { $0 + $1.bytes }, children: entries, identity: identity, skippedDescendants: progress.skipped - skippedBefore)
        }
        guard kind == S_IFREG || kind == S_IFLNK else { progress.skipped += 1; return nil }
        progress.files += 1
        progress.bytes += info.st_size
        let item = DiskItem(parentPath: parent, name: name, bytes: info.st_size, children: nil, identity: identity)
        if candidates.count < 100 || item.bytes >= candidates[99].bytes {
            candidates.append(item)
            if candidates.count == 200 || candidates.count == 100 { rankCandidates() }
        }
        return item
    }
    // Directory enumeration returns physical paths, including /private for /var and /tmp.
    guard let physical = realpath(root.path, nil) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { free(physical) }
    let directory = URL(fileURLWithFileSystemRepresentation: physical, isDirectory: true, relativeTo: nil)
    guard let item = try visit(parent: directory.deletingLastPathComponent().path, name: directory.lastPathComponent, path: directory.path, isRoot: true), item.isFolder else { throw CocoaError(.fileReadUnsupportedScheme) }
    rankCandidates()
    return ScanResult(root: item, skipped: progress.skipped, files: progress.files, largestFiles: candidates)
}
