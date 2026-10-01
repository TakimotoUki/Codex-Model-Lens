import SwiftUI
import AppKit
import ModelLensCore

enum MenuPage: String, CaseIterable { case usage = "用量", timer = "番茄钟" }
struct MenuBarView: View {
    @Bindable var store: LensStore
    let delegate: LensAppDelegate
    @State private var usageHeight: CGFloat = 300
    @State private var page: MenuPage = CommandLine.arguments.contains("--preview-timer") ? .timer : .usage
    private var hub: UsageHub { store.usage }
    private var tasks: [ThreadRecord] {
        store.archive.threads.filter { $0.isRunning && (store.settings.showInternal || !$0.isInternal) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Model Lens", systemImage: "viewfinder").font(.headline)
                Spacer()
                if page == .usage {
                    if !hub.loading.isEmpty || store.isScanning { ProgressView().controlSize(.mini) }
                    Button {
                        Task { await store.refresh() }
                        hub.refreshAll(codexHome: URL(fileURLWithPath: store.settings.codexHome))
                    } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("刷新任务、所有已启用平台用量和服务状态")
                }
            }.padding(16)
            Picker("功能", selection: $page) {
                ForEach(MenuPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 14)
            Divider()
            if page == .timer { PomodoroView(controller: store.pomodoro).padding(18) }
            else {
                ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if hub.enabledProviders.isEmpty {
                        Text("在设置中开启需要显示的平台。").font(.callout).foregroundStyle(.secondary)
                    } else {
                        providerPicker
                        accountPicker
                        if hub.provider == .codex {
                            runningTasks
                        }
                        UsageSnapshotView(snapshot: hub.current, loading: hub.loading.contains(hub.currentID), error: hub.errors[hub.currentID])
                        ProviderStatusView(provider: hub.provider, status: hub.serviceStatuses[hub.provider])
                    }
                }.padding(16).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { usageHeight = $0 }
                }.frame(height: min(usageHeight, delegate.maximumMenuBodyHeight))
            }
            Divider()
            HStack {
                Button("打开主界面") { delegate.showMainWindow() }.buttonStyle(.glass)
                Spacer()
                Menu {
                    Button("用量概览…") { delegate.showUtility(.dashboard) }
                    Button("添加账户…") { delegate.showUtility(.account) }
                    Divider()
                    Button("独立模型核验…") { delegate.showMainWindow(); store.showingProbe = true }
                    Button("设置…") { delegate.showUtility(.settings) }
                    Button("关于 Model Lens…") { delegate.showUtility(.about) }
                    Divider(); Button("退出") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(13)
        }.frame(width: 390).fixedSize(horizontal: false, vertical: true).tint(.blue)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in delegate.resizePopover(height: size.height) }
        .onAppear { if page == .usage { refresh() } }
        .onChange(of: page) { _, value in if value == .usage { refresh() } }
        .onChange(of: hub.provider) { _, _ in refresh() }
        .onChange(of: hub.currentID) { _, _ in refresh() }
    }
    private var providerPicker: some View {
        HStack(spacing: 5) {
            ForEach(hub.enabledProviders) { provider in
                Button { hub.provider = provider } label: {
                    ProviderIcon(provider: provider).frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(hub.provider == provider ? Color.blue : .secondary)
                        .background(hub.provider == provider ? Color.blue.opacity(0.12) : .clear, in: .rect(cornerRadius: 9))
                }.buttonStyle(.plain).help(provider.title).accessibilityLabel(provider.title)
            }
        }
    }
    @ViewBuilder private var accountPicker: some View {
        let accounts = hub.preferences.accounts.filter { $0.provider == hub.provider }
        HStack {
            Text(hub.provider.title).font(.title3.weight(.semibold))
            Spacer()
            if !accounts.isEmpty {
                Picker("账户", selection: Binding(get: { hub.currentID }, set: { hub.select($0.hasPrefix("local-") ? nil : $0, for: hub.provider) })) {
                    Text("本机登录").tag("local-" + hub.provider.rawValue)
                    ForEach(accounts) { Text($0.label).tag($0.id) }
                }.labelsHidden().fixedSize()
            } else { Text("本机账户").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var runningTasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("正在运行").font(.caption.weight(.semibold)); Spacer(); Text("\(tasks.count)").foregroundStyle(.secondary).font(.caption.monospacedDigit()) }
            if tasks.isEmpty { Text(store.isScanning ? "正在读取任务…" : "当前没有运行任务").font(.caption).foregroundStyle(.secondary) }
            if !tasks.isEmpty {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(tasks.prefix(8)) { thread in
                            Button {
                                store.selection = thread.id; store.filter = .running; delegate.showMainWindow()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(thread.conciseTitle).font(.caption.weight(.medium)).lineLimit(1)
                                    let active = thread.turns.filter { $0.status == .running }
                                    if !active.isEmpty, active.allSatisfy({ $0.reportedModel != nil }) {
                                        Label(Array(Set(active.compactMap(\.reportedModel))).sorted().joined(separator: "、"), systemImage: "checkmark.circle.fill").foregroundStyle(.blue).font(.caption)
                                        Text("服务端报告").font(.caption2).foregroundStyle(.secondary)
                                    } else {
                                        HStack { Text("模型未确认").foregroundStyle(.orange); Spacer(); Text("请求 \(thread.latestTurn?.recordedModel ?? thread.selectedModel ?? "未知")").foregroundStyle(.secondary).lineLimit(1) }.font(.caption)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: min(CGFloat(tasks.count) * 74, 185))
            }
            Divider()
        }
    }
    private func refresh(force: Bool = false) {
        guard !CommandLine.arguments.contains("--preview-path") else { return }
        hub.refresh(codexHome: URL(fileURLWithPath: store.settings.codexHome), force: force)
    }
}

struct UsageSnapshotView: View {
    let snapshot: UsageSnapshot?
    var loading = false
    var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let snapshot {
                if let plan = snapshot.plan { Text(plan).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                ForEach(snapshot.meters.prefix(6)) { meter in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(meter.title); Spacer(); Text(meter.remainingPercent.map { String(format: "剩余 %.0f%%", $0) } ?? "剩余未知").monospacedDigit() }.font(.caption)
                        if let left = meter.remainingPercent { ProgressView(value: left, total: 100).tint(left < 15 ? .orange : .blue) }
                        if let reset = meter.resetsAt {
                            HStack {
                                Text("重置 \(reset.formatted(.dateTime.month().day().hour().minute()))")
                                Spacer(); if reset > Date() { Text(reset, style: .relative) } else { Text("等待刷新") }
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if snapshot.meters.count > 6 { Text("其他额度见 用量概览").font(.caption2).foregroundStyle(.secondary) }
                if let balance = snapshot.balance {
                    HStack {
                        Text(snapshot.currency == "积分" ? "剩余积分" : snapshot.currency == "购买额度" ? "购买额度" : "余额")
                        Spacer()
                        Text(balance, format: .number.precision(.fractionLength(0...2)))
                        if snapshot.currency != "购买额度" { Text(snapshot.currency ?? "") }
                    }.font(.callout.weight(.medium))
                    if let paid = snapshot.paidBalance, let granted = snapshot.grantedBalance {
                        Text(String(format: "充值 %.2f · 赠送 %.2f", paid, granted)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if snapshot.provider == .codex {
                    HStack {
                        Label("重置卡", systemImage: "arrow.counterclockwise.circle")
                        Spacer()
                        Text(snapshot.availableResetCards.map { "\($0) 张可用" } ?? "暂未提供")
                    }.font(.callout.weight(.medium))
                    if let expiry = snapshot.resetCardExpiresAt {
                        Text("最近一张到期 \(expiry.formatted(.dateTime.month().day().hour().minute()))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    metric("今日 Token · UTC", snapshot.todayTokens)
                    Spacer(); metric("累计 Token", snapshot.tokens)
                }
                if let credits = snapshot.spentCredits { Text(String(format: "本机已记录消耗 · %.2f 积分", credits)).font(.callout.weight(.medium)) }
                if let note = snapshot.note { Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Text("更新 \(snapshot.fetchedAt.formatted(.dateTime.hour().minute()))")
                    if Date().timeIntervalSince(snapshot.fetchedAt) > 300 { Text("· 缓存") }
                }.font(.caption2).foregroundStyle(.tertiary)
            } else { Text(loading ? "正在读取账户…" : "刷新以读取用量；需要对应 Agent 登录或已添加的 API Key。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let error { Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func metric(_ title: String, _ value: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value.map(CompactNumber.tokens) ?? "暂无数据").font(.caption.weight(.medium).monospacedDigit()) }
    }
}

struct PomodoroView: View {
    @Bindable var controller: PomodoroController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("番茄钟", systemImage: "timer").font(.subheadline.weight(.semibold))
                Spacer()
                Button { controller.showDurationEditor.toggle() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help("自定义时间")
            }
            if controller.showDurationEditor {
                HStack(spacing: 12) {
                    duration("专注", $controller.state.focusMinutes, maximum: 240)
                    duration("休息", $controller.state.restMinutes, maximum: 120)
                }.onChange(of: controller.state.focusMinutes) { _, _ in controller.saveDurations() }
                    .onChange(of: controller.state.restMinutes) { _, _ in controller.saveDurations() }
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.state.phase == .idle ? "\(controller.state.focusMinutes):00" : controller.text)
                        .font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
                    Text(controller.state.phase == .idle ? "专注 \(controller.state.focusMinutes) 分钟 · 休息 \(controller.state.restMinutes) 分钟" : controller.title + (controller.state.isPaused ? " · 已暂停" : "中"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.state.phase == .idle {
                    Button("开始") { controller.start() }.buttonStyle(.glassProminent)
                    Button("休息") { controller.start(rest: true) }.buttonStyle(.glass)
                } else {
                    Button { controller.togglePause() } label: { Image(systemName: controller.state.isPaused ? "play.fill" : "pause.fill") }.buttonStyle(.glass)
                    Button { controller.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(.glass)
                }
            }
            if let reminder = controller.reminder { Text(reminder).font(.caption).foregroundStyle(.blue) }
            if let error = controller.storageError { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
    }
    private func duration(_ label: String, _ value: Binding<Int>, maximum: Int) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption)
            TextField("分钟", value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 46)
            Stepper("", value: value, in: 1...maximum).labelsHidden()
        }
    }
}
