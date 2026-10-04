import XCTest
import Foundation
import Darwin
@testable import CleanMasterCore

final class CleanMasterCoreTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        home = project.appendingPathComponent(".build/test-fixtures/" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let home {
            if let entries = fm.enumerator(at: home, includingPropertiesForKeys: nil) {
                for case let url as URL in entries {
                    var info = stat()
                    if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { _ = chmod(url.path, 0o700) }
                }
            }
            try fm.removeItem(at: home)
        }
    }

    @discardableResult private func write(_ relative: String, bytes: Int = 8192) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }
    private func scan() throws -> ScanReport { try DiskScanner(home: home).scan(includeSimulators: false) }

    func testOnlyKnownCachesAreCandidatesAndDesktopRemainsExcluded() throws {
        try write(".npm/_cacache/content/package")
        let source = try write("Desktop/project/node_modules/large-file")
        try write("Documents/important.txt")
        let report = try scan()
        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.subtitle, "npm 下载缓存")
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testSpoofedDesktopTargetCannotBeDeleted() throws {
        let source = try write("Desktop/project/main.swift")
        var info = stat(); XCTAssertEqual(lstat(source.path, &info), 0)
        let fake = FileSnapshot(url: source, identity: FileIdentity(info), ruleID: "npm")
        XCTAssertThrowsError(try PathPolicy(home: home).revalidate(fake))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testSymlinkedCacheRootIsNotScannedOrCleaned() throws {
        let source = try write("Desktop/project/source.txt")
        let npm = home.appendingPathComponent(".npm")
        try fm.createDirectory(at: npm, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: npm.appendingPathComponent("_cacache"), withDestinationURL: source.deletingLastPathComponent())
        let report = try scan()
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertFalse(report.issues.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testCacheSymlinkContentsDoNotTouchTheirDestination() throws {
        try write(".npm/_cacache/content/package")
        let source = try write("Desktop/project/source.txt")
        let link = home.appendingPathComponent(".npm/_cacache/linked-project")
        try fm.createSymbolicLink(at: link, withDestinationURL: source.deletingLastPathComponent())
        let item = try XCTUnwrap(try scan().items.first)
        let result = DiskCleaner(home: home).clean(item, mode: .permanent, runningApps: [])
        XCTAssertTrue(result.success, result.message)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".npm/_cacache").path))
    }

    func testChangedFileIdentityPreventsCleaning() throws {
        try write(".npm/_cacache/content/package")
        let item = try XCTUnwrap(try scan().items.first)
        let old = home.appendingPathComponent(".npm/_cacache")
        try fm.moveItem(at: old, to: home.appendingPathComponent("old-cache"))
        let replacement = try write(".npm/_cacache/new-file")
        let result = DiskCleaner(home: home).clean(item, mode: .permanent, runningApps: [])
        XCTAssertFalse(result.success)
        XCTAssertTrue(fm.fileExists(atPath: replacement.path))
    }

    func testAncestorSymlinkIntroducedAfterScanIsRejected() throws {
        try write(".npm/_cacache/content/package")
        let item = try XCTUnwrap(try scan().items.first)
        let npm = home.appendingPathComponent(".npm")
        try fm.moveItem(at: npm, to: home.appendingPathComponent("original-npm"))
        try fm.createSymbolicLink(at: npm, withDestinationURL: home.appendingPathComponent("original-npm"))
        let result = DiskCleaner(home: home).clean(item, mode: .permanent, runningApps: [])
        XCTAssertFalse(result.success)
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("original-npm/_cacache/content/package").path))
    }

    func testRepositoriesInsideCacheAreProtected() throws {
        try write(".npm/_cacache/project/.git/config")
        let source = try write(".npm/_cacache/project/main.swift")
        let item = try XCTUnwrap(try scan().items.first)
        XCTAssertFalse(item.canClean)
        let result = DiskCleaner(home: home).clean(item, mode: .permanent, runningApps: [])
        XCTAssertFalse(result.success)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testOnlySelectedCacheIsRemoved() throws {
        try write(".npm/_cacache/content/package")
        let untouched = try write(".npm/_npx/tool")
        let item = try XCTUnwrap(try scan().items.first(where: { $0.subtitle == "npm 下载缓存" }))
        let result = DiskCleaner(home: home).clean(item, mode: .permanent, runningApps: [])
        XCTAssertTrue(result.success, result.message)
        XCTAssertTrue(fm.fileExists(atPath: untouched.path))
    }

    func testRunningBrowserIsCheckedAgainBeforeCleaning() throws {
        let cache = try write("Library/Caches/BraveSoftware/Brave-Browser/file")
        let item = try XCTUnwrap(try scan().items.first)
        let result = DiskCleaner(home: home).clean(item, mode: .permanent, runningApps: ["com.brave.Browser"])
        XCTAssertFalse(result.success)
        XCTAssertTrue(fm.fileExists(atPath: cache.path))
    }

    func testSparseFilesUseAllocatedSizeAndHardLinksAreDeduplicated() throws {
        let file = try write(".npm/_cacache/sparse", bytes: 4096)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 32 * 1024 * 1024)
        try handle.write(contentsOf: Data([1])); try handle.close()
        let first = try FileSizer.measure(file)
        XCTAssertLessThan(first.bytes, 32 * 1024 * 1024)
        try fm.linkItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("hard-link"))
        let directory = try FileSizer.measure(file.deletingLastPathComponent())
        XCTAssertLessThan(directory.bytes, first.bytes * 2)
    }

    func testArchiveAndNestedCacheRulesStayWithinExpectedDepth() throws {
        let policy = PathPolicy(home: home)
        XCTAssertNoThrow(try policy.validate(home.appendingPathComponent("Library/Developer/Xcode/Archives/2026-09-22/App.xcarchive"), ruleID: "archives"))
        XCTAssertThrowsError(try policy.validate(home.appendingPathComponent("Library/Developer/Xcode/Archives"), ruleID: "archives"))
        XCTAssertThrowsError(try policy.validate(home.appendingPathComponent("Library/Application Support/lzc-client-desktop/webapp_userData/Local Storage"), ruleID: "lazycat"))
    }

    func testSimulatorIdentifiersCannotBecomeCommandArguments() {
        XCTAssertTrue(SimulatorService.validID(UUID().uuidString))
        XCTAssertFalse(SimulatorService.validID("all"))
        XCTAssertFalse(SimulatorService.validID("--unusable"))
        XCTAssertFalse(SimulatorService.validID("; rm -rf /"))
        XCTAssertFalse(SimulatorService.validRuntimePath(home.appendingPathComponent("Desktop/runtime").path))
    }

    func testCancelledScanDoesNotPublishPartialResults() async throws {
        try write(".npm/_cacache/file")
        let scanner = DiskScanner(home: home)
        let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try scanner.scan(includeSimulators: false) { _, fraction in
                if fraction == 0 {
                    started.signal()
                    _ = resume.wait(timeout: .now() + 5)
                }
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        task.cancel()
        resume.signal()
        do { _ = try await task.value; XCTFail("Cancelled scan must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testReadOnlyGoModuleDirectoriesCanBeCleaned() throws {
        let module = try write("go/pkg/mod/example.org/tool@v1.0/source.go")
        let moduleDirectory = module.deletingLastPathComponent()
        XCTAssertEqual(chmod(moduleDirectory.path, 0o555), 0)
        let item = try XCTUnwrap(try scan().items.first)
        let result = DiskCleaner(home: home).clean(item, mode: .permanent, runningApps: [])
        XCTAssertTrue(result.success, result.message)
        XCTAssertFalse(fm.fileExists(atPath: module.path))
    }

    func testLazycatOnlySelectsCacheDirectories() throws {
        try write("Library/Application Support/lzc-client-desktop/webapp_userData/Cache/data")
        let loginData = try write("Library/Application Support/lzc-client-desktop/webapp_userData/Local Storage/session")
        let item = try XCTUnwrap(try scan().items.first)
        let result = DiskCleaner(home: home).clean(item, mode: .permanent, runningApps: [])
        XCTAssertTrue(result.success, result.message)
        XCTAssertTrue(fm.fileExists(atPath: loginData.path))
    }
}
