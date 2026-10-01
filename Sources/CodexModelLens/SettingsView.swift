import SwiftUI
import Foundation
import ModelLensCore

struct SettingsView: View {
    @Bindable var store: LensStore
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var detailedCapture = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.blue)
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
            }
            Form {
                Section("网络响应模型采集") {
                    Text("直接读取当前任务响应的 model 与 OpenAI-Model，并用请求中的任务和轮次 ID 关联。需要在退出 Codex / ChatGPT 后从这里重新打开，已发生的响应无法补回。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("此模式通过本机 HTTPS 反向代理观察该客户端的 OpenAI 响应，只保存模型、关联 ID 和时间。代理只监听本机，服务端地址和证书只传给这次启动的客户端；不改配置文件、系统证书或系统代理。第三方中转暂不覆盖。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if !store.networkCapture.ready { Button("下载网络采集组件…") { store.networkCapture.install() } }
                        else { Button("以网络采集模式打开 Codex") { store.networkCapture.launch(outputDirectory: store.importedDirectory) } }
                        if store.networkCapture.isRunning { Button("停止采集") { store.networkCapture.stop() } }
                        if store.networkCapture.busy { ProgressView().controlSize(.small) }
                    }.disabled(store.networkCapture.busy)
                    Text(store.networkCapture.message).font(.caption).foregroundStyle(store.networkCapture.isRunning ? .blue : .secondary)
                    Text("组件按需下载，占用独立磁盘空间；采集时会增加内存与 CPU 开销，默认关闭。服务端若未公开真实模型名，仍会明确显示未确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("服务端模型采集") {
                    Text("为后续任务记录服务端报告的模型，包括未发生切换的响应。请先结束或暂停任务并自行退出 Codex / ChatGPT，再使用下方按钮打开。客户端运行期间不会自动重启。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("同时采集响应模型字段（实验性）", isOn: $detailedCapture)
                    if detailedCapture {
                        Text("此选项会让 Codex 自身记录 SSE / WebSocket 调试日志，可能包含任务内容，并增加磁盘与运行开销。Model Lens 只保存白名单模型元数据。请勿公开分享原始日志；正常重新打开客户端可恢复默认日志级别。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("以模型采集模式打开 Codex / ChatGPT") { store.launchModelCapture(detailed: detailedCapture) }
                    Text("默认只启用核心模块的 info 日志；上游必须返回模型字段，且记录必须包含明确任务与轮次 ID。不更改配置或登录文件，未保存的历史字段无法补回。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = store.captureError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                Section("菜单栏平台") {
                    ForEach(UsageProvider.allCases) { provider in
                        Toggle(provider.title, isOn: Binding(get: { store.usage.preferences.enabled.contains(provider) }, set: { store.usage.enable(provider, $0) }))
                    }
                    Text("Antigravity / Gemini、OpenCode Go、DeepSeek、WorkBuddy 仅显示在菜单栏与用量面板；Codex 任务工作区保持专注。").font(.caption).foregroundStyle(.secondary)
                    if let error = store.usage.configurationError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                Section("本机数据源") {
                    Toggle("实时监听桌面模型路由", isOn: $store.settings.liveModelEvents)
                    Text(store.desktopStatus.message).font(.caption).foregroundStyle(.secondary)
                    directoryField("Codex 数据目录", path: store.settings.codexHome) { store.chooseDirectory() }
                    Toggle("读取 Codex 桌面日志", isOn: $store.settings.scanDesktopLogs)
                    if store.settings.scanDesktopLogs {
                        directoryField("桌面日志目录", path: store.settings.desktopLogs) { store.chooseDirectory(forLogs: true) }
                    }
                }
                Section("监测与显示") {
                    Picker("刷新间隔", selection: $store.settings.refreshSeconds) {
                        Text("2 秒").tag(2.0); Text("5 秒").tag(5.0); Text("10 秒").tag(10.0); Text("15 秒").tag(15.0); Text("30 秒").tag(30.0)
                    }
                    Text("菜单栏后台至少间隔 15 秒；Codex 关闭时每 60 秒检查。额度按需读取并缓存 5 分钟。").font(.caption).foregroundStyle(.secondary)
                    Toggle("显示自动审核等内部任务", isOn: $store.settings.showInternal)
                }
                Section("检测历史") {
                    LabeledContent("保存位置") { Text(store.dataDirectory.path).font(.caption).textSelection(.enabled) }
                    Button("在 Finder 中显示历史文件") { store.revealHistory() }
                }
            }.formStyle(.grouped)
            Text("读取任务索引、会话元数据、模型事件及通信日志中的相关响应头和错误字段。请求证据自动保存在历史文件中。无法访问的记录会显示读取提示。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("导入模型证据…") { store.importEvidence() }
                Spacer()
                Button("完成") {
                    store.saveSettings(); if let close { close() } else { dismiss() }
                    Task { await store.refresh() }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 640, height: 640)
    }
    private func directoryField(_ title: String, path: String, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Button("选择…", action: action)
            }
        }
    }
}
