import Foundation
import Darwin

public struct DiskCleaner: Sendable {
    public let policy: PathPolicy
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { policy = PathPolicy(home: home) }

    public func clean(_ item: DiskItem, mode: CleanupMode, runningApps: Set<String>) -> CleanupResult {
        do {
            guard item.canClean else { throw CleanError.incomplete }
            guard runningApps.isDisjoint(with: item.blockers) else { throw CleanError.running }
            switch item.action {
            case .applicationFile(let owner, let location, let snapshot):
                let appPolicy = ApplicationPolicy(home: policy.home)
                try appPolicy.revalidate(snapshot, location: location, owner: owner)
                guard try FileSizer.measure(snapshot.url).complete else { throw CleanError.incomplete }
                try appPolicy.revalidate(snapshot, location: location, owner: owner)
                if mode == .trash { try FileManager.default.trashItem(at: snapshot.url, resultingItemURL: nil) }
                else { try FileManager.default.removeItem(at: snapshot.url) }
                var info = stat()
                guard lstat(snapshot.url.path, &info) != 0 && errno == ENOENT else { throw CleanError.command("项目仍然存在，请重新检查。") }
            case .files(let snapshots):
                // Check every target before starting a grouped operation.
                for snapshot in snapshots {
                    try policy.revalidate(snapshot)
                    guard try FileSizer.measure(snapshot.url).complete else { throw CleanError.incomplete }
                }
                var completed = 0
                do {
                    for snapshot in snapshots {
                        try policy.revalidate(snapshot)
                        if mode == .trash {
                            try FileManager.default.trashItem(at: snapshot.url, resultingItemURL: nil)
                        } else {
                            try removePermanently(snapshot)
                        }
                        var info = stat()
                        guard lstat(snapshot.url.path, &info) != 0 && errno == ENOENT else { throw CleanError.command("操作后项目仍然存在，请重新扫描。") }
                        completed += 1
                    }
                } catch { throw CleanError.command("已处理 \(completed)/\(snapshots.count) 个目录。\(error.localizedDescription)") }
            case .simulatorDevice(let id):
                try requirePermanent(mode)
                guard SimulatorService.validID(id) else { throw CleanError.changed }
                guard let current = try SimulatorService.devices().first(where: { $0.udid == id }) else { throw CleanError.changed }
                guard current.state == "Shutdown" else { throw CleanError.running }
                _ = try ToolRunner.run(["delete", id], timeout: 120)
                guard try !SimulatorService.devices().contains(where: { $0.udid == id }) else { throw CleanError.command("设备仍存在，未能完成移除。") }
            case .simulatorRuntime(let id, let path):
                try requirePermanent(mode)
                guard SimulatorService.validID(id), SimulatorService.validRuntimePath(path),
                      let current = try SimulatorService.runtimes().first(where: { $0.identifier == id }),
                      current.path == path, current.deletable != false else { throw CleanError.changed }
                guard try !SimulatorService.devices().contains(where: { $0.runtime == current.runtimeIdentifier && $0.state != "Shutdown" }) else { throw CleanError.running }
                _ = try ToolRunner.run(["runtime", "delete", id], timeout: 120)
                guard try !SimulatorService.runtimes().contains(where: { $0.identifier == id }) else { throw CleanError.command("系统组件仍存在，未能完成移除。") }
            case .simulatorCaches:
                try requirePermanent(mode)
                guard try !SimulatorService.devices().contains(where: { $0.state != "Shutdown" }) else { throw CleanError.running }
                _ = try ToolRunner.run(["runtime", "dyld_shared_cache", "remove", "--all"], timeout: 120)
                let remaining = try FileSizer.measure(URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches"))
                guard remaining.complete, remaining.bytes < 1_048_576 else { throw CleanError.command("Xcode 已处理共享缓存，但仍有缓存残留，请重新扫描查看。") }
            }
            return CleanupResult(id: item.id, title: item.title, success: true,
                                 message: mode == .trash ? "已移到废纸篓，可在 Finder 中恢复。" : "已清理。")
        } catch {
            return CleanupResult(id: item.id, title: item.title, success: false, message: error.localizedDescription)
        }
    }

    private func requirePermanent(_ mode: CleanupMode) throws {
        guard mode == .permanent else { throw CleanError.managedRequiresPermanent }
    }

    private func removePermanently(_ snapshot: FileSnapshot) throws {
        do { try FileManager.default.removeItem(at: snapshot.url) }
        catch {
            // Downloaded Go modules may have owner-read-only directories. Never chmod
            // a regular file (it could be hard-linked into a working repository).
            try policy.revalidate(snapshot)
            let ns = error as NSError
            guard (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError) || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(EACCES)) else { throw error }
            guard try FileSizer.measure(snapshot.url).complete else { throw CleanError.incomplete }
            let manager = FileManager.default
            var rootInfo = stat()
            guard lstat(snapshot.url.path, &rootInfo) == 0 else { throw CleanError.changed }
            func writableDirectory(_ url: URL) {
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return }
                _ = chmod(url.path, info.st_mode | S_IWUSR | S_IXUSR)
            }
            writableDirectory(snapshot.url)
            if let e = manager.enumerator(at: snapshot.url, includingPropertiesForKeys: nil) {
                for case let url as URL in e {
                    var info = stat()
                    guard lstat(url.path, &info) == 0 else { continue }
                    if info.st_mode & S_IFMT == S_IFLNK || info.st_dev != rootInfo.st_dev || url.lastPathComponent == ".git" { e.skipDescendants(); continue }
                    writableDirectory(url)
                }
            }
            try policy.revalidate(snapshot)
            try manager.removeItem(at: snapshot.url)
        }
    }
}
