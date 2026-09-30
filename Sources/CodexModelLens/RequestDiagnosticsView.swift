import SwiftUI
import ModelLensCore

private struct RequestGroup: Identifiable {
    let id: String
    let label: String
    let summary: RequestSummary
}

struct RequestDiagnosticsView: View {
    @Bindable var store: LensStore
    @Environment(\.dismiss) private var dismiss
    @State private var category = "全部"
    @State private var grouping = "请求记录"
    @State private var selection: String?
    @State private var useDates = false
    @State private var fromDate = Date().addingTimeInterval(-7 * 86400)
    @State private var toDate = Date()

    init(store: LensStore) {
        self.store = store
        let args = CommandLine.arguments
        if args.contains("--preview-path"), let i = args.firstIndex(of: "--preview-request-filter"), args.indices.contains(i + 1) {
            let initialCategory = args[i + 1]
            _category = State(initialValue: initialCategory)
            let first = store.archive.requestRecords.first {
                (initialCategory != "安全缓冲" || $0.isBuffering) && (initialCategory != "错误" || $0.isError)
            }
            _selection = State(initialValue: first?.id)
        }
    }

    private var records: [RequestRecord] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let begin = calendar.startOfDay(for: fromDate)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: toDate)) ?? toDate
        let titles = Dictionary(store.archive.threads.map { ($0.id, $0.title) }, uniquingKeysWith: { _, last in last })
        return store.archive.requestRecords.filter { r in
            if category == "安全缓冲" && !r.isBuffering { return false }
            if category == "错误" && !r.isError { return false }
            if useDates && (r.timestamp < begin || r.timestamp >= end) { return false }
            return store.requestSearch.isEmpty || [r.threadID ?? "", r.turnID ?? "", r.requestID ?? "",
                r.requestedModel ?? "", r.fasterModel ?? "", r.errorCode ?? "", titles[r.threadID ?? ""] ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(store.requestSearch) }
        }.sorted { $0.timestamp > $1.timestamp }
    }
    private var selected: RequestRecord? { records.first { $0.id == selection } }
    private var groups: [RequestGroup] {
        let grouped = Dictionary(grouping: records) { r in
            if grouping == "按日期" { return String(r.utcTimestamp.prefix(10)) }
            if grouping == "按任务" {
                return r.threadID ?? "未关联任务"
            }
            return r.requestedModel ?? "未记录请求模型"
        }
        return grouped.map { key, records in
            let title = grouping == "按任务" ? store.archive.threads.first { $0.id == key }?.conciseTitle : nil
            return RequestGroup(id: key, label: title.map { "\($0) · \(key.prefix(8))" } ?? key, summary: RequestSummary(records))
        }.sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("请求诊断").font(.title2.weight(.semibold))
                    Text("通信证据按请求保存 · 时间使用 UTC").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("导出当前结果") {
                    Button("JSON 证据…") { store.exportRequests(records, csv: false) }
                    Button("CSV 表格…") { store.exportRequests(records, csv: true) }
                }.disabled(records.isEmpty)
                Button("完成") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.cancelAction)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索任务、模型、请求 ID 或错误代码", text: $store.requestSearch).textFieldStyle(.plain)
                if !store.requestSearch.isEmpty {
                    Button { store.requestSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }
            }.padding(10).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
            HStack {
                Picker("筛选", selection: $category) {
                    ForEach(["全部", "安全缓冲", "错误"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 245)
                Spacer()
                Picker("视图", selection: $grouping) {
                    ForEach(["请求记录", "按模型", "按日期", "按任务"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 155)
                Toggle("日期范围", isOn: $useDates).toggleStyle(.checkbox)
            }
            if useDates {
                HStack {
                    DatePicker("从", selection: $fromDate, displayedComponents: .date)
                    DatePicker("至", selection: $toDate, displayedComponents: .date)
                    Spacer()
                    Text("包含起止日期 · UTC").font(.caption).foregroundStyle(.secondary)
                }.environment(\.timeZone, .gmt)
            }
            let summary = RequestSummary(records)
            HStack(spacing: 20) {
                stat("通信记录", summary.rows)
                stat("有 ID 的请求", summary.identifiedRequests)
                stat("安全缓冲", summary.bufferingRows)
                stat("容量文字", summary.capacityRows)
                stat("过载代码", summary.overloadedRows)
                stat("错误记录", summary.errorRows)
            }
            if summary.unidentifiedRows > 0 {
                Text("另有 \(summary.unidentifiedRows) 条记录缺少请求 ID，不能据此确定独立请求数。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Group {
                if records.isEmpty {
                    ContentUnavailableView("暂无匹配的通信记录", systemImage: "network",
                        description: Text("更改筛选条件，或等待 Codex 留存相关响应头与错误记录。"))
                } else if grouping == "请求记录" {
                    VStack(spacing: 0) {
                        requestColumns("时间 UTC", "请求模型", "状态", "缓冲 / 可重试模型", "请求 ID")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(10)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(records) { record in
                                    Button { selection = record.id } label: {
                                        HStack(spacing: 12) {
                                            Text(record.utcTimestamp.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: ""))
                                                .frame(width: 150, alignment: .leading)
                                            Text(record.requestedModel ?? "未记录").font(.caption.monospaced())
                                                .frame(width: 130, alignment: .leading)
                                            Text(record.statusLabel).foregroundStyle(record.isError ? .orange : .secondary)
                                                .frame(width: 100, alignment: .leading)
                                            Text(record.isBuffering ? (record.fasterModel ?? "已启用") : "—")
                                                .foregroundStyle(record.isBuffering ? .orange : .secondary)
                                                .frame(width: 150, alignment: .leading)
                                            Text(record.requestID ?? "未记录").font(.caption.monospaced())
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }.font(.caption).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 12)
                                            .contentShape(.rect)
                                            .background(selection == record.id ? Color.blue.opacity(0.16) : .clear, in: .rect(cornerRadius: 7))
                                    }.buttonStyle(.plain).help(record.requestID ?? record.statusLabel)
                                }
                            }.padding(5)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        groupColumns(grouping == "按日期" ? "日期 UTC" : grouping == "按任务" ? "任务" : "请求模型",
                                     ["记录", "有 ID 的请求", "安全缓冲", "容量文字", "过载代码", "错误"])
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(10)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(groups) { group in
                                    groupColumns(group.label, [group.summary.rows, group.summary.identifiedRequests,
                                        group.summary.bufferingRows, group.summary.capacityRows,
                                        group.summary.overloadedRows, group.summary.errorRows].map(String.init))
                                        .font(.caption).monospacedDigit().padding(10)
                                    Divider().opacity(0.4)
                                }
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let selected, grouping == "请求记录" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("请求 ID：\(selected.requestID ?? "未记录")").font(.caption.monospaced())
                            Spacer()
                            Button("复制证据") { store.copy(requestText(selected)) }.font(.caption)
                        }
                        Text("任务：\(selected.threadID ?? "未关联") · 轮次：\(selected.turnID ?? "未关联")").font(.caption2.monospaced())
                        ForEach(selected.headers.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(selected.headers[key] ?? "")").font(.caption2.monospaced())
                        }
                        Text("\(selected.source) · \(selected.locator)").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled)
                }.frame(maxHeight: 145).background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
            }
            if let coverage = store.archive.logCoverage {
                Text("本次可访问日志：\(utc(coverage.oldest)) — \(utc(coverage.newest)) · \(coverage.rowCount) 行；已归档证据可早于此范围。")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("统计排除聊天和工具正文；容量文字与过载代码可能同时出现在一条记录中。安全缓冲和可重试模型不代表已完成模型切换，HTTP 200 也不保证整个轮次成功。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 1000, height: 760)
            .onChange(of: store.requestSearch) { _, _ in selection = nil }
            .onChange(of: category) { _, _ in selection = nil }
    }
    private func requestColumns(_ date: String, _ model: String, _ status: String, _ buffering: String, _ request: String) -> some View {
        HStack(spacing: 12) {
            Text(date).frame(width: 150, alignment: .leading)
            Text(model).frame(width: 130, alignment: .leading)
            Text(status).frame(width: 100, alignment: .leading)
            Text(buffering).frame(width: 150, alignment: .leading)
            Text(request).frame(maxWidth: .infinity, alignment: .leading)
        }.lineLimit(1)
    }
    private func groupColumns(_ label: String, _ values: [String]) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            ForEach(values.indices, id: \.self) { index in
                Text(values[index]).frame(width: index == 1 ? 100 : 70, alignment: .trailing)
            }
        }
    }
    private func stat(_ label: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)").font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func utc(_ date: Date?) -> String {
        date.map { ISO8601DateFormatter().string(from: $0) } ?? "未知"
    }
    private func requestText(_ record: RequestRecord) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
