import SwiftUI
import ModelLensCore

struct ContentView: View {
    @Bindable var store: LensStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } content: {
            taskList
                .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 480)
        } detail: {
            if let thread = store.selectedThread {
                TaskDetailView(thread: thread, store: store)
                    .id(thread.id)
            } else {
                ContentUnavailableView("选择一个任务", systemImage: "viewfinder",
                                       description: Text("查看轮次模型、路由变化与检测证据。"))
            }
        }
        .navigationTitle("Codex Model Lens")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.monitoring.toggle()
                    if store.monitoring { Task { await store.refresh() } }
                } label: {
                    Label(store.monitoring ? "暂停监测" : "恢复监测", systemImage: store.monitoring ? "pause" : "play")
                }
                .help(store.monitoring ? "暂停自动检测" : "恢复自动检测")
                Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(store.isScanning)
                    .keyboardShortcut("r", modifiers: .command)
                Menu {
                    Button("独立模型核验…") { store.showingProbe = true }
                    Divider()
                    Button("导出 JSON 历史…") { store.export(csv: false) }
                    Button("导出 CSV 表格…") { store.export(csv: true) }
                    Button("请求诊断与证据导出…") { store.showRequestDiagnostics() }
                    Divider()
                    Button("导入模型证据…") { store.importEvidence() }
                    Button("在 Finder 中显示历史") { store.revealHistory() }
                    Divider()
                    Button("检测设置…") { store.showingSettings = true }
                } label: { Label("更多", systemImage: "ellipsis") }
            }
        }
        .sheet(isPresented: $store.showingSettings) { SettingsView(store: store) }
        .sheet(isPresented: $store.showingDiagnostics) { DiagnosticsView(store: store) }
        .sheet(isPresented: $store.showingProbe) { ModelProbeView(store: store) }
        .sheet(isPresented: $store.showingRequests) { RequestDiagnosticsView(store: store) }
        .alert("检测提示", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("好") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
        .task {
            if CommandLine.arguments.contains("--preview-path") { FileHandle.standardError.write(Data("Preview: content appeared.\n".utf8)) }
            store.start()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 46, height: 46)
                    .glassEffect(.regular.tint(.blue.opacity(0.08)), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Model Lens").font(.headline)
                    Text("让模型记录可追溯").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 25)

            List {
                Section("工作空间") {
                    ForEach(TaskFilter.allCases) { filter in
                        Button { store.filter = filter } label: {
                            HStack {
                                Label(filter.title, systemImage: filter.icon)
                                Spacer()
                                if filter == .running { countLabel(store.runningCount) }
                                if filter == .differences && store.differenceCount > 0 { countLabel(store.differenceCount) }
                                if filter == .buffering { countLabel(store.bufferingThreadIDs.count) }
                            }.padding(.vertical, 4).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(store.filter == filter ? Color.blue.opacity(0.12) : Color.clear)
                        .accessibilityAddTraits(store.filter == filter ? [.isSelected] : [])
                    }
                }
                Section("证据状态") {
                    Label("\(store.evidenceCount) 条服务端记录", systemImage: "doc.text.magnifyingglass")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { store.showingProbe = true } label: {
                        Label("独立核验 · \(store.probeReports.filter(\.isConfirmed).count) 条已确认", systemImage: "checkmark.shield")
                            .font(.caption)
                    }.buttonStyle(.plain)
                    Button { store.showingDiagnostics = true } label: {
                        Label(store.latestScan.diagnostics.isEmpty ? "查看检测范围" : "\(store.latestScan.diagnostics.count) 项读取提示",
                              systemImage: store.latestScan.diagnostics.isEmpty ? "info.circle" : "exclamationmark.circle")
                            .font(.caption)
                    }.buttonStyle(.plain)
                    Button { store.showRequestDiagnostics() } label: {
                        Label("请求诊断 · \(store.archive.requestRecords.count) 条", systemImage: "network")
                            .font(.caption)
                    }.buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(store.monitoring ? .blue : .secondary).frame(width: 6, height: 6)
                    Text(store.isScanning ? "正在读取记录…" : store.monitoring ? "自动监测 · \(Int(store.settings.refreshSeconds)) 秒" : "监测已暂停")
                        .font(.caption)
                }
                Text("未公开的内部路由无法在本机独立验证。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("macOS 原生 · 本地保存").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button { store.showingSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("设置")
                }
            }
            .padding(16)
        }
        .onChange(of: store.filter) { _, _ in store.selection = store.visibleThreads.first?.id }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.filter.title).font(.system(size: 25, weight: .semibold))
                    Spacer()
                    Text("\(store.visibleThreads.count) 个任务").font(.caption).foregroundStyle(.secondary)
                }
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        metric(value: "\(store.runningCount)", title: "运行中", symbol: "waveform", color: .blue)
                        metric(value: "\(store.differenceCount)", title: "模型变化", symbol: "arrow.triangle.branch", color: .orange)
                    }
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索任务或模型", text: $store.search).textFieldStyle(.plain)
                    if !store.search.isEmpty {
                        Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(9).background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 9))
            }
            .padding(20)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Group {
                if store.visibleThreads.isEmpty {
                    ContentUnavailableView(store.isScanning ? "正在读取任务" : "暂无匹配任务", systemImage: store.isScanning ? "arrow.trianglehead.2.clockwise" : "moon.zzz",
                        description: Text(store.filter == .running ? "启动 Codex 中的任务后，记录会自动显示。活动待确认的任务也会保留在这里。" : "试试其他视图或清除搜索条件。"))
                } else {
                    List(selection: $store.selection) {
                        ForEach(store.visibleThreads) { thread in
                            TaskRow(thread: thread, hasBuffering: store.bufferingThreadIDs.contains(thread.id))
                                .tag(thread.id)
                                .padding(.vertical, 7)
                                .contextMenu {
                                    Button("移除本地检测记录", role: .destructive) { store.removeLocalTask(thread.id) }
                                        .disabled(store.isScanning)
                                }
                        }
                    }.listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = store.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.07))
            }
            HStack {
                Text(store.latestScan.scannedAt, style: .time)
                Text("· \(String(format: "%.1f", store.latestScan.duration)) 秒")
                Spacer()
                Image(systemName: "lock").help("只读检测 Codex 记录")
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: store.search) { _, _ in
            if !store.visibleThreads.contains(where: { $0.id == store.selection }) { store.selection = store.visibleThreads.first?.id }
        }
    }

    private func countLabel(_ count: Int) -> some View {
        Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
    private func metric(value: String, title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 13))
    }
}

struct TaskRow: View {
    let thread: ThreadRecord
    var hasBuffering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(thread.isRunning ? .blue : thread.isUnconfirmed ? .orange : .gray.opacity(0.5))
                    .frame(width: 6, height: 6).padding(.top, 6)
                Text(thread.conciseTitle).font(.system(size: 13, weight: .medium)).lineLimit(2).help(thread.title)
                Spacer(minLength: 0)
                if thread.hasModelDifference { Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange) }
            }
            Text(thread.displayModel).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                .foregroundStyle(thread.latestTurn?.reportedModel == nil ? .secondary : .primary)
            HStack(spacing: 6) {
                Text(thread.statusLabel)
                if thread.parentID != nil { Text("· 子任务") }
                if thread.archived { Text("· 已归档") }
                if hasBuffering { Image(systemName: "hourglass").foregroundStyle(.orange).help("有安全缓冲记录") }
                Spacer(minLength: 0)
                Text(thread.updatedAt, format: .dateTime.month().day())
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
