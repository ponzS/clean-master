import SwiftUI
import AppKit
import CleanMasterCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CleanMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--scan-json") {
            do {
                let report = try DiskScanner().scan()
                let data = try JSONSerialization.data(withJSONObject: [
                    "items": report.items.map { ["name": $0.title, "bytes": $0.bytes, "paths": $0.paths, "selectable": $0.canClean] as [String: Any] },
                    "issues": report.issues.map { ["path": $0.path, "message": $0.message] },
                    "totalBytes": report.totalBytes
                ], options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data); exit(0)
            } catch { FileHandle.standardError.write(Data(error.localizedDescription.utf8)); exit(1) }
        }
    }

    var body: some Scene {
        WindowGroup("clean-master") {
            GeometryReader { geometry in
                ContentView(model: model)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .tint(Color.accentColor)
            }.frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1080, height: 760)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("清理") {
                Button("扫描可清理项目") { model.scan() }.keyboardShortcut("r").disabled(model.busy || model.filter == ItemGroup.applications.rawValue)
                Button("停止扫描") { model.cancelScan() }.disabled(!model.scanning)
                Divider()
                Button("选择可再生成的缓存") { model.selectCaches() }.disabled(model.busy || model.report == nil || model.filter == ItemGroup.applications.rawValue)
                Button("取消全部选择") { model.selected.removeAll() }.disabled(model.busy)
            }
        }
    }
}
