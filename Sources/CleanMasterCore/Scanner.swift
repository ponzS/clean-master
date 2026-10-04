import Foundation
import Darwin

public struct DiskScanner: Sendable {
    public let policy: PathPolicy
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { policy = PathPolicy(home: home) }

    public func scan(runningApps: Set<String> = [], includeSimulators: Bool = true,
                     progress: @Sendable (String, Double) -> Void = { _, _ in }) throws -> ScanReport {
        var report = ScanReport()
        for (index, rule) in Catalog.rules.enumerated() {
            try Task.checkCancellation()
            progress(rule.name, Double(index) / Double(Catalog.rules.count + 2))
            report.scannedLocations += 1
            let root = policy.home.appendingPathComponent(rule.relativePath)
            do {
                try policy.rejectSymlinkAncestors(root)
                let urls: [URL]
                switch rule.layout {
                case .whole: urls = [root]
                case .children: urls = try children(root)
                case .archives:
                    urls = try children(root).filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
                        .flatMap { try children($0).filter { $0.pathExtension == "xcarchive" } }
                case .nestedCaches: urls = try cacheDirectories(root, issues: &report.issues)
                }
                if case .nestedCaches = rule.layout {
                    if let item = try makeItem(urls: urls, rule: rule, title: rule.name, runningApps: runningApps) { report.items.append(item) }
                } else {
                    for url in urls {
                        try Task.checkCancellation()
                        let title: String
                        if case .whole = rule.layout { title = rule.name }
                        else { title = url.deletingPathExtension().lastPathComponent }
                        do {
                            if let item = try makeItem(urls: [url], rule: rule, title: title, runningApps: runningApps) { report.items.append(item) }
                        } catch {
                            if error is CancellationError { throw error }
                            if !isMissing(error) { report.issues.append(.init(path: url.path, message: error.localizedDescription)) }
                        }
                    }
                }
            } catch {
                if error is CancellationError { throw error }
                if !isMissing(error) { report.issues.append(.init(path: root.path, message: error.localizedDescription)) }
            }
        }
        if includeSimulators {
            progress("iOS 模拟器与系统组件", 0.94)
            scanSimulators(into: &report)
        }
        try Task.checkCancellation()
        report.items.sort { $0.bytes > $1.bytes }
        report.date = Date()
        progress("扫描完成", 1)
        return report
    }

    private func makeItem(urls: [URL], rule: ScanRule, title: String, runningApps: Set<String>) throws -> DiskItem? {
        var snapshots: [FileSnapshot] = [], bytes: Int64 = 0, count = 0, issue: String?
        for url in urls {
            let snapshot = try policy.snapshot(url, ruleID: rule.id)
            let measure = try FileSizer.measure(url)
            if measure.containsProtectedContent { issue = "目录中包含代码仓库或其他磁盘，已保护。" }
            else if measure.unreadable > 0 { issue = "有 \(measure.unreadable) 个位置无法读取，需授权后重新扫描。" }
            snapshots.append(snapshot); bytes += measure.bytes; count += measure.count
        }
        guard !snapshots.isEmpty, bytes > 0 || count > 0 || issue != nil else { return nil }
        if !runningApps.isDisjoint(with: rule.blockers) { issue = "关联应用正在使用这些文件，请退出应用后重新扫描。" }
        return DiskItem(id: rule.id + ":" + (urls.first?.path ?? ""), title: title, subtitle: rule.name,
                        group: rule.group, risk: rule.risk, bytes: bytes, fileCount: count,
                        paths: urls.map(\.path), impact: rule.impact, action: .files(snapshots), blockers: rule.blockers, issue: issue)
    }

    private func children(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }

