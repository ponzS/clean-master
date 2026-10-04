import SwiftUI
import CleanMasterCore

private struct SheetHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ItemDetail: View {
    let item: DiskItem
    let reveal: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: item.title, subtitle: "\(item.group.rawValue) · \(byteString(item.bytes)) · \(item.fileCount) 个文件")
            Label(item.risk.rawValue, systemImage: item.risk == .regenerable ? "arrow.triangle.2.circlepath" : "info.circle").foregroundStyle(.secondary)
            Text(item.impact).lineSpacing(4)
            if let issue = item.issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Divider()
            Text("位置").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(item.paths, id: \.self) { path in
                        HStack(alignment: .top) {
                            Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Button { reveal(path) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                        }
                    }
                }
            }.frame(maxHeight: 210)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 540)
    }
}

struct ConfirmationSheet: View {
    let items: [DiskItem]
    let bytes: Int64
    let mode: CleanupMode
    var context: String? = nil
    let proceed: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let context { Text(context).font(.headline).foregroundStyle(.secondary) }
            SheetHeader(title: mode == .trash ? "将这 \(items.count) 项移到废纸篓？" : "永久删除这 \(items.count) 项？",
                        subtitle: mode == .trash ? "占用约 \(byteString(bytes))。可以从废纸篓恢复；清空废纸篓后才会释放空间。" : "占用约 \(byteString(bytes))。此操作无法撤销，请确认下面的项目不再需要。")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(item.title).fontWeight(.medium); Spacer(); Text(byteString(item.bytes)).foregroundStyle(.secondary) }
                            if item.risk != .regenerable { Text(item.impact).font(.caption).foregroundStyle(.secondary) }
                            if let path = item.paths.first { Text(path).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Divider()
                    }
                }
            }.frame(maxHeight: 320)
            Text("已识别的关联应用运行时会跳过对应项目；操作前再次检查路径和文件身份。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .trash ? "移到废纸篓" : "永久删除", role: mode == .permanent ? .destructive : nil) { proceed() }
                    .buttonStyle(.borderedProminent).tint(mode == .permanent ? .red : .accentColor)
            }
        }.padding(26).frame(width: 580)
    }
}

struct ScopeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "只扫描明确的清理范围", subtitle: "本地规则扫描，无需账号、网络或 AI。默认不扫描桌面、文稿、照片、钥匙串、数据库、工具链和聊天记录。")
            Label("不跟随符号链接，不跨磁盘，不处理包含 .git 的目录。", systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Catalog.rules, id: \.id) { rule in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name).font(.callout.weight(.medium))
                            Text("~/" + rule.relativePath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Divider()
                    Text("iOS 模拟器及系统组件通过 Xcode 工具识别和移除，不直接删除系统资源目录。")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 310)
            Text("应用模块扫描 /Applications 和 ~/Applications。按标识符、已知路径关联数据；仅名称匹配需要手动选择，不处理共享容器和钥匙串。清理记录最多保留 20 次，存于本机。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 600)
    }
}

struct IssuesSheet: View {
    let issues: [ScanIssue]
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "部分位置未能扫描", subtitle: "这些位置没有被计为已清理。权限不足时，可以在系统设置中为 clean-master 开启“完全磁盘访问权限”，再重新扫描。")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(issue.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: 340)
            HStack { Button("打开隐私设置") { openSettings() }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 590)
    }
}

struct ResultsSheet: View {
    let record: CleanupRecord
    let openTrash: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "已处理 \(record.results.filter(\.success).count)/\(record.results.count) 项",
                        subtitle: record.results.allSatisfy { !$0.success } ? "本次没有成功处理的项目，请查看下方原因。" : (record.mode == CleanupMode.trash.rawValue ? "成功项目已移到废纸篓，清空后才会释放磁盘空间。" : "处理结果如下。后台进程、共享文件和系统回收时机会影响磁盘空间变化。"))
            if record.mode == CleanupMode.permanent.rawValue, let delta = record.freeSpaceChange {
                LabeledContent("本次观察到的可用空间变化", value: (delta < 0 ? "−" : "+") + byteString(abs(delta))).font(.headline)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(record.results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(result.success ? .green : .orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).font(.callout.weight(.medium))
                                Text(result.message).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }.frame(maxHeight: 310)
            HStack {
                if record.mode == CleanupMode.trash.rawValue { Button("打开废纸篓") { openTrash() } }
                Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 580)
    }
}

struct HistorySheet: View {
    let records: [CleanupRecord]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "清理记录", subtitle: "最近 20 次记录，仅保存在这台 Mac 上。")
            if records.isEmpty {
                ContentUnavailableView("还没有清理记录", systemImage: "clock", description: Text("完成第一次清理后，会在这里留下记录。"))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(records) { record in
                            DisclosureGroup {
                                ForEach(record.results) { result in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(result.title, systemImage: result.success ? "checkmark.circle" : "exclamationmark.circle")
                                        Text(result.message).font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 4)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).fontWeight(.medium)
                                    Text("\(record.mode) · \(record.results.filter(\.success).count)/\(record.results.count) 项 · 预估 \(byteString(record.estimatedBytes))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                        }
                    }
                }.frame(height: 310)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(26).frame(width: 580)
    }
}
