import Foundation
import Darwin

// Reconcile the two affected entries against disk. Siblings retain their cached trees.
extension ScanResult {
    func updating(source: DiskItem, destination: URL?) -> ScanResult {
        var tree = root
        var count = files

        func fileCount(_ item: DiskItem) -> Int {
            item.children?.reduce(0) { $0 + fileCount($1) } ?? 1
        }

        func update(_ folder: DiskItem, components: ArraySlice<String>) -> DiskItem {
            guard let name = components.first, var entries = folder.children else { return folder }
            let index = entries.firstIndex { $0.name == name }
            let old = index.map { entries[$0] }
            let path = folder.url.appendingPathComponent(name, isDirectory: false).path
            var replacement: DiskItem?
            if components.count > 1, let old, old.isFolder {
                replacement = update(old, components: components.dropFirst())
            } else {
                var info = stat()
                if lstat(path, &info) == 0 {
                    guard info.st_dev == root.identity.device else { return folder }
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR:
                        if let old, old.isFolder, old.identity == DiskIdentity(info) { return folder }
                        guard let subtree = try? scan(URL(fileURLWithPath: path)) else { return folder }
                        replacement = subtree.root
                    case S_IFREG, S_IFLNK:
                        replacement = DiskItem(parentPath: folder.path, name: name, bytes: info.st_size, children: nil, identity: DiskIdentity(info))
                    default: break
                    }
                } else if errno != ENOENT && errno != ENOTDIR { return folder }
                count += (replacement.map(fileCount) ?? 0) - (old.map(fileCount) ?? 0)
            }
            if let index { entries.remove(at: index) }
            if let replacement {
                let position = entries.firstIndex {
                    $0.bytes < replacement.bytes || ($0.bytes == replacement.bytes && replacement.name.localizedStandardCompare($0.name) == .orderedAscending)
                }
                entries.insert(replacement, at: position ?? entries.endIndex)
            }
            return DiskItem(parentPath: folder.parentPath, name: folder.name,
                            bytes: folder.bytes - (old?.bytes ?? 0) + (replacement?.bytes ?? 0),
                            children: entries, identity: folder.identity,
                            skippedDescendants: folder.skippedDescendants - (old?.skippedDescendants ?? 0) + (replacement?.skippedDescendants ?? 0))
        }

        var targets = [source.url]
        if let destination, let parent = realpath(destination.deletingLastPathComponent().path, nil) {
            defer { free(parent) }
            targets.append(URL(fileURLWithFileSystemRepresentation: parent, isDirectory: true, relativeTo: nil).appendingPathComponent(destination.lastPathComponent))
        }
        let prefix = root.url.pathComponents
        for target in targets where target.pathComponents.starts(with: prefix) {
            tree = update(tree, components: target.pathComponents.dropFirst(prefix.count))
        }
        // Each folder is size-sorted. Its byte total bounds every file beneath it.
        var top = [DiskItem]()
        func rank(_ node: DiskItem) {
            if let children = node.children {
                for child in children {
                    if top.count == 100 && child.bytes < top[99].bytes { break }
                    rank(child)
                }
            } else {
                if top.count == 100 && node.bytes == top[99].bytes && node.path >= top[99].path { return }
                let i = top.firstIndex { node.bytes > $0.bytes || (node.bytes == $0.bytes && node.path < $0.path) }
                top.insert(node, at: i ?? top.endIndex)
                if top.count > 100 { top.removeLast() }
            }
        }
        rank(tree)
        return ScanResult(root: tree, skipped: tree.skippedDescendants, files: count, largestFiles: top)
    }
}
