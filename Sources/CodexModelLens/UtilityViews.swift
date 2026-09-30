import SwiftUI
import AppKit
import Charts
import ModelLensCore

enum UtilityPage: String { case dashboard, cost, account, status, settings, about
    var title: String { switch self { case .dashboard: "Usage Dashboard"; case .cost: "Cost"; case .account: "Add Account"; case .status: "Status Page"; case .settings: "设置"; case .about: "关于 Model Lens" } }
}
struct UtilityView: View {
    @Bindable var store: LensStore
    let page: UtilityPage
    var close: (() -> Void)?
    var body: some View {
        Group {
            switch page {
            case .settings: SettingsView(store: store, close: close)
            case .account: AddAccountView(hub: store.usage)
            case .dashboard: DashboardView(hub: store.usage)
            case .cost: CostView(store: store)
            case .status: StatusView(hub: store.usage)
            case .about: AboutView()
            }
        }.tint(.blue)
    }
}
struct AddAccountView: View {
    @Bindable var hub: UsageHub
    @State private var provider: UsageProvider = .deepseek
    @State private var label = ""
    @State private var key = ""
    @State private var workspace = ""
    @State private var cookieMode = false
    @State private var credentials: Data?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("添加账户", systemImage: "person.crop.circle.badge.plus").font(.title2.weight(.semibold))
            Form {
                Picker("平台", selection: $provider) { ForEach([UsageProvider.codex, .deepseek, .opencodego]) { Text($0.title).tag($0) } }
                TextField("账户标签", text: $label).textFieldStyle(.roundedBorder)
                if provider == .codex {
                    Button(credentials == nil ? "选择 Codex 登录文件…" : "已选择登录文件 · 重新选择…") { chooseCodexLogin() }
                    Text("选择已登录账户的 auth.json，安全保存至本应用钥匙串。切换不会改变 Codex 的登录。过期时重新导入。").font(.caption).foregroundStyle(.secondary)
                } else {
                    if provider == .opencodego {
                        Toggle("使用已登录工作区 Cookie", isOn: $cookieMode)
                        if cookieMode { TextField("工作区 ID · org_…", text: $workspace).textFieldStyle(.roundedBorder) }
                    }
                    SecureField(cookieMode && provider == .opencodego ? "本人会话 Cookie" : "API Key", text: $key).textFieldStyle(.roundedBorder)
                    Text("凭据保存在 macOS 钥匙串。每个账户的缓存单独保存。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("添加账户") {
                do {
                    let web = provider == .opencodego && cookieMode
                    let data = try provider == .codex ? credentials : (web ? JSONSerialization.data(withJSONObject: ["cookie": key, "workspace": workspace]) : Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
                    guard let data, !data.isEmpty else { throw CredentialError.invalid }
                    if web {
                        guard workspace.hasPrefix("org_"), workspace.count <= 100,
                              workspace.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                              !key.contains(where: { $0.isNewline }), key.utf8.count <= 8192 else { throw CredentialError.invalid }
                    }
                    if provider != .codex && !web, key.contains(where: { $0.isWhitespace || $0.isNewline }) { throw CredentialError.invalid }
                    try hub.add(UsageAccount(provider: provider, label: String(label.prefix(80)), credentialKind: web ? "cookie" : provider == .codex ? "codexLogin" : "apiKey"), credential: data)
                    key = ""; credentials = nil; label = ""; error = nil
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.glassProminent).disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            Divider()
            Text("已保存账户").font(.headline)
            if hub.preferences.accounts.isEmpty { Text("Antigravity 与 WorkBuddy 使用本机 Agent 的当前登录；无需复制其密码。").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(hub.preferences.accounts) { account in
                        HStack {
                            Label(account.label, systemImage: account.provider.symbol)
                            Spacer(); Text(account.provider.title).foregroundStyle(.secondary)
                            Button("移除", role: .destructive) { do { try hub.remove(account) } catch { self.error = error.localizedDescription } }
                        }.font(.callout)
                    }
                }
            }.frame(maxHeight: 200)
        }.padding(24).frame(width: 540).fixedSize(horizontal: false, vertical: true)
        .onChange(of: provider) { _, _ in key = ""; credentials = nil; cookieMode = false; workspace = ""; error = nil }
    }
    private func chooseCodexLogin() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.showsHiddenFiles = true
        panel.message = "选择此账户的 Codex auth.json；不会修改原文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 128 * 1024 else { throw CredentialError.invalid }
            let bytes = try Data(contentsOf: url); guard CodexCredentials.isValid(bytes) else { throw CredentialError.invalid }
            credentials = bytes; error = nil
        } catch { self.error = error.localizedDescription }
    }
}
struct DashboardView: View {
    @Bindable var hub: UsageHub
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Usage Dashboard", systemImage: "chart.bar.xaxis").font(.title2.weight(.semibold))
                Text("按账户保存每天最近一次成功读取的用量快照，保留 90 天。累计 Token 曲线不是每日账单。").font(.caption).foregroundStyle(.secondary)
                if hub.snapshots.isEmpty { ContentUnavailableView("还没有用量记录", systemImage: "chart.bar", description: Text("在菜单栏选择平台并刷新，或添加账户。")) }
                ForEach(hub.enabledProviders) { provider in
                    let snapshots = hub.snapshots.values.filter { $0.provider == provider }.sorted { $0.accountID < $1.accountID }
                    ForEach(snapshots, id: \.accountID) { snapshot in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(provider.title + " · " + (hub.preferences.accounts.first { $0.id == snapshot.accountID }?.label ?? "本机账户")).font(.headline)
                            UsageSnapshotView(snapshot: snapshot)
                            let points = hub.history.filter { $0.provider == provider && $0.accountID == snapshot.accountID && $0.tokens != nil }.sorted { $0.fetchedAt < $1.fetchedAt }
                            if points.count > 1 {
                                Chart(points, id: \.fetchedAt) { point in
                                    LineMark(x: .value("时间", point.fetchedAt), y: .value("累计 Token", Double(point.tokens ?? 0))).interpolationMethod(.monotone)
                                }.frame(height: 150).chartYAxisLabel("累计 Token").foregroundStyle(.blue)
                            }
                        }.padding(16).background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 14))
                    }
                }
            }.padding(24)
        }.frame(width: 620, height: 650)
    }
}
struct CostView: View {
    @Bindable var store: LensStore
    private var estimates: [(ThreadRecord, Double)] {
        store.archive.threads.compactMap { thread in
            guard let usage = thread.latestTurn?.tokenUsage, let cost = store.usage.preferences.rates.estimate(usage) else { return nil }
            return (thread, cost)
        }.sorted { $0.1 > $1.1 }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Cost", systemImage: "dollarsign.circle").font(.title2.weight(.semibold))
                Text("订阅额度、积分、余额与费用分别计量。Codex 订阅的 Token 数不能直接换算实际账单。").font(.callout).foregroundStyle(.secondary)
                ForEach(store.usage.snapshots.values.filter { $0.recordedCost != nil }.sorted { $0.provider.rawValue < $1.provider.rawValue }, id: \.accountID) { value in
                    Text(value.provider.title + String(format: " · 本机记录费用 $%.4f", value.recordedCost ?? 0)).font(.headline)
                    if !value.dailyCosts.isEmpty {
                        Chart(value.dailyCosts) { cost in BarMark(x: .value("日期", cost.day), y: .value("USD", cost.amount)) }.frame(height: 170).foregroundStyle(.blue)
                    }
                }
                ForEach(store.usage.snapshots.values.filter { $0.spentCredits != nil }, id: \.accountID) { value in
                    Text(value.provider.title + String(format: " · 本机已记录消耗 %.2f 积分", value.spentCredits ?? 0)).font(.headline)
                }
                GroupBox("Codex 本机价格估算 · USD / 1M Token") {
                    VStack(spacing: 10) {
                        rate("输入", Binding(get: { store.usage.preferences.rates.input }, set: { store.usage.preferences.rates.input = $0 }))
                        rate("缓存输入", Binding(get: { store.usage.preferences.rates.cachedInput }, set: { store.usage.preferences.rates.cachedInput = $0 }))
                        rate("输出", Binding(get: { store.usage.preferences.rates.output }, set: { store.usage.preferences.rates.output = $0 }))
                    }.padding(6)
                }
                Text("请自行输入适用价格。按每个任务最近一次累计 Token 记录估算，缓存输入不重复计费；缺少组成字段的任务不计入。统一价格不代表实际路由模型价格或订阅费用。").font(.caption).foregroundStyle(.secondary)
                Button("保存价格") { store.usage.save() }.buttonStyle(.glass)
                if !estimates.isEmpty {
                    Text(String(format: "本机可计算任务合计 · $%.4f", estimates.reduce(0) { $0 + $1.1 })).font(.headline)
                    ForEach(estimates.prefix(30), id: \.0.id) { thread, amount in HStack { Text(thread.conciseTitle).lineLimit(1); Spacer(); Text(String(format: "$%.4f", amount)).monospacedDigit() }.font(.caption) }
                } else { Text("尚无完整 Token 组成与有效价格记录。").font(.caption).foregroundStyle(.secondary) }
            }.padding(24)
        }.frame(width: 620, height: 620)
    }
    private func rate(_ title: String, _ value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField("0", value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 110) }
    }
}
struct StatusView: View {
    let hub: UsageHub
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Status Page", systemImage: "network").font(.title2.weight(.semibold))
            Text("打开官方服务状态页；未提供独立状态页的平台打开官方产品页面。").font(.caption).foregroundStyle(.secondary)
            ForEach(hub.enabledProviders) { value in
                Link(destination: value.statusURL) { HStack { Label(value.title, systemImage: value.symbol); Spacer(); Text(value.hasDedicatedStatusPage ? "官方状态" : "官方网站").foregroundStyle(.secondary); Image(systemName: "arrow.up.right") } }
            }
        }.padding(24).frame(width: 480).fixedSize(horizontal: false, vertical: true)
    }
}
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder").font(.system(size: 45)).foregroundStyle(.blue).padding(18).glassEffect(.regular, in: .rect(cornerRadius: 22))
            Text("Codex Model Lens").font(.title2.weight(.semibold))
            Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3.0") · macOS 26+ · Apple Silicon").font(.caption).foregroundStyle(.secondary)
            Text("任务模型证据、多平台用量与番茄钟。\n以明确来源保存记录，让缺失信息保持透明。").multilineTextAlignment(.center).font(.callout)
            Text("TakimotoUki · 与 Codex AI 协作开发").font(.caption).foregroundStyle(.secondary)
            HStack { Link("开源仓库", destination: URL(string: "https://github.com/TakimotoUki/Codex-Model-Lens")!); Link("介绍网站", destination: URL(string: "https://takimotouki.github.io/Codex-Model-Lens/")!) }
            Text("MIT License · 数据源设计参考 CodexBar").font(.caption2).foregroundStyle(.tertiary)
        }.padding(30).frame(width: 440)
    }
}
