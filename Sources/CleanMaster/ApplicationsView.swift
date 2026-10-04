import SwiftUI
import AppKit
import CleanMasterCore

struct ApplicationsView: View {
    @ObservedObject var shared: AppModel
    @StateObject private var model = ApplicationsModel()
    @State private var detail: DiskItem?
    @State private var confirm = false
    @State private var showIssues = false

    private var applications: [InstalledApplication] {
        (model.inventory?.applications ?? []).filter {
            shared.search.isEmpty || ($0.name + ($0.bundleID ?? "")).localizedCaseInsensitiveContains(shared.search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("应用卸载与数据").font(.title2.weight(.semibold))
                    Text("卸载时处理应用与所选数据；只清数据时保留应用。").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button { model.refreshInventory() } label: { Label("刷新应用", systemImage: "arrow.clockwise") }.disabled(model.busy)
            }.padding(24)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            HStack(spacing: 0) {
                appList.frame(width: 228)
                Divider()
                appDetails.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            footer
        }
        .navigationTitle("应用管理")
        .searchable(text: $shared.search, prompt: "搜索应用")
        .task { if model.inventory == nil { model.refreshInventory() } }
        .onChange(of: model.selection) { _, _ in model.inspectSelection() }
        .onChange(of: model.operation) { _, _ in model.operationChanged() }
        .onChange(of: model.busy) { _, value in shared.applicationBusy = value }
        .sheet(item: $detail) { ItemDetail(item: $0, reveal: shared.reveal) }
        .sheet(isPresented: $showIssues) {
            IssuesSheet(issues: (model.inventory?.issues ?? []) + (model.report?.issues ?? []), openSettings: shared.openPrivacySettings)
        }
        .sheet(isPresented: $confirm) {
            ConfirmationSheet(items: model.selectedItems, bytes: model.selectedBytes, mode: model.mode,
                context: model.operation == .uninstall ? "卸载 \(model.application?.name ?? "应用") 与所选数据" : "仅清理 \(model.application?.name ?? "应用") 的数据，保留应用本体") {
                confirm = false
                model.clean { shared.acceptApplicationRecord($0) }
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("已安装应用").font(.caption.weight(.medium))
                Spacer(); Text("\(applications.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(14)
            if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(applications, selection: $model.selection) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.callout).lineLimit(1)
                            Text(app.version.isEmpty ? "未标注版本" : app.version).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4).tag(app.id)
                }.listStyle(.plain).frame(minHeight: 0, maxHeight: .infinity).disabled(model.busy)
            }
            Text("仅列出应用程序文件夹中的应用，保护系统内置应用和 clean-master。").font(.caption2).foregroundStyle(.secondary).padding(14)
        }
    }

    @ViewBuilder private var appDetails: some View {
        if let application = model.application {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path)).resizable().frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(application.name).font(.headline)
                            Text(application.bundleID ?? application.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button { model.inspectSelection() } label: { Image(systemName: "arrow.clockwise") }.help("重新检查应用与数据").disabled(model.busy)
                    }
                    Picker("操作", selection: $model.operation) {
                        ForEach(ApplicationOperation.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).disabled(model.busy)
                    Text(model.operation == .uninstall ? "应用本体将一并移除。未勾选的数据会保留。" : "应用本体会保留，所选设置、登录状态或本地内容可能丢失。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(18)
                if model.checking || model.cleaning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(model.activity).font(.caption).lineLimit(1)
                        Spacer()
                        if model.checking { Button("停止") { model.cancelScan() }.buttonStyle(.borderless) }
                    }.padding(.horizontal, 18).padding(.bottom, 12)
                }
                if model.hasBlockedData {
                    Text("部分关联数据未能读取或已受保护。请解决后再卸载；也可以只处理可读取的数据。")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 18).padding(.bottom, 10)
                }
                if model.hasOtherCopies {
                    Text("检测到此应用的其他安装副本，清理关联数据也会影响这些副本。")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 18).padding(.bottom, 10)
                }
                if let report = model.report {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(report.items) { item in
                                componentRow(item).padding(.horizontal, 16).padding(.vertical, 4)
                                Divider().padding(.leading, 42)
                            }
                        }
                    }.frame(minHeight: 0, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
                } else {
                    Spacer()
                    if !model.checking { Button("检查应用与数据") { model.inspectSelection() }.frame(maxWidth: .infinity) }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    if !(model.report?.issues.isEmpty ?? true) || !(model.inventory?.issues.isEmpty ?? true) {
                        Button("查看未能读取的位置") { showIssues = true }.buttonStyle(.borderless)
                    }
                    Text("按应用标识符和已知路径关联数据；仅名称匹配的目录默认不选。共享容器、钥匙串、系统服务和桌面项目不在范围内。")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(14)
            }
        } else {
            ContentUnavailableView("选择一个应用", systemImage: "app.dashed", description: Text("查看应用本体和对应数据，\n再决定卸载或只清理数据。"))
        }
    }

    private func componentRow(_ item: DiskItem) -> some View {
        let isApp = model.isApplication(item)
        return HStack(alignment: .top, spacing: 10) {
            Toggle(item.title, isOn: Binding(get: { model.selected.contains(item.id) }, set: { _ in model.toggle(item) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(isApp || model.busy || !item.canClean)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(componentTitle(item)).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(byteString(item.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(item.issue ?? (isApp && model.operation == .dataOnly ? "保留应用本体" : item.subtitle))
                    .font(.caption2).foregroundStyle(item.issue == nil ? Color.secondary : .orange)
                if let path = item.paths.first { Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
            }
            Button { detail = item } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless).help("查看数据路径和影响")
        }.padding(.vertical, 7).accessibilityElement(children: .contain)
    }

    private func componentTitle(_ item: DiskItem) -> String {
        if case .applicationFile(_, let location, _) = item.action { return location.title }
        return item.title
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("已选 \(model.selectedItems.count) 项 · \(byteString(model.selectedBytes))").font(.callout.weight(.medium))
                Text(model.mode == .trash ? "移到废纸篓后，需自行清空才会释放空间。" : "永久删除无法撤销，下一步确认具体项目。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("处理方式", selection: $model.mode) { ForEach(CleanupMode.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().frame(width: 138).disabled(model.busy)
            Button(model.operation == .uninstall ? "卸载并清理…" : "仅清理数据…") { confirm = true }
                .buttonStyle(.borderedProminent).tint(Color(red: 0.12, green: 0.62, blue: 0.47)).controlSize(.large).disabled(!model.canProceed)
        }.padding(20)
    }
}
