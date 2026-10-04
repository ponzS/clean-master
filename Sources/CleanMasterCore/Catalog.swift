import Foundation
import Darwin

public struct ScanRule: Sendable {
    public enum Layout: Sendable { case whole, children, archives, nestedCaches }
    public let id: String
    public let name: String
    public let relativePath: String
    public let group: ItemGroup
    public let impact: String
    public let risk: ItemRisk
    public let layout: Layout
    public let blockers: [String]

    public init(_ id: String, _ name: String, _ path: String, group: ItemGroup = .caches,
                impact: String = "需要时会重新生成或下载，下次使用可能稍慢。",
                risk: ItemRisk = .regenerable, layout: Layout = .whole, blockers: [String] = []) {
        self.id = id; self.name = name; relativePath = path; self.group = group
        self.impact = impact; self.risk = risk; self.layout = layout; self.blockers = blockers
    }
}

public enum Catalog {
    public static let browserCacheNames: Set<String> = ["Cache", "Code Cache", "GPUCache", "ShaderCache", "DawnGraphiteCache", "DawnWebGPUCache"]
    public static let rules: [ScanRule] = [
        .init("derived", "Xcode 编译缓存", "Library/Developer/Xcode/DerivedData", layout: .children, blockers: ["com.apple.dt.Xcode"]),
        .init("pods", "CocoaPods 下载缓存", "Library/Caches/CocoaPods"),
        .init("npm", "npm 下载缓存", ".npm/_cacache"),
        .init("npx", "npx 临时工具", ".npm/_npx"),
        .init("pnpm", "pnpm 包存储", "Library/pnpm/store", impact: "移除包存储后，后续安装依赖可能需要重新下载。共享文件的实际释放量可能低于占用。"),
        .init("pnpm-meta", "pnpm 元数据缓存", "Library/Caches/pnpm"),
        .init("react-native", "React Native 缓存", "Library/Caches/ReactNative"),
        .init("brave", "Brave 网页缓存", "Library/Caches/BraveSoftware", blockers: ["com.brave.Browser"]),
        .init("chrome", "Chrome 网页缓存", "Library/Caches/Google/Chrome", blockers: ["com.google.Chrome"]),
        .init("lazycat", "懒猫微服网页缓存", "Library/Application Support/lzc-client-desktop", impact: "只清理网页与代码缓存，保留登录信息、设置和本地应用数据。", layout: .nestedCaches, blockers: ["cloud.lazycat.client"]),
        .init("go-build", "Go 编译缓存", "Library/Caches/go-build"),
        .init("go-mod", "Go 模块下载缓存", "go/pkg/mod"),
        .init("cargo", "Cargo 依赖缓存", ".cargo/registry"),
        .init("playwright", "Playwright 浏览器组件", "Library/Caches/ms-playwright", impact: "后续自动化测试可能需要重新安装浏览器组件。"),
        .init("dotslash", "DotSlash 工具缓存", "Library/Caches/dotslash"),
        .init("typescript", "TypeScript 下载缓存", "Library/Caches/typescript"),
        .init("node-gyp", "Node 原生模块构建缓存", "Library/Caches/node-gyp"),
        .init("agent-device", "agent-device 编译缓存", ".agent-device/apple-runner/derived"),
        .init("vscode", "VS Code 启动缓存", "Library/Application Support/Code/CachedData", blockers: ["com.microsoft.VSCode"]),
        .init("homebrew", "Homebrew 下载缓存", "Library/Caches/Homebrew"),
        .init("device-support", "真机调试支持文件", "Library/Developer/Xcode/iOS DeviceSupport", group: .development, impact: "按不再调试的系统版本选择；下次连接对应设备调试时可能重新生成。", risk: .review, layout: .children, blockers: ["com.apple.dt.Xcode"]),
        .init("archives", "Xcode 发布归档", "Library/Developer/Xcode/Archives", group: .development, impact: "包含历史发布产物和调试符号。删除会影响重新导出与崩溃符号解析，请确认不再需要。", risk: .review, layout: .archives, blockers: ["com.apple.dt.Xcode"]),
        .init("wallpapers", "动态壁纸视频", "Library/Application Support/com.apple.wallpaper/aerials/videos", group: .wallpapers, impact: "重新使用对应壁纸时，macOS 可能再次下载。", risk: .review, layout: .children)
    ]
}

public struct PathPolicy: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }
    public var desktop: URL { home.appendingPathComponent("Desktop") }

    public static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.path, p = parent.standardizedFileURL.path
        return c == p || c.hasPrefix(p + "/")
    }

    public func validate(_ url: URL, ruleID: String) throws {
        guard let rule = Catalog.rules.first(where: { $0.id == ruleID }) else { throw CleanError.protectedPath(url.path) }
        let target = url.standardizedFileURL
        let root = home.appendingPathComponent(rule.relativePath).standardizedFileURL
        guard !Self.isInside(target, desktop), Self.isInside(target, root) else { throw CleanError.protectedPath(target.path) }
        let relative = String(target.path.dropFirst(root.path.count)).split(separator: "/").map(String.init)
        switch rule.layout {
        case .whole: guard relative.isEmpty else { throw CleanError.protectedPath(target.path) }
        case .children: guard relative.count == 1 else { throw CleanError.protectedPath(target.path) }
        case .archives:
            guard relative.count == 2, relative[1].hasSuffix(".xcarchive"),
                  relative[0].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw CleanError.protectedPath(target.path) }
        case .nestedCaches:
            guard (1...8).contains(relative.count), Catalog.browserCacheNames.contains(relative.last ?? "") else { throw CleanError.protectedPath(target.path) }
        }
        try rejectSymlinkAncestors(target)
    }

    public func rejectSymlinkAncestors(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard info.st_mode & S_IFMT != S_IFLNK else { throw CleanError.protectedPath(current.path) }
            } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            current.deleteLastPathComponent()
        }
    }

    public func snapshot(_ url: URL, ruleID: String) throws -> FileSnapshot {
        try validate(url, ruleID: ruleID)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileSnapshot(url: url, identity: FileIdentity(info), ruleID: ruleID)
    }

    public func revalidate(_ snapshot: FileSnapshot) throws {
        let now = try self.snapshot(snapshot.url, ruleID: snapshot.ruleID)
        guard now.identity == snapshot.identity else { throw CleanError.changed }
    }
}
