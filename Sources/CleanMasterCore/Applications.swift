import Foundation
import Darwin

public enum ApplicationOperation: String, CaseIterable, Identifiable, Sendable {
    case uninstall = "卸载应用与数据"
    case dataOnly = "仅清理应用数据"
    public var id: String { rawValue }
}

public struct InstalledApplication: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String
    public let identity: FileIdentity
    public var id: String { url.path }
    public var blockers: [String] { [bundleID, "path:" + url.path].compactMap { $0 } }
}

public enum ApplicationMatch: String, Sendable {
    case application = "应用本体"
    case identifier = "标识符匹配"
    case known = "已知关联"
    case nameOnly = "仅名称匹配 · 请核对"
}

public struct ApplicationLocation: Sendable {
    public let url: URL
    public let title: String
    public let match: ApplicationMatch
    public let impact: String
    public var id: String { url.path }
    public var isRecommended: Bool { match != .nameOnly }
}

public struct ApplicationInventory: Sendable {
    public var applications: [InstalledApplication] = []
    public var issues: [ScanIssue] = []
    public init() {}
}

public struct ApplicationScan: Sendable {
    public var items: [DiskItem] = []
    public var issues: [ScanIssue] = []
    public init() {}
}

public struct ApplicationPolicy: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home.standardizedFileURL }
    public var roots: [URL] { [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] }

    public func validateApplicationPath(_ url: URL) throws {
        let target = url.standardizedFileURL
        guard target.pathExtension == "app", roots.contains(where: { root in
            let depth = target.pathComponents.count - root.pathComponents.count
            let ancestors = target.pathComponents.dropFirst(root.pathComponents.count).dropLast()
            return PathPolicy.isInside(target, root) && (1...3).contains(depth) && !ancestors.contains { $0.hasSuffix(".app") }
        }) else { throw CleanError.protectedPath(target.path) }
        try PathPolicy(home: home).rejectSymlinkAncestors(target)
        // Safari is managed by macOS even on systems that expose it in /Applications.
        guard Bundle(url: target)?.bundleIdentifier != "com.apple.Safari",
              Bundle(url: target)?.bundleIdentifier != "local.ponzs.clean-master" else { throw CleanError.protectedPath(target.path) }
    }

    public func validateOwner(_ application: InstalledApplication) throws {
        try validateApplicationPath(application.url)
        var info = stat()
        guard lstat(application.url.path, &info) == 0, FileIdentity(info) == application.identity,
              Bundle(url: application.url)?.bundleIdentifier == application.bundleID else { throw CleanError.changed }
    }

    public func locations(for application: InstalledApplication) -> [ApplicationLocation] {
        var result = [ApplicationLocation(url: application.url, title: "应用本体", match: .application,
            impact: "移除 \(application.name) 应用。移到废纸篓后可恢复；永久删除后需要重新安装。")]
        func add(_ relative: String, _ title: String, _ match: ApplicationMatch, _ impact: String) {
            let url = home.appendingPathComponent(relative).standardizedFileURL
            guard !result.contains(where: { $0.url == url }) else { return }
            result.append(.init(url: url, title: title, match: match, impact: impact))
        }
        let dataImpact = "可能包含登录状态、本地数据库、未同步内容和应用设置。清理后应用可能恢复初始状态，请先确认重要内容已备份。"
        if let id = application.bundleID, Self.validIdentifier(id) {
            add("Library/Caches/" + id, "应用缓存", .identifier, "后续使用会重新生成缓存。")
            add("Library/Preferences/" + id + ".plist", "偏好设置", .identifier, "重置此应用的本地偏好设置。")
            add("Library/Saved Application State/" + id + ".savedState", "窗口恢复状态", .identifier, "清除上次打开的窗口与恢复状态。")
            add("Library/Application Support/" + id, "应用支持数据", .identifier, dataImpact)
            add("Library/Containers/" + id, "应用沙盒数据", .identifier, dataImpact)
            add("Library/HTTPStorages/" + id, "网页与登录存储", .identifier, dataImpact)
            add("Library/HTTPStorages/" + id + ".binarycookies", "登录 Cookie", .identifier, "可能需要重新登录。")
            add("Library/WebKit/" + id, "内嵌网页数据", .identifier, dataImpact)
            let known: [String: [String]] = [
                "com.microsoft.VSCode": ["Library/Application Support/Code", ".vscode", "Library/Caches/com.microsoft.VSCode.ShipIt"],
                "com.google.Chrome": ["Library/Application Support/Google/Chrome", "Library/Caches/Google/Chrome"],
                "com.brave.Browser": ["Library/Application Support/BraveSoftware/Brave-Browser", "Library/Caches/BraveSoftware/Brave-Browser"],
                "cloud.lazycat.client": ["Library/Application Support/lzc-client-desktop"],
                "com.todesktop.230313mzl4w4u92": ["Library/Application Support/Cursor", ".cursor"]
            ]
            for path in known[id] ?? [] { add(path, "应用数据 · " + URL(fileURLWithPath: path).lastPathComponent, .known, dataImpact) }
        }
        // A same-name folder is only a suggestion, never selected by default.
        let names = Set([application.name, application.url.deletingPathExtension().lastPathComponent])
        let sharedNames: Set<String> = ["apple", "google", "microsoft", "adobe", "shared", "library", "caches", "containers", "preferences", "application support", "desktop", "documents"]
        for name in names.sorted() where name.count >= 3 && !name.contains("/") && name != ".." && !sharedNames.contains(name.lowercased()) {
            add("Library/Application Support/" + name, "可能关联的数据 · " + name, .nameOnly,
                "仅根据文件夹名称推测关联，可能被其他应用使用。请先核对目录内容。" + dataImpact)
            add("Library/Caches/" + name, "可能关联的缓存 · " + name, .nameOnly,
                "仅名称相同，尚不能确认归属；请核对后再选择。")
        }
        return result
    }

    public func snapshot(_ location: ApplicationLocation, owner: InstalledApplication) throws -> FileSnapshot {
        try validateOwner(owner)
        guard locations(for: owner).contains(where: { $0.url == location.url && $0.match == location.match }) else { throw CleanError.protectedPath(location.url.path) }
        try PathPolicy(home: home).rejectSymlinkAncestors(location.url)
        var info = stat()
        guard lstat(location.url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileSnapshot(url: location.url, identity: FileIdentity(info), ruleID: location.id)
    }

    public func revalidate(_ snapshot: FileSnapshot, location: ApplicationLocation, owner: InstalledApplication) throws {
        guard snapshot.url == location.url, snapshot.ruleID == location.id else { throw CleanError.changed }
        let current = try self.snapshot(location, owner: owner)
        guard current.identity == snapshot.identity else { throw CleanError.changed }
    }

    public static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil && value.count < 200
    }
}

