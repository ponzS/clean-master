import Foundation
import Darwin

public enum ItemGroup: String, CaseIterable, Identifiable, Sendable {
    case caches = "应用与开发缓存"
    case development = "Xcode 开发数据"
    case simulators = "iOS 模拟器"
    case wallpapers = "动态壁纸"
    case applications = "应用卸载与数据"
    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .caches: "square.stack.3d.up"
        case .development: "hammer"
        case .simulators: "iphone"
        case .wallpapers: "photo"
        case .applications: "app.badge.checkmark"
        }
    }
}

public enum ItemRisk: String, Sendable {
    case regenerable = "可重新生成"
    case review = "按需保留"
    case managed = "由 Xcode 管理"
}

public struct FileIdentity: Hashable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
}

public struct FileSnapshot: Sendable {
    public let url: URL
    public let identity: FileIdentity
    public let ruleID: String
    public init(url: URL, identity: FileIdentity, ruleID: String) {
        self.url = url; self.identity = identity; self.ruleID = ruleID
    }
}

public enum CleanupAction: Sendable {
    case files([FileSnapshot])
    case simulatorDevice(id: String)
    case simulatorRuntime(id: String, path: String)
    case simulatorCaches
    case applicationFile(owner: InstalledApplication, location: ApplicationLocation, snapshot: FileSnapshot)

    public var isManaged: Bool {
        switch self { case .files, .applicationFile: false; default: true }
    }
    public var order: Int {
        switch self {
        case .simulatorCaches: 0
        case .simulatorDevice: 1
        case .simulatorRuntime: 2
        case .files: 3
        case .applicationFile(_, let location, _): location.match == .application ? 10 : 4
        }
    }
}

public struct DiskItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let group: ItemGroup
    public let risk: ItemRisk
    public let bytes: Int64
    public let fileCount: Int
    public let paths: [String]
    public let impact: String
    public let action: CleanupAction
    public let blockers: [String]
    public var issue: String?
    public var canClean: Bool { issue == nil }
    public var isManaged: Bool { action.isManaged }
}

public struct ScanIssue: Identifiable, Sendable {
    public let id = UUID()
    public let path: String
    public let message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public struct ScanReport: Sendable {
    public var items: [DiskItem] = []
    public var issues: [ScanIssue] = []
    public var scannedLocations = 0
    public var date = Date()
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

public struct DiskSpace: Sendable {
    public let total: Int64
    public let available: Int64
    public var used: Int64 { max(0, total - available) }
    public static func read(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiskSpace? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let total = attributes[.systemSize] as? NSNumber,
              let free = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return DiskSpace(total: total.int64Value, available: free.int64Value)
    }
}

public enum CleanupMode: String, CaseIterable, Identifiable, Sendable {
    case trash = "移到废纸篓"
    case permanent = "永久删除"
    public var id: String { rawValue }
}

public struct CleanupResult: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let success: Bool
    public let message: String
    public init(id: String, title: String, success: Bool, message: String) {
        self.id = id; self.title = title; self.success = success; self.message = message
    }
}

public struct CleanupRecord: Identifiable, Codable, Sendable {
    public var id = UUID()
    public let date: Date
    public let mode: String
    public let estimatedBytes: Int64
    public let freeSpaceChange: Int64?
    public let results: [CleanupResult]
    public init(date: Date, mode: String, estimatedBytes: Int64, freeSpaceChange: Int64?, results: [CleanupResult]) {
        self.date = date; self.mode = mode; self.estimatedBytes = estimatedBytes
        self.freeSpaceChange = freeSpaceChange; self.results = results
    }
}

public enum CleanError: LocalizedError {
    case protectedPath(String), changed, incomplete, running, managedRequiresPermanent, command(String)
    public var errorDescription: String? {
        switch self {
        case .protectedPath(let path): "路径不在可清理范围，或指向受保护位置：\(path)"
        case .changed: "项目自扫描后发生了变化，请重新扫描。"
        case .incomplete: "此目录未能完整读取，或包含受保护内容，未执行清理。"
        case .running: "关联应用或模拟器正在运行，请退出后重新扫描。"
        case .managedRequiresPermanent: "模拟器项目需选择“永久删除”，通过 Xcode 自带工具移除。"
        case .command(let message): message
        }
    }
}

public func byteString(_ value: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .decimal
    f.allowsNonnumericFormatting = false
    f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return f.string(fromByteCount: max(0, value))
}
