import XCTest
import Foundation
@testable import CleanMasterCore

final class ApplicationTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default
    let identifier = "org.cleanmaster.TestExample"

    override func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        home = project.appendingPathComponent(".build/test-fixtures/" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    @discardableResult private func write(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: url)
        return url
    }
    private func makeApplication(name: String = "TestExample", id: String? = nil) throws -> InstalledApplication {
        let plist = home.appendingPathComponent("Applications/\(name).app/Contents/Info.plist")
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id ?? identifier, "CFBundleName": name,
                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        return try XCTUnwrap(try ApplicationScanner(home: home).inventory(includeSystemApplications: false).applications.first { $0.name == name })
    }
    private func scan(_ app: InstalledApplication) throws -> ApplicationScan {
        try ApplicationScanner(home: home).scan(app, runningApps: [])
    }

    func testDataOnlyPreservesApplicationEvenIfInputIncludesItsBundle() async throws {
        let app = try makeApplication()
        let data = try write("Library/Application Support/\(identifier)/database")
        let unrelated = try write("Library/Application Support/org.other.App/database")
        let items = try scan(app).items
        XCTAssertEqual(items.count, 2)
        let results = await ApplicationCleaner(home: home).clean(items, operation: .dataOnly, mode: .permanent, runningApps: { [] })
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.allSatisfy(\.success))
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertFalse(fm.fileExists(atPath: data.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
    }

    func testUninstallRemovesSelectedDataThenApplication() async throws {
        let app = try makeApplication()
        let data = try write("Library/Application Support/\(identifier)/database")
        let results = await ApplicationCleaner(home: home).clean(try scan(app).items, operation: .uninstall, mode: .permanent, runningApps: { [] })
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy(\.success), results.map(\.message).joined(separator: "; "))
        XCTAssertFalse(fm.fileExists(atPath: app.url.path))
        XCTAssertFalse(fm.fileExists(atPath: data.path))
    }

    func testDataFailureKeepsApplicationForRetry() async throws {
        let app = try makeApplication()
        let data = try write("Library/Application Support/\(identifier)/database").deletingLastPathComponent()
        let items = try scan(app).items
        try fm.moveItem(at: data, to: home.appendingPathComponent("old-data"))
        let replacement = try write("Library/Application Support/\(identifier)/replacement")
        let results = await ApplicationCleaner(home: home).clean(items, operation: .uninstall, mode: .permanent, runningApps: { [] })
        XCTAssertTrue(results.allSatisfy { !$0.success })
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertTrue(fm.fileExists(atPath: replacement.path))
    }

    func testApplicationStartingAfterScanPreventsUninstall() async throws {
        let app = try makeApplication()
        let data = try write("Library/Preferences/\(identifier).plist")
        let results = await ApplicationCleaner(home: home).clean(try scan(app).items, operation: .uninstall, mode: .permanent, runningApps: { ["org.cleanmaster.TestExample"] })
        XCTAssertTrue(results.allSatisfy { !$0.success })
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertTrue(fm.fileExists(atPath: data.path))
    }

    func testNameOnlyDataIsNeverRecommendedAutomatically() throws {
        let app = try makeApplication()
        try write("Library/Application Support/TestExample/database")
        let item = try XCTUnwrap(try scan(app).items.first { $0.subtitle == ApplicationMatch.nameOnly.rawValue })
        guard case .applicationFile(_, let location, _) = item.action else { return XCTFail("Expected application data") }
        XCTAssertFalse(location.isRecommended)
    }

    func testSymlinkedDataCannotReachDesktopRepository() throws {
        let app = try makeApplication()
        let source = try write("Desktop/repository/source.swift")
        let support = home.appendingPathComponent("Library/Application Support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: support.appendingPathComponent(identifier), withDestinationURL: source.deletingLastPathComponent())
        let report = try scan(app)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertFalse(report.issues.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testRepositoriesInsideApplicationDataAreProtected() throws {
        let app = try makeApplication()
        try write("Library/Application Support/\(identifier)/project/.git/config")
        let source = try write("Library/Application Support/\(identifier)/project/source.swift")
        let item = try XCTUnwrap(try scan(app).items.first { $0.paths.first?.contains("Application Support") == true })
        XCTAssertFalse(item.canClean)
        let result = DiskCleaner(home: home).clean(item, mode: .permanent, runningApps: [])
        XCTAssertFalse(result.success)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testApplicationPolicyRejectsDesktopSystemAndEmbeddedApps() throws {
        let policy = ApplicationPolicy(home: home)
        XCTAssertThrowsError(try policy.validateApplicationPath(home.appendingPathComponent("Desktop/Example.app")))
        XCTAssertThrowsError(try policy.validateApplicationPath(URL(fileURLWithPath: "/System/Applications/Notes.app")))
        XCTAssertThrowsError(try policy.validateApplicationPath(home.appendingPathComponent("Applications/Parent.app/Helper.app")))
        XCTAssertFalse(ApplicationPolicy.validIdentifier("../../Desktop"))
        XCTAssertFalse(ApplicationPolicy.validIdentifier("."))
    }

    func testSharedVendorDirectoryIsNotSuggested() throws {
        let app = try makeApplication(name: "Google", id: "com.example.NotChrome")
        try write("Library/Application Support/Google/Chrome/profile")
        XCTAssertFalse(ApplicationPolicy(home: home).locations(for: app).contains { $0.url.lastPathComponent == "Google" })
    }
}
