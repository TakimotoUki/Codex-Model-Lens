import SwiftUI
import Foundation
import ModelLensCore

struct SettingsView: View {
    @Bindable var store: LensStore
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.blue)
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
            }
            Form {
                Section("菜单栏平台") {
                    ForEach(UsageProvider.allCases) { provider in
                        Toggle(provider.title, isOn: Binding(get: { store.usage.preferences.enabled.contains(provider) }, set: { store.usage.enable(provider, $0) }))
                    }
                    Text("Antigravity / Gemini、OpenCode Go、DeepSeek、WorkBuddy 仅显示在菜单栏与用量面板；Codex 任务工作区保持专注。").font(.caption).foregroundStyle(.secondary)
                    if let error = store.usage.configurationError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                Section("本机数据源") {
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
