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
                    if hub.loading.contains(hub.currentID) { ProgressView().controlSize(.mini) }
                    Button {
                        if hub.provider == .codex { Task { await store.refresh() } }
                        refresh(force: true)
                    } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("刷新当前用量")
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
                            if let report = store.probeReports.first {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("最近独立核验").font(.caption.weight(.medium))
                                        Text(report.isConfirmed ? report.deliveredModels.joined(separator: "、") : report.label)
                                            .font(.caption.monospaced()).foregroundStyle(report.isConfirmed ? .blue : .secondary)
                                        Text("\(report.testedAt.formatted(.dateTime.month().day().hour().minute())) · 仅属于该测试")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("查看") { delegate.showMainWindow(); store.showingProbe = true }.buttonStyle(.link).font(.caption)
                                }
                                Divider()
                            }
                        }
                        UsageSnapshotView(snapshot: hub.current, loading: hub.loading.contains(hub.currentID), error: hub.errors[hub.currentID])
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
                    Button("Usage Dashboard…") { delegate.showUtility(.dashboard) }
                    Button("Cost…") { delegate.showUtility(.cost) }
                    Button("Add Account…") { delegate.showUtility(.account) }
                    Button("Status Page…") { delegate.showUtility(.status) }
                    Divider()
                    Button("独立模型核验…") { delegate.showMainWindow(); store.showingProbe = true }
                    Button("设置…") { delegate.showUtility(.settings) }
                    Button("About Model Lens…") { delegate.showUtility(.about) }
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
                    Image(systemName: provider.symbol).frame(maxWidth: .infinity).padding(.vertical, 7)
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
                                    .background(.quaternary.opacity(0.22), in: .rect(corn…7988 tokens truncated…oad["type"] as? String ?? ""
            switch event {
            case "task_started", "turn_started":
                let id = payload["turn_id"] as? String ?? "legacy-\(locator)"
                currentTurnID = id
                updateTurn(id: id, time: time) { turn in
                    turn.startedAt = LensDate.parse(payload["started_at"]) ?? time
                    turn.status = .running; turn.completedAt = nil
                }
            case "task_complete", "turn_complete", "turn_aborted", "task_interrupted":
                guard let id = payload["turn_id"] as? String ?? currentTurnID else { return }
                updateTurn(id: id, time: time) { turn in
                    turn.completedAt = LensDate.parse(payload["completed_at"]) ?? time
                    turn.status = event.contains("abort") || event.contains("interrupt") ? .interrupted :
                        payload["error"].map { $0 is NSNull ? TurnStatus.completed : .failed } ?? .completed
                }
                // Do not clear currentTurnID: late response metadata still belongs to this turn.
            case "token_count":
                if let id = currentTurnID, let info = payload["info"] as? [String: Any],
                   let value = info["total_token_usage"] as? [String: Any] {
                    updateTurn(id: id, time: time) { $0.tokenUsage = TokenUsage.parse(value) }
                }
            case "thread_settings_applied":
                if let model = validModel(payload["model"]) { thread?.selectedModel = model }
            case "model_reroute", "model_rerouted":
                parseRouting(payload, time: time, source: source, locator: locator, allowStreamContext: true)
            default: break
            }
            if let id = payload["turn_id"] as? String ?? currentTurnID {
                updateTurn(id: id, time: time) { _ in }
            }
            return
        }
        // Never descend into response_item, tool results, user messages, or arbitrary JSON strings.
        if type == "response_item" { return }
        if object["method"] as? String == "model/safetyBuffering/updated",
           let params = object["params"] as? [String: Any], let model = validModel(params["model"]) {
            guard let turn = association(params, allowStreamContext: false, time: time) else {
                unassociatedRecords += 1; return
            }
            updateTurn(id: turn, time: time) {
                $0.evidence.append(ModelEvidence(kind: .safetyBuffering, model: model, timestamp: time,
                    source: source, locator: locator, fasterModel: validModel(params["fasterModel"]),
                    bufferingEnabled: params["showBufferingUi"] as? Bool))
            }
            return
        }
        if let method = object["method"] as? String, method == "model/rerouted",
           let params = object["params"] as? [String: Any] {
            parseRouting(params, time: time, source: source, locator: locator, allowStreamContext: false)
            return
        }
        if type == "model/rerouted" || type == "model_rerouted" {
            parseRouting(object, time: time, source: source, locator: locator, allowStreamContext: false)
            return
        }
        // Whitelist server response envelopes, with an explicit association unless reading an
        // already-associated rollout stream. Output text and model self-identification are ignored.
        if type == "response.metadata" {
            parseResponse(object["response"] as? [String: Any] ?? [:], envelope: object,
                          time: time, source: source, locator: locator)
        } else if ["response.created", "response.completed", "response.in_progress", "response.failed"].contains(type),
           let response = object["response"] as? [String: Any] {
            parseResponse(response, envelope: object, time: time, source: source, locator: locator)
        } else if type.isEmpty, let response = object["response"] as? [String: Any], response["object"] as? String == "response" {
            parseResponse(response, envelope: object, time: time, source: source, locator: locator)
        }
    }

    mutating func parseRouting(_ params: [String: Any], time: Date, source: String, locator: String,
                               allowStreamContext: Bool) {
        guard let model = validModel(params["toModel"] ?? params["to_model"]) else { return }
        guard let pair = association(params, allowStreamContext: allowStreamContext, time: time) else {
            unassociatedRecords += 1; return
        }
        let evidence = ModelEvidence(kind: .reroute, model: model,
                                     fromModel: validModel(params["fromModel"] ?? params["from_model"]),
                                     timestamp: time, source: source, locator: locator,
                                     reason: safeReason(params["reason"]))
        updateTurn(id: pair, time: time) { $0.evidence.append(evidence) }
    }

    mutating func parseResponse(_ response: [String: Any], envelope: [String: Any], time: Date,
                               source: String, locator: String) {
        let responseID = response["id"] as? String ?? envelope["response_id"] as? String
        if let responseID, !responseID.hasPrefix("resp_") { return }
        let model = validModel(response["model"])
        let responseHeaders = serverModelHeaders(response["headers"])
        let headers = responseHeaders.isEmpty ? serverModelHeaders(envelope["headers"]) : responseHeaders
        // Official websocket metadata may precede the response ID. An explicit
        // trusted turn association is enough for header evidence, without an invented ID.
        guard responseID != nil || (envelope["type"] as? String == "response.metadata" && !headers.isEmpty) else { return }
        guard model != nil || !headers.isEmpty else { return }
        var identity = envelope
        if let metadata = response["metadata"] as? [String: Any] {
            for key in ["thread_id", "turn_id", "threadId", "turnId"] where identity[key] == nil {
                identity[key] = metadata[key]
            }
        }
        guard let id = association(identity, allowStreamContext: true, time: time) else {
            unassociatedRecords += 1; return
        }
        let date = time == .distantPast ? LensDate.parse(response["created_at"]) ?? time : time
        updateTurn(id: id, time: date) {
            if let model {
                $0.evidence.append(ModelEvidence(kind: .responseModel, model: model, timestamp: date,
                                                source: source, locator: locator, responseID: responseID))
            }
            for (field, model) in headers {
                $0.evidence.append(ModelEvidence(kind: .responseHeader, model: model, timestamp: date,
                                                source: source, locator: locator, responseID: responseID, field: field))
            }
        }
    }

    mutating func association(_ object: [String: Any], allowStreamContext: Bool, time: Date) -> String? {
        let threadID = object["threadId"] as? String ?? object["thread_id"] as? String
        let turnID = object["turnId"] as? String ?? object["turn_id"] as? String
        if let threadID, let existing = thread, existing.id != threadID { return nil }
        if thread == nil, let threadID { thread = ThreadRecord(id: threadID, updatedAt: time) }
        guard thread != nil else { return nil }
        return turnID ?? (allowStreamContext ? currentTurnID : nil)
    }

    mutating func updateTurn(id: String, time: Date, _ update: (inout TurnRecord) -> Void) {
        guard thread != nil else { return }
        if let index = thread!.turns.firstIndex(where: { $0.id == id }) {
            update(&thread!.turns[index])
            thread!.turns[index].lastActivity = max(thread!.turns[index].lastActivity, time)
        } else {
            var turn = TurnRecord(id: id, startedAt: time)
            update(&turn); thread!.turns.append(turn)
        }
        thread!.updatedAt = max(thread!.updatedAt, time)
    }
}

func serverModelHeaders(_ value: Any?) -> [(String, String)] {
    guard let headers = value as? [String: Any] else { return [] }
    return headers.keys.sorted().compactMap { key in
        guard ["openai-model", "x-openai-model"].contains(key.lowercased()) else { return nil }
        let value = headers[key] as? String ?? (headers[key] as? [String])?.first
        return validModel(value).map { (key.lowercased(), $0) }
    }
}

func validModel(_ value: Any?) -> String? {
    guard let model = value as? String, !model.isEmpty, model.count <= 160,
          model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/".contains($0)) }) else { return nil }
    return model
}

private func safeReason(_ value: Any?) -> String? {
    // Persist enum-like routing reasons, never free-form text that could contain credentials.
    guard let value = value as? String, value.count <= 100,
          value.allSatisfy({ $0.isLetter || $0.isNumber || "_-".contains($0) }) else { return nil }
    return value
}

private func sourceName(_ value: Any?) -> String {
    if let name = value as? String { return name }
    if let object = value as? [String: Any] { return object.keys.sorted().joined(separator: "/") }
    return "local"
}
