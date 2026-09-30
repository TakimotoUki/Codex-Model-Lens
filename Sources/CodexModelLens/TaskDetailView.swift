import SwiftUI
import AppKit
import ModelLensCore

struct TaskDetailView: View {
    let thread: ThreadRecord
    let store: LensStore
    @State private var selectedTurnID: String?
    @State private var showAllEvidence = false
    private var selectedTurn: TurnRecord? {
        thread.turns.first { $0.id == selectedTurnID } ?? thread.latestTurn
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                title
                if let turn = selectedTurn {
                    comparison(turn)
                    requestEvidence(turn)
                    evidence(turn)
                } else {
                    ContentUnavailableView("暂无轮次模型证据", systemImage: "doc.questionmark",
                                           description: Text("任务设置中记录的模型：\(thread.selectedModel ?? "未知")。这不能证明实际执行模型。"))
                }
                if !thread.turns.isEmpty { timeline }
                metadata
            }
            .padding(28).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.25))
        .textSelection(.enabled)
        .onAppear {
            let args = CommandLine.arguments
            if args.contains("--preview-path"), let i = args.firstIndex(of: "--preview-turn"), args.indices.contains(i + 1) {
                selectedTurnID = args[i + 1]
            }
        }
        .onChange(of: thread.latestTurn?.id) { _, _ in
            // Follow the latest turn unless the user is inspecting an older one.
            if selectedTurnID == nil { showAllEvidence = false }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(thread.parentID == nil ? "Codex 任务" : "Codex 子任务", systemImage: thread.parentID == nil ? "terminal" : "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                statusBadge(thread.statusLabel, color: thread.isRunning ? .blue : thread.isUnconfirmed ? .orange : .secondary)
            }
            Text(thread.conciseTitle).font(.system(size: 24, weight: .semibold)).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).help(thread.title)
                .contextMenu { Button("复制完整任务标题") { store.copy(thread.title) } }
            if !thread.cwd.isEmpty {
                Label(URL(fileURLWithPath: thread.cwd).lastPathComponent, systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary).help(thread.cwd)
            }
        }
    }

    private func comparison(_ turn: TurnRecord) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("模型证据").font(.headline)
                Spacer()
                if turn.hasModelDifference { statusBadge("发现模型差异", color: .orange) }
                else { statusBadge(turn.reportedModel == nil ? "实际模型未确认" : "有服务端报告", color: turn.reportedModel == nil ? .secondary : .blue) }
            }
            VStack(alignment: .leading, spacing: 0) {
                modelLine(title: "轮次记录模型", model: turn.recordedModel ?? "暂无轮次记录", symbol: "slider.horizontal.3", accent: .secondary)
                Divider().padding(.horizontal, 17)
                modelLine(title: "服务端报告模型", model: turn.reportedModel ?? "本轮未记录服务端模型", symbol: "arrow.down.doc", accent: turn.hasModelDifference ? .orange : .blue)
            }
            .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 15))
            if let routed = turn.serverEvidence.last(where: { $0.kind == .reroute }), let from = routed.fromModel {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
                    Text(from).lineLimit(1)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(routed.model).lineLimit(1)
                }
                .font(.system(size: 11, design: .monospaced)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: .rect(cornerRadius: 10))
            }
            if let usage = turn.tokenUsage {
                HStack {
                    Text("任务累计 Token").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(usage.total.map(CompactNumber.tokens) ?? "未知").font(.caption.monospacedDigit())
                }
                Text("本机 token_count 记录，包含该任务先前轮次；不等于账户计费或剩余额度。").font(.caption2).foregroundStyle(.secondary)
            }
            Text(turn.reportedModel == nil
                 ? "尚未取得明确路由或响应模型字段，实际交付模型保持未确认。"
                 : "服务端字段是可观察到的模型报告；本地日志和导入文件未经独立认证，无法证明底层模型权重。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func requestEvidence(_ turn: TurnRecord) -> some View {
        let records = store.requests(threadID: thread.id, turnID: turn.id)
        let buffering = records.filter(\.isBuffering)
        let event = turn.safetyEvidence.sorted { $0.timestamp > $1.timestamp }.first
        let faster = buffering.first?.fasterModel ?? event?.fasterModel
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("请求与安全缓冲").font(.headline)
                Spacer()
                Button("查看请求证据") { store.showRequestDiagnostics(threadID: thread.id) }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.blue)
            }
            if !buffering.isEmpty || event != nil {
                VStack(alignment: .leading, spacing: 9) {
                    Label("该轮记录过安全缓冲", systemImage: "hourglass").font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                    if let faster { Text("可重试模型：\(faster)").font(.system(size: 13, design: .monospaced)) }
                    Text("这是安全缓冲期间提供的重试目标，不能单独证明已经切换了实际交付模型。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.06), in: .rect(cornerRadius: 12))
            }
            Text("\(records.count) 条通信记录 · \(RequestSummary(records).identifiedRequests) 个已记录 ID 的请求")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(records.prefix(4))) { record in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(record.utcTimestamp).font(.caption2.monospaced())
                        Spacer()
                        Text(record.statusLabel).font(.caption2).foregroundStyle(record.isError ? .orange : .secondary)
                    }
                    Text(record.requestID ?? "未记录请求 ID").font(.caption2.monospaced()).textSelection(.enabled)
                    Text("\(URL(fileURLWithPath: record.source).lastPathComponent) · \(record.locator)")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(10).background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 10))
            }
            if records.isEmpty && event == nil {
                Text("该轮尚未发现可关联的通信记录。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modelLine(title: String, model: String, symbol: String, accent: Color) -> some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: symbol).font(.title3).foregroundStyle(accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(model).font(.system(size: 17, weight: .medium, design: .monospaced)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(18)
    }

    private func evidence(_ turn: TurnRecord) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("证据来源").font(.headline)
                Spacer()
                Text("\(turn.evidence.count) 条").font(.caption).foregroundStyle(.secondary)
            }
            if turn.evidence.isEmpty {
                Text("该轮次没有可读取的模型字段。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(turn.evidence.sorted { $0.timestamp > $1.timestamp }.prefix(showAllEvidence ? .max : 6))) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.kind.isServerClaim ? "arrow.down.doc" : "doc.text")
                        .foregroundStyle(item.kind.isServerClaim ? .blue : .secondary).frame(width: 20).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.kind.label).font(.caption.weight(.medium))
                            if item.source.contains("ImportedEvidence") { Text("导入 · 未认证").font(.caption2).foregroundStyle(.orange) }
                            Spacer()
                            if item.timestamp != .distantPast { Text(item.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary) }
                        }
                        if let field = item.field { Text(field).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                        Text(item.model).font(.system(size: 11, design: .monospaced))
                        Text("\(URL(fileURLWithPath: item.source).lastPathComponent) · \(item.locator)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(item.source)
                    }
                    Button { copyEvidence(item, turn: turn) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("复制模型字段及来源")
                }
                .padding(11).background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 10))
            }
            if turn.evidence.count > 6 {
                Button(showAllEvidence ? "收起" : "显示全部证据") { showAllEvidence.toggle() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.blue)
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("轮次历史").font(.headline)
                Spacer()
                Text("\(thread.turns.count) 轮").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(thread.turns) { turn in
                Button {
                    selectedTurnID = turn.id; showAllEvidence = false
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle().fill(turn.id == selectedTurn?.id ? .blue.opacity(0.12) : .secondary.opacity(0.06))
                            Image(systemName: turn.hasModelDifference ? "arrow.triangle.branch" : turn.isOpen ? "waveform" : "clock")
                                .font(.caption).foregroundStyle(turn.hasModelDifference ? .orange : .blue)
                        }.frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(turn.reportedModel ?? turn.recordedModel ?? "暂无模型记录")
                                .font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(turn.startedAt, format: .dateTime.month().day().hour().minute())
                                Text("· \(turn.status.label)")
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if turn.id == selectedTurn?.id { Image(systemName: "checkmark").font(.caption).foregroundStyle(.blue) }
                    }
                    .padding(10).contentShape(Rectangle())
                    .background(turn.id == selectedTurn?.id ? Color.blue.opacity(0.05) : .clear, in: .rect(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            info("任务 ID", thread.id)
            if let turn = selectedTurn { info("轮次 ID", turn.id) }
            info("任务设置模型", thread.selectedModel ?? "未记录")
            if !thread.provider.isEmpty { info("提供方", thread.provider) }
            info("首次检测", thread.firstDetectedAt.formatted(date: .abbreviated, time: .shortened))
            info("最近检测", thread.lastDetectedAt.formatted(date: .abbreviated, time: .shortened))
            if let parent = thread.parentID { info("父任务", parent) }
        }
    }

    private func info(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key).frame(width: 85, alignment: .leading).foregroundStyle(.secondary)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption2)
    }
    private func copyEvidence(_ item: ModelEvidence, turn: TurnRecord) {
        store.copy("task=\(thread.id)\nturn=\(turn.id)\nkind=\(item.kind.rawValue)\nmodel=\(item.model)\nfrom_model=\(item.fromModel ?? "")\nsource=\(item.source)\nlocator=\(item.locator)\nresponse_id=\(item.responseID ?? "")")
    }
}

func statusBadge(_ text: String, color: Color) -> some View {
    Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .glassEffect(.regular.tint(color.opacity(0.07)), in: .capsule)
}