public struct ApplicationCleaner: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public func clean(_ items: [DiskItem], operation: ApplicationOperation, mode: CleanupMode,
                      runningApps: @Sendable () async -> Set<String>,
                      progress: @Sendable (String) -> Void = { _ in }) async -> [CleanupResult] {
        // The data-only contract is enforced here, independently of checkbox state.
        let targets = items.filter { item in
            guard case .applicationFile(_, let location, _) = item.action else { return false }
            return operation == .uninstall || location.match != .application
        }.sorted { $0.action.order < $1.action.order }
        let owners = Set(targets.compactMap { item -> String? in
            if case .applicationFile(let owner, _, _) = item.action { return owner.id }
            return nil
        })
        guard owners.count <= 1 else {
            return targets.map { .init(id: $0.id, title: $0.title, success: false, message: "每次仅处理一个应用，请重新选择。") }
        }
        var results: [CleanupResult] = []
        for item in targets {
            progress(item.title)
            if case .applicationFile(_, let location, _) = item.action, location.match == .application,
               results.contains(where: { !$0.success }) {
                results.append(.init(id: item.id, title: item.title, success: false,
                    message: "部分所选数据未处理成功，应用已保留，便于检查后重试。"))
                continue
            }
            let running = await runningApps()
            let result = await Task.detached(priority: .utility) { DiskCleaner(home: home).clean(item, mode: mode, runningApps: running) }.value
            results.append(result)
        }
        return results
    }
}

public struct ApplicationScanner: Sendable {
    public let policy: ApplicationPolicy
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { policy = ApplicationPolicy(home: home) }

    public func inventory(includeSystemApplications: Bool = true) throws -> ApplicationInventory {
        var result = ApplicationInventory()
        let roots = includeSystemApplications ? policy.roots : [policy.home.appendingPathComponent("Applications")]
        func visit(_ directory: URL, depth: Int) throws {
            try Task.checkCancellation()
            do {
                try PathPolicy(home: policy.home).rejectSymlinkAncestors(directory)
                let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                for url in children {
                    try Task.checkCancellation()
                    var info = stat()
                    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                    if url.pathExtension == "app" {
                        guard (try? policy.validateApplicationPath(url)) != nil, let bundle = Bundle(url: url) else { continue }
                        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String ?? url.deletingPathExtension().lastPathComponent
                        result.applications.append(.init(url: url, name: name, bundleID: bundle.bundleIdentifier,
                            version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                            identity: FileIdentity(info)))
                    } else if depth < 2, url.pathExtension.isEmpty {
                        try visit(url, depth: depth + 1)
                    }
                }
            } catch {
                if error is CancellationError { throw error }
                if !isMissing(error) { result.issues.append(.init(path: directory.path, message: error.localizedDescription)) }
            }
        }
        for root in roots { try visit(root, depth: 0) }
        result.applications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    public func scan(_ application: InstalledApplication, runningApps: Set<String>,
                     progress: @Sendable (String) -> Void = { _ in }) throws -> ApplicationScan {
        try policy.validateOwner(application)
        var result = ApplicationScan()
        for location in policy.locations(for: application) {
            try Task.checkCancellation()
            progress(location.title)
            do {
                let snapshot = try policy.snapshot(location, owner: application)
                let size = try FileSizer.measure(location.url)
                var issue: String?
                if !size.complete { issue = "未能完整读取，或包含代码仓库；此项目已保护。" }
                if !runningApps.isDisjoint(with: application.blockers) { issue = "应用正在运行，请完全退出后重新检查。" }
                result.items.append(.init(id: "application:" + location.url.path, title: application.name + " · " + location.title,
                    subtitle: location.match.rawValue, group: .applications, risk: .review,
                    bytes: size.bytes, fileCount: size.count, paths: [location.url.path], impact: location.impact,
                    action: .applicationFile(owner: application, location: location, snapshot: snapshot), blockers: application.blockers, issue: issue))
            } catch {
                if error is CancellationError { throw error }
                if !isMissing(error) { result.issues.append(.init(path: location.url.path, message: error.localizedDescription)) }
            }
        }
        return result
    }

    private func isMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)) ||
            (ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code))
    }
}
