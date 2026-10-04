import SwiftUI
import AppKit
import CleanMasterCore

@MainActor
final class ApplicationsModel: ObservableObject {
    @Published var inventory: ApplicationInventory?
    @Published var selection: String?
    @Published var report: ApplicationScan?
    @Published var selected = Set<String>()
    @Published var loading = false
    @Published var checking = false
    @Published var cleaning = false
    @Published var activity = ""
    @Published var operation: ApplicationOperation = .uninstall
    @Published var mode: CleanupMode = .trash
    @Published var error: String?
    private var scanWorker: Task<ApplicationScan, Error>?
    var busy: Bool { loading || checking || cleaning }
    var application: InstalledApplication? { inventory?.applications.first { $0.id == selection } }
    var items: [DiskItem] { report?.items ?? [] }
    var selectedItems: [DiskItem] { items.filter { selected.contains($0.id) && $0.canClean } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var hasOtherCopies: Bool {
        guard let application, let id = application.bundleID else { return false }
        return (inventory?.applications.filter { $0.bundleID == id }.count ?? 0) > 1
    }
    var hasBlockedData: Bool {
        !(report?.issues.isEmpty ?? true) || items.contains { item in
            guard case .applicationFile(_, let location, _) = item.action else { return false }
            return location.match != .application && location.isRecommended && !item.canClean
        }
    }
    var canProceed: Bool {
        guard !busy, !selectedItems.isEmpty else { return false }
        return operation == .dataOnly || (!hasBlockedData && selectedItems.contains { isApplication($0) })
    }

    func isApplication(_ item: DiskItem) -> Bool {
        if case .applicationFile(_, let location, _) = item.action { return location.match == .application }
        return false
    }
    func runningApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.flatMap { app in
            [app.bundleIdentifier, app.bundleURL.map { "path:" + $0.path }].compactMap { $0 }
        })
    }
    func refreshInventory() {
        guard !busy else { return }
        loading = true; error = nil; report = nil; selected.removeAll(); selection = nil
        Task {
            do { inventory = try await Task.detached(priority: .utility) { try ApplicationScanner().inventory() }.value }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
    func inspectSelection() {
        guard !busy, let application else { return }
        report = nil; selected.removeAll(); checking = true; error = nil
        let running = runningApps()
        let progress: @Sendable (String) -> Void = { [weak self] title in
            Task { @MainActor [weak self] in self?.activity = "正在检查 · " + title }
        }
        let worker = Task.detached(priority: .utility) { try ApplicationScanner().scan(application, runningApps: running, progress: progress) }
        scanWorker = worker
        Task {
            do { report = try await worker.value; chooseRecommended() }
            catch is CancellationError { activity = "检查已停止" }
            catch { self.error = error.localizedDescription }
            checking = false; scanWorker = nil
        }
    }
    func cancelScan() { scanWorker?.cancel() }
    func chooseRecommended() {
        selected = Set(items.filter { item in
            guard item.canClean, case .applicationFile(_, let location, _) = item.action else { return false }
            return location.isRecommended && (operation == .uninstall || location.match != .application)
        }.map(\.id))
    }
    func operationChanged() {
        for item in items where isApplication(item) {
            if operation == .uninstall && item.canClean { selected.insert(item.id) }
            else { selected.remove(item.id) }
        }
    }
    func toggle(_ item: DiskItem) {
        guard !busy, item.canClean, !isApplication(item) else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
    func clean(onFinished: @escaping @MainActor (CleanupRecord) -> Void) {
        guard canProceed else { return }
        let targets = selectedItems.sorted { $0.action.order < $1.action.order }
        let chosenMode = mode, total = selectedBytes, before = DiskSpace.read()?.available
        let chosenOperation = operation
        cleaning = true; error = nil
        Task { [self] in
            let progress: @Sendable (String) -> Void = { [weak self] title in
                Task { @MainActor [weak self] in self?.activity = "正在处理 · " + title }
            }
            let results = await ApplicationCleaner().clean(targets, operation: chosenOperation, mode: chosenMode,
                runningApps: { [self] in await runningApps() }, progress: progress)
            let after = DiskSpace.read()?.available
            let delta = before.flatMap { previous in after.map { $0 - previous } }
            let record = CleanupRecord(date: Date(), mode: chosenMode.rawValue, estimatedBytes: total, freeSpaceChange: delta, results: results)
            let appRemoved = results.contains { result in result.success && targets.contains { $0.id == result.id && isApplication($0) } }
            selected.removeAll(); cleaning = false
            onFinished(record)
            if appRemoved { refreshInventory() } else { inspectSelection() }
        }
    }
}
