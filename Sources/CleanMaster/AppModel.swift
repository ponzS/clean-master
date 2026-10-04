import SwiftUI
import AppKit
import CleanMasterCore

@MainActor
final class AppModel: ObservableObject {
    @Published var report: ScanReport?
    @Published var space = DiskSpace.read()
    @Published var selected = Set<String>()
    @Published var scanning = false
    @Published var cleaning = false
    @Published var applicationBusy = false
    @Published var progress = 0.0
    @Published var activity = "准备好整理你的 Mac"
    @Published var mode: CleanupMode = .trash
    @Published var search = ""
    @Published var filter: String? = "all"
    @Published var error: String?
    @Published var lastRecord: CleanupRecord?
    @Published var history: [CleanupRecord] = []
    @Published var showResults = false
    private var scanWorker: Task<ScanReport, Error>?

    var busy: Bool { scanning || cleaning || applicationBusy }
    var items: [DiskItem] { report?.items ?? [] }
    var selectedItems: [DiskItem] { items.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var eligibleItems: [DiskItem] { items.filter { $0.canClean && (mode == .permanent || !$0.isManaged) } }
    var eligibleBytes: Int64 { eligibleItems.reduce(0) { $0 + $1.bytes } }
    var filteredItems: [DiskItem] {
        items.filter { item in
            (filter == nil || filter == "all" || item.group.rawValue == filter) &&
            (search.isEmpty || (item.title + item.subtitle + item.paths.joined()).localizedCaseInsensitiveContains(search))
        }
    }

    init() { loadHistory() }

    func canSelect(_ item: DiskItem) -> Bool { !busy && item.canClean && (mode == .permanent || !item.isManaged) }
    func toggle(_ item: DiskItem) {
        guard canSelect(item) else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
    func selectCaches() {
        selected = Set(filteredItems.filter { $0.risk == .regenerable && canSelect($0) }.map(\.id))
    }
    func modeChanged() {
        selected = Set(selectedItems.filter { $0.canClean && (mode == .permanent || !$0.isManaged) }.map(\.id))
    }
    private func runningApps() -> Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }

    func scan() {
        guard !busy else { return }
        scanning = true; progress = 0; activity = "正在检查可清理位置…"
        selected.removeAll(); error = nil
        let running = runningApps()
        let updateProgress: @Sendable (String, Double) -> Void = { [weak self] title, fraction in
            Task { @MainActor [weak self] in
                guard self?.scanning == true else { return }
                self?.activity = "正在扫描 · " + title; self?.progress = fraction
            }
        }
        let worker = Task.detached(priority: .utility) {
            try DiskScanner().scan(runningApps: running, progress: updateProgress)
        }
        scanWorker = worker
        Task {
            do {
                let result = try await worker.value
                report = result; activity = "已检查 \(result.scannedLocations) 类位置"
            } catch is CancellationError { activity = "扫描已停止，未修改任何文件" }
            catch { self.error = error.localizedDescription; activity = "扫描未完成" }
            scanning = false; scanWorker = nil; space = DiskSpace.read()
        }
    }

    func cancelScan() { scanWorker?.cancel(); activity = "正在停止扫描…" }

    func cleanSelection() {
        guard !busy, !selectedItems.isEmpty else { return }
        let targets = selectedItems.sorted { $0.action.order < $1.action.order }
        let selectedMode = mode, total = selectedBytes
        let before = DiskSpace.read()?.available
        cleaning = true; progress = 0; error = nil
        Task {
            var results: [CleanupResult] = []
            for (index, item) in targets.enumerated() {
                activity = "正在处理 · " + item.title
                progress = Double(index) / Double(targets.count)
                let running = runningApps()
                let result = await Task.detached(priority: .utility) {
                    DiskCleaner().clean(item, mode: selectedMode, runningApps: running)
                }.value
                results.append(result)
            }
            space = DiskSpace.read()
            let delta = before.flatMap { previous in space.map { $0.available - previous } }
            let record = CleanupRecord(date: Date(), mode: selectedMode.rawValue, estimatedBytes: total, freeSpaceChange: delta, results: results)
            storeRecord(record)
            let succeeded = Set(results.filter(\.success).map(\.id))
            report?.items.removeAll { succeeded.contains($0.id) }
            selected.removeAll(); cleaning = false; progress = 1
            activity = "已处理 \(results.filter(\.success).count)/\(targets.count) 项"
            showResults = true
            // A grouped operation can partly succeed; refresh rather than retain stale estimates.
            scan()
        }
    }

    func acceptApplicationRecord(_ record: CleanupRecord) {
        storeRecord(record)
        report = nil; selected.removeAll(); space = DiskSpace.read(); showResults = true
    }
    private func storeRecord(_ record: CleanupRecord) {
        lastRecord = record; history.insert(record, at: 0); history = Array(history.prefix(20)); saveHistory()
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }

    private var historyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/clean-master/history.json")
    }
    private func loadHistory() {
        if let data = try? Data(contentsOf: historyURL), let records = try? JSONDecoder().decode([CleanupRecord].self, from: data) { history = Array(records.prefix(20)) }
    }
    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
        } catch { self.error = "清理结果已显示，但记录未能保存：" + error.localizedDescription }
    }
}
