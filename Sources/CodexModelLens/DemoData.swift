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
        archive.threads = CommandLine.arguments.contains("--demo-empty") ? [] : [task]; selection = archive.threads.first?.id
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
            usage.snapshots["local-" + value.rawValue] = snapshot
        }
        if CommandLine.arguments.contains("--preview-countdown") { pomodoro.state.start(); pomodoro.startForPreview() }
    }
}
