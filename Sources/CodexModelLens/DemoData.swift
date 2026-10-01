import Foundation
import ModelLensCore

extension LensStore {
    func installDemo() {
        monitoring = false
        let now = Date()
        var task = ThreadRecord(id: "demo-task", title: "演示任务 · 原生界面优化", source: "demo", updatedAt: now)
        var turn = TurnRecord(id: "demo-turn", startedAt: now, status: .running)
        turn.requestedModel = "demo-request-model"
        turn.evidence.append(ModelEvidence(kind: .responseModel, model: "demo-server-model", timestamp: now,
            source: "演示数据", locator: "demo", responseID: "resp_demo"))
        task.turns = [turn]; task.selectedModel = turn.requestedModel
        let arguments = CommandLine.arguments
        let requestedCount = arguments.firstIndex(of: "--demo-tasks").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 1
        archive.threads = arguments.contains("--demo-empty") ? [] : (0..<max(1, min(8, requestedCount))).map { index in
            var copy = task
            copy.id = "demo-task-\(index)"; copy.title = "演示任务 \(index + 1) · 原生界面优化"
            if arguments.contains("--demo-long-titles") {
                copy.title = index.isMultiple(of: 2) ? "演示 · 读取工作目录（/Users/demo/Desktop/历史资料/臺灣日記知識庫/葉盛吉日記）中的工作指南 md 文档、检查点和 Excel 记录" : "演示 · 帮我使用 Swift 语言写一个查看当前 Codex 任务实际使用模型的 macOS 原生程序，Liquid Glass 界面简洁大方"
            }
            copy.turns[0].evidence[0].origin = .networkCapture
            if arguments.contains("--demo-unconfirmed") { copy.turns[0].evidence = [] }
            return copy
        }
        selection = archive.threads.first?.id
        if let index = CommandLine.arguments.firstIndex(of: "--preview-filter"), CommandLine.arguments.indices.contains(index + 1),
           let value = TaskFilter(rawValue: CommandLine.arguments[index + 1]) { filter = value }
        latestScan = ScanResult(); latestScan.threads = archive.threads; latestScan.scannedAt = now
        latestScan.sources = [
            ScanSourceStatus(id: "demo-index", title: "任务索引", path: "演示数据", state: .available, detail: "演示任务 · 只读"),
            ScanSourceStatus(id: "demo-rollouts", title: "轮次记录", path: "演示数据", state: .available, detail: "请求模型与响应字段"),
            ScanSourceStatus(id: "demo-transport", title: "通信日志", path: "演示数据", state: .available, detail: "仅保留模型、时间与请求标识"),
            ScanSourceStatus(id: "demo-import", title: "导入证据", path: "演示数据", state: .missing, detail: "未导入外部证据")
        ]
        usage.preferences.enabled = Set(UsageProvider.allCases)
        for value in UsageProvider.allCases {
            var snapshot = UsageSnapshot(provider: value, accountID: "demo-" + value.rawValue, source: "演示数据 · 非真实账户")
            snapshot.plan = "Demo Plan"
            snapshot.tokens = 2_456_789_000; snapshot.todayTokens = 12_345_678
            snapshot.meters = [UsageMeter(id: "primary", title: "5 小时额度", remainingPercent: 64, resetsAt: now.addingTimeInterval(7200)),
                UsageMeter(id: "weekly", title: "周额度", remainingPercent: 82, resetsAt: now.addingTimeInterval(172800))]
            snapshot.note = "演示数据 · 非真实账户"
            if value == .codex { snapshot.availableResetCards = 1; snapshot.balance = 0; snapshot.currency = "购买额度" }
            if [.antigravity, .deepseek, .workbuddy].contains(value) { snapshot.tokens = nil; snapshot.todayTokens = nil }
            if [.deepseek, .workbuddy].contains(value) { snapshot.meters = []; snapshot.balance = 128; snapshot.currency = value == .workbuddy ? "积分" : "CNY" }
            usage.snapshots["local-" + value.rawValue] = snapshot
            usage.serviceStatuses[value] = ServiceStatus(condition: .operational, detail: "演示 · 全部公开服务正常", events: [
                ServiceEvent(title: "演示 · 服务状态事件标题可以换行并保持左对齐", url: value.statusURL, updatedAt: now, phase: "resolved")])
            if value == .antigravity {
                usage.serviceStatuses[value]?.items = [
                    ServiceStatusItem(title: "Gemini API / AI Studio", condition: .operational, detail: "演示 · 暂无未解决事件", url: URL(string: "https://aistudio.google.com/status")!),
                    ServiceStatusItem(title: "Google Cloud", condition: .operational, detail: "演示 · 全部服务暂无公开未解决事件", url: value.statusURL)]
            }
        }
        if let index = arguments.firstIndex(of: "--preview-provider"), arguments.indices.contains(index + 1),
           let provider = UsageProvider(rawValue: arguments[index + 1]) { usage.provider = provider }
        if CommandLine.arguments.contains("--preview-countdown") { pomodoro.state.start(); pomodoro.startForPreview() }
    }
}
