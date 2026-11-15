import Foundation

@main struct FileActionsTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let dest = root.appendingPathComponent("destination")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.txt")
        let target = dest.appendingPathComponent("sample.txt")
        let payload = Data("original".utf8)
        try payload.write(to: source)
        let report = try scan(root)
        let item = report.largestFiles[0]
        func mustFail(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected failure") } catch {}
        }
        mustFail { try moveFile(item, in: report.root, to: root) }
        try Data("existing".utf8).write(to: target)
        mustFail { try moveFile(item, in: report.root, to: dest) }
        mustFail { try copyAcrossVolumes(item, in: report.root, to: target) }
        let existing = try Data(contentsOf: target)
        let original = try Data(contentsOf: source)
        precondition(existing == Data("existing".utf8) && original == payload)
        try fm.removeItem(at: target)
        try moveFile(item, in: report.root, to: dest)
        precondition(!fm.fileExists(atPath: source.path))
        let updated = report.updating(source: item, destination: target)
        let refreshed = try scan(root)
        precondition(updated.files == refreshed.files && updated.root.bytes == refreshed.root.bytes)
        precondition(updated.largestFiles.map(\.path) == refreshed.largestFiles.map(\.path))
        precondition(updated.root.children?.first?.children?.first?.name == "sample.txt")
        let moved = try Data(contentsOf: target)
        precondition(moved == payload)
        try payload.write(to: source)
        mustFail { try moveFile(item, in: report.root, to: dest) }
        try fm.removeItem(at: target)
        mustFail { try moveFile(item, in: report.root, to: dest) }
        let fresh = try scan(root)
        try copyAcrossVolumes(fresh.largestFiles[0], in: fresh.root, to: target)
        let copied = try Data(contentsOf: target)
        let contents = try fm.contentsOfDirectory(atPath: dest.path)
        precondition(copied == payload && contents == ["sample.txt"] && !fm.fileExists(atPath: source.path))
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let links = try scan(root)
        let linkItem = links.root.children!.first { $0.name == "link" }!
        try moveFile(linkItem, in: links.root, to: dest)
        let linkTarget = try fm.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("link").path)
        precondition(linkTarget == target.path)
        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        if geteuid() != 0 {
            let partial = try scan(root)
            precondition(partial.skipped > 0 && partial.root.skippedDescendants > 0)
            let readable = partial.largestFiles.first { $0.name == "sample.txt" }!
            mustFail { try moveFile(readable, in: partial.root, to: locked) }
            precondition(fm.fileExists(atPath: readable.url.path))
        }
        for n in 1...320 { try Data(repeating: 1, count: n).write(to: root.appendingPathComponent("f-\(n)")) }
        let monitor = ScanMonitor()
        let ranked = try scan(root, monitor: monitor)
        let progress = monitor.snapshot()
        let names = try fm.contentsOfDirectory(atPath: root.path)
        precondition(progress.total == names.count && progress.completed == progress.total)
        precondition(progress.bytes == ranked.root.bytes && progress.files == ranked.files)
        precondition(progress.skipped == ranked.skipped && progress.folders >= 2)

        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try scan(root, monitor: ScanMonitor())
        }
        do {
            _ = try await cancelled.value
            fatalError("Cancelled scan returned a result")
        } catch is CancellationError {}
        precondition(ranked.largestFiles.map(\.bytes) == Array((221...320).reversed()).map(Int64.init))
        let biggest = ranked.largestFiles[0]
        try fm.removeItem(at: biggest.url)
        let afterRemoval = ranked.updating(source: biggest, destination: nil)
        let expected = try scan(root)
        precondition(afterRemoval.files == expected.files && afterRemoval.root.bytes == expected.root.bytes)
        precondition(afterRemoval.largestFiles.map(\.path) == expected.largestFiles.map(\.path))
        print("Passed incremental move and removal, move, collision, stale source, staged copy, cleanup, ranking, scan progress and cancellation checks.")
    }
}