    private func cacheDirectories(_ root: URL, issues: inout [ScanIssue]) throws -> [URL] {
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var paths: [URL] = [], errors: [ScanIssue] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { path, error in
            errors.append(.init(path: path.path, message: error.localizedDescription)); return true
        }) else { throw CleanError.incomplete }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            var entry = stat()
            guard lstat(url.path, &entry) == 0 else { continue }
            if entry.st_mode & S_IFMT == S_IFLNK || entry.st_dev != info.st_dev || url.lastPathComponent == ".git" {
                enumerator.skipDescendants(); continue
            }
            let depth = url.pathComponents.count - root.pathComponents.count
            if depth > 8 { enumerator.skipDescendants(); continue }
            if entry.st_mode & S_IFMT == S_IFDIR, Catalog.browserCacheNames.contains(url.lastPathComponent) {
                paths.append(url); enumerator.skipDescendants()
            }
        }
        issues.append(contentsOf: errors)
        return paths.sorted { $0.path < $1.path }
    }

    private func scanSimulators(into report: inout ScanReport) {
        do {
            let devices = try SimulatorService.devices()
            for device in devices where SimulatorService.validID(device.udid) {
                try Task.checkCancellation()
                let url = policy.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices").appendingPathComponent(device.udid)
                do {
                    try policy.rejectSymlinkAncestors(url)
                    let size = try FileSizer.measure(url)
                    let issue = device.state != "Shutdown" ? "模拟器正在运行，请关闭后重新扫描。" : (!size.complete ? "设备数据未能完整读取。" : nil)
                    report.items.append(DiskItem(id: "device:" + device.udid, title: device.name,
                        subtitle: device.runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: ""),
                        group: .simulators, risk: .managed, bytes: size.bytes, fileCount: size.count, paths: [url.path],
                        impact: "移除这台模拟设备及其中的应用、登录状态和测试数据。需要时可重新创建设备。",
                        action: .simulatorDevice(id: device.udid), blockers: [], issue: issue))
                } catch {
                    if error is CancellationError { throw error }
                    if !isMissing(error) { report.issues.append(.init(path: url.path, message: error.localizedDescription)) }
                }
            }
            for runtime in try SimulatorService.runtimes() where SimulatorService.validID(runtime.identifier) && SimulatorService.validRuntimePath(runtime.path) {
                let inUse = devices.contains { $0.runtime == runtime.runtimeIdentifier && $0.state != "Shutdown" }
                let issue = inUse ? "有设备正在使用此系统，请关闭模拟器后重新扫描。" : (runtime.deletable == false ? "Xcode 将此系统标为不可移除。" : nil)
                report.items.append(DiskItem(id: "runtime:" + runtime.identifier, title: "iOS " + runtime.version + " 系统",
                    subtitle: "构建版本 " + runtime.build, group: .simulators, risk: .managed,
                    bytes: runtime.sizeBytes ?? 0, fileCount: 1, paths: [runtime.path],
                    impact: "卸载这一版本的模拟器系统。再次使用时，需要通过 Xcode 下载。关联模拟设备的数据可单独选择清理。",
                    action: .simulatorRuntime(id: runtime.identifier, path: runtime.path), blockers: [], issue: issue))
            }
            let caches = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches")
            if let size = try? FileSizer.measure(caches), size.bytes > 0 {
                report.items.append(DiskItem(id: "simulator-caches", title: "模拟器共享缓存", subtitle: "dyld shared cache", group: .simulators,
                    risk: .managed, bytes: size.bytes, fileCount: size.count, paths: [caches.path],
                    impact: "通过 Xcode 工具移除共享缓存；再次启动模拟器可能需要重新生成。",
                    action: .simulatorCaches, blockers: [], issue: devices.contains { $0.state != "Shutdown" } ? "请先关闭正在运行的模拟器。" : (!size.complete ? "缓存目录未能完整读取。" : nil)))
            }
        } catch {
            if !(error is CancellationError) { report.issues.append(.init(path: "iOS 模拟器", message: "无法获取模拟器信息。" + error.localizedDescription)) }
        }
    }

    private func isMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)) ||
            (ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code))
    }
}
