import Foundation
import Darwin

public struct FileMeasure: Sendable {
    public var bytes: Int64 = 0
    public var count = 0
    public var unreadable = 0
    public var containsProtectedContent = false
    public var complete: Bool { unreadable == 0 && !containsProtectedContent }
}

public enum FileSizer {
    public static func measure(_ url: URL) throws -> FileMeasure {
        try Task.checkCancellation()
        var root = stat()
        guard lstat(url.path, &root) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard root.st_mode & S_IFMT != S_IFLNK else { throw CleanError.protectedPath(url.path) }
        var result = FileMeasure()
        var seen = Set<FileIdentity>()
        func add(_ info: stat) {
            guard seen.insert(FileIdentity(info)).inserted else { return }
            result.bytes += max(0, Int64(info.st_blocks) * 512)
            if info.st_mode & S_IFMT != S_IFDIR { result.count += 1 }
        }
        add(root)
        guard root.st_mode & S_IFMT == S_IFDIR else { return result }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in
            result.unreadable += 1; return true
        }) else { throw CleanError.incomplete }
        for case let child as URL in enumerator {
            try Task.checkCancellation()
            if child.lastPathComponent == ".git" {
                result.containsProtectedContent = true; enumerator.skipDescendants(); continue
            }
            var info = stat()
            guard lstat(child.path, &info) == 0 else { result.unreadable += 1; continue }
            if info.st_dev != root.st_dev { result.containsProtectedContent = true; enumerator.skipDescendants(); continue }
            if info.st_mode & S_IFMT == S_IFLNK { enumerator.skipDescendants() }
            add(info)
        }
        return result
    }
}
