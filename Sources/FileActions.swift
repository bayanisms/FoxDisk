import Foundation
import Darwin

struct ActionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func validateSource(_ item: DiskItem, in root: DiskItem) throws {
    let parent = item.url.deletingLastPathComponent()
    guard item.url.pathComponents.count > root.url.pathComponents.count,
          item.url.pathComponents.starts(with: root.url.pathComponents),
          parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.standardizedFileURL.path,
          try diskIdentity(root.url) == root.identity,
          try diskIdentity(item.url) == item.identity else {
        throw ActionError("The scanned item or its location changed. Scan the folder again.")
    }
}

private func exclusiveRename(_ from: URL, to: URL) throws {
    if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) != 0 {
        let code = errno
        if code == EEXIST { throw ActionError("An item named “\(to.lastPathComponent)” already exists in the destination.") }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

func moveFile(_ item: DiskItem, in root: DiskItem, to directory: URL) throws {
    guard !item.isFolder else { throw ActionError("Select a file to move.") }
    let destination = directory.resolvingSymlinksInPath().standardizedFileURL
    let target = destination.appendingPathComponent(item.name, isDirectory: false)
    try validateSource(item, in: root)
    guard try diskIdentity(destination) != diskIdentity(item.url.deletingLastPathComponent()) else { throw ActionError("Choose a different destination folder.") }
    do {
        try exclusiveRename(item.url, to: target)
        return
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EXDEV) {
        // Finish copying before publishing the destination or removing the source.
    }

    try copyAcrossVolumes(item, in: root, to: target)
}

func copyAcrossVolumes(_ item: DiskItem, in root: DiskItem, to target: URL) throws {
    let fm = FileManager.default
    let destination = target.deletingLastPathComponent()
    func snapshot() throws -> stat {
        var value = stat()
        guard lstat(item.url.path, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return value
    }
    let before = try snapshot()
    let type = before.st_mode & S_IFMT
    guard type == S_IFREG || type == S_IFLNK else { throw ActionError("Only regular files and symbolic links can move between volumes.") }
    let stage = destination.appendingPathComponent(".FoxDisk-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: stage) }
    let copy = stage.appendingPathComponent("item")
    try fm.copyItem(at: item.url, to: copy)
    func checkUnchanged() throws {
        try validateSource(item, in: root)
        let current = try snapshot()
        guard current.st_dev == before.st_dev, current.st_ino == before.st_ino,
              current.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw ActionError("The source changed during the copy. Scan again before moving it.")
        }
    }
    try checkUnchanged()
    try exclusiveRename(copy, to: target)
    do {
        try checkUnchanged()
        // unlink only a file or link, even if something replaces it with a directory.
        if unlink(item.url.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    } catch {
        throw ActionError("A copy was saved at \(target.path). FoxDisk could not finish removing the source. \(error.localizedDescription)")
    }
}
