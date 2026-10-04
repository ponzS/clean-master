import SwiftUI
import CleanMasterCore

private let mint = Color(red: 0.12, green: 0.62, blue: 0.47)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var detail: DiskItem?
    @State private var confirm = false
    @State private var scope = false
    @State private var issues = false
    @State private var history = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 28, weight: .medium)).foregroundStyle(mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("clean-master").font(.system(size: 17, weight: .semibold))
                        Text("给磁盘留点空间").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 26)
                List(selection: $model.filter) {
                    Label("全部项目", systemImage: "square.grid.2x2").tag("all")
                    Section("清理分类") {
                        ForEach(ItemGroup.allCases) { group in
                            Label(group.rawValue, systemImage: group.symbol).tag(group.rawValue)
                        }
                    }
                }.listStyle(.sidebar).disabled(model.busy)
                VStack(alignment: .leading, spacing: 14) {
                    Button { history = true } label: { Label("清理记录", systemImage: "clock.arrow.circlepath") }.buttonStyle(.plain)
                    Button { scope = true } label: { Label("扫描范围", systemImage: "slider.horizontal.3") }.buttonStyle(.plain)
                    Divider()
                    Label("本机处理 · 无需联网", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    Text("不扫描桌面和个人文档").font(.caption2).foregroundStyle(.tertiary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 260)
        } detail: {
            if model.filter == ItemGroup.applications.rawValue {
                ApplicationsView(shared: model)
            } else {
            VStack(spacing: 0) {
                overview.padding(24)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12)
                }
                if model.scanning || model.cleaning {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.activity).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            if model.scanning { Button("停止") { model.cancelScan() }.buttonStyle(.borderless) }
                        }
                        ProgressView(value: model.progress).tint(mint)
                    }.padding(.horizontal, 24).padding(.bottom, 18)
                }
                Divider()
                results
                Divider()
                footer
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("磁盘清理")
            .toolbar {
                ToolbarItem {
                    Button { model.scan() } label: { Label(model.report == nil ? "扫描" : "重新扫描", systemImage: "arrow.clockwise") }
                        .disabled(model.busy).keyboardShortcut("r")
                }
            }
            .searchable(text: $model.search, prompt: "筛选项目")
            }
        }
        .onChange(of: model.mode) { _, _ in model.modeChanged() }
        .sheet(item: $detail) { item in ItemDetail(item: item, reveal: model.reveal) }
        .sheet(isPresented: $confirm) { ConfirmationSheet(items: model.selectedItems, bytes: model.selectedBytes, mode: model.mode) {
            confirm = false; model.cleanSelection()
        } }
        .sheet(isPresented: $scope) { ScopeSheet() }
        .sheet(isPresented: $issues) { IssuesSheet(issues: model.report?.issues ?? [], openSettings: model.openPrivacySettings) }
        .sheet(isPresented: $history) { HistorySheet(records: model.history) }
        .sheet(isPresented: $model.showResults) {
            if let record = model.lastRecord { ResultsSheet(record: record, openTrash: model.openTrash) }
        }
    }

    private var overview: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle().stroke(mint.opacity(0.12), lineWidth: 9)
                Circle().trim(from: 0, to: usedFraction).stroke(mint, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "internaldrive").font(.system(size: 26, weight: .light)).foregroundStyle(mint)
            }.frame(width: 78, height: 78).accessibilityLabel("磁盘使用比例 \(Int(usedFraction * 100))%")
            VStack(alignment: .leading, spacing: 6) {
                Text("Macintosh HD").font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(model.space.map { byteString($0.available) } ?? "—").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("可用").foregroundStyle(.secondary)
                }
                Text(model.space.map { "共 \(byteString($0.total)) · 已用 \(byteString($0.used))" } ?? "无法读取磁盘容量")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if model.report != nil {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("可选择项目占用").font(.caption).foregroundStyle(.secondary)
                    Text(byteString(model.eligibleBytes)).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("\(model.eligibleItems.count) 项 · 不自动勾选").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usedFraction: Double {
        guard let space = model.space, space.total > 0 else { return 0 }
        return min(1, max(0, Double(space.used) / Double(space.total)))
    }

    @ViewBuilder private var results: some View {
        if model.report == nil {
            VStack(spacing: 18) {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(mint)
                Text(model.scanning ? "正在寻找可以整理的空间" : "清楚地看到，再决定清理").font(.title2.weight(.medium))
                Text("检查应用缓存、开发数据、模拟器和动态壁纸。\n扫描只读取文件，清理由你决定。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                if !model.scanning {
                    Button("扫描可清理项目") { model.scan() }.buttonStyle(.borderedProminent).tint(mint).controlSize(.large)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text(model.filter == "all" || model.filter == nil ? "扫描结果" : model.filter!).font(.headline)
                    Text("\(model.filteredItems.count) 项").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !(model.report?.issues.isEmpty ?? true) {
                        Button { issues = true } label: { Label("\(model.report?.issues.count ?? 0) 个位置未能扫描", systemImage: "exclamationmark.circle") }
                            .buttonStyle(.borderless).font(.caption).foregroundStyle(.orange)
                    }
                    Menu {
                        Button("选择当前列表的可再生成缓存") { model.selectCaches() }
                        Button("选择当前列表可处理的项目") { model.selected.formUnion(model.filteredItems.filter { model.canSelect($0) }.map(\.id)) }
                        Button("取消全部选择") { model.selected.removeAll() }
                    } label: { Image(systemName: "checklist") }.menuStyle(.borderlessButton).frame(width: 28).disabled(model.busy)
                }.padding(.horizontal, 24).padding(.vertical, 14)
                if model.filteredItems.isEmpty {
                    ContentUnavailableView(model.search.isEmpty ? "这里已经很清爽" : "没有匹配项目",
                                           systemImage: model.search.isEmpty ? "checkmark.circle" : "magnifyingglass",
                                           description: Text(model.search.isEmpty ? "本次扫描未在此分类发现可清理文件。" : "试试其他名称或路径。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.filteredItems) { item in
                        itemRow(item).listRowSeparator(.visible).listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24))
                    }.listStyle(.plain)
                }
                HStack {
                    Text("占用为预估值；共享文件、APFS 快照与缓存重建会影响实际释放量。").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 24).padding(.vertical, 9)
            }
        }
    }

    private func itemRow(_ item: DiskItem) -> some View {
        HStack(spacing: 14) {
            Toggle(item.title, isOn: Binding(get: { model.selected.contains(item.id) }, set: { _ in model.toggle(item) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(!model.canSelect(item))
            Image(systemName: item.group.symbol).font(.system(size: 20)).foregroundStyle(item.risk == .regenerable ? mint : Color.secondary)
                .frame(width: 32, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.issue ?? (item.isManaged && model.mode == .trash ? "选择“永久删除”后可通过 Xcode 移除" : item.subtitle))
                    .font(.caption).foregroundStyle(item.issue == nil ? Color.secondary : .orange).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.risk.rawValue).font(.caption2).foregroundStyle(item.risk == .regenerable ? mint : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4).background((item.risk == .regenerable ? mint : Color.secondary).opacity(0.08), in: Capsule())
            Text(byteString(item.bytes)).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit().frame(width: 84, alignment: .trailing)
            Button { detail = item } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("查看路径和清理影响").accessibilityLabel("查看 \(item.title) 的详情")
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("查看详情") { detail = item }
            if let path = item.paths.first { Button("在 Finder 中显示") { model.reveal(path) } }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("已选 \(model.selected.count) 项 · \(byteString(model.selectedBytes))").font(.callout.weight(.medium)).monospacedDigit()
                Text(model.mode == .trash ? "移到废纸篓后，需自行清空才会释放空间。" : "永久删除无法撤销，下一步会列出所选项目供你确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("清理方式", selection: $model.mode) {
                ForEach(CleanupMode.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 138).disabled(model.busy)
            Button("检查并清理…") { confirm = true }
                .buttonStyle(.borderedProminent).tint(mint).controlSize(.large)
                .disabled(model.busy || model.selected.isEmpty)
        }.padding(20)
    }
}
