import SwiftUI
import AppKit
import Charts
import ModelLensCore

enum UtilityPage: String { case dashboard, account, settings, about
    var title: String { switch self { case .dashboard: "用量概览"; case .account: "添加账户"; case .settings: "设置"; case .about: "关于 Model Lens" } }
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
                Label("用量概览", systemImage: "chart.bar.xaxis").font(.title2.weight(.semibold))
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
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            AppBrandIcon(size: 88)
            Text("Codex Model Lens").font(.title2.weight(.semibold))
            Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") · macOS 26+ · Apple Silicon").font(.caption).foregroundStyle(.secondary)
            Text("任务模型证据、多平台用量与番茄钟。\n以明确来源保存记录，让缺失信息保持透明。").multilineTextAlignment(.center).font(.callout)
            Text("TakimotoUki · 与 Codex AI 协作开发").font(.caption).foregroundStyle(.secondary)
            HStack { Link("开源仓库", destination: URL(string: "https://github.com/TakimotoUki/Codex-Model-Lens")!); Link("介绍网站", destination: URL(string: "https://takimotouki.github.io/Codex-Model-Lens/")!) }
            Text("MIT License · 数据源设计参考 CodexBar").font(.caption2).foregroundStyle(.tertiary)
        }.padding(30).frame(width: 440)
    }
}
