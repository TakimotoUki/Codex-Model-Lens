import Foundation

struct ParsedStream {
    var thread: ThreadRecord?
    var currentTurnID: String?
    var inheritedUntilOrdinal: Int = 0
    var malformedRecords = 0
    var unassociatedRecords = 0

    mutating func consume(_ data: Data, source: String, locator: String, ordinal: Int = .max) {
        guard !data.isEmpty else { return }
        // Rollout envelopes put type before payload. Skip large prompt/tool records before
        // Foundation constructs their full JSON trees; other envelope layouts still parse normally.
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
        if let payload = prefix.range(of: "\"payload\""),
           prefix[..<payload.lowerBound].contains("\"response_item\"") { return }
        // Avoid decoding prompt/tool bodies and avoid recognizing model names inside their text.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            malformedRecords += 1; return
        }
        let type = object["type"] as? String ?? ""
        let payload = object["payload"] as? [String: Any] ?? [:]
        let time = LensDate.parse(object["timestamp"]) ?? LensDate.parse(payload["timestamp"]) ?? .distantPast
        if type == "session_meta" {
            guard let id = payload["id"] as? String ?? payload["session_id"] as? String else { return }
            thread = ThreadRecord(id: id, cwd: payload["cwd"] as? String ?? "",
                                  provider: payload["model_provider"] as? String ?? "",
                                  source: sourceName(payload["source"]), updatedAt: time)
            thread?.parentID = payload["parent_thread_id"] as? String
            inheritedUntilOrdinal = (payload["subagent_history_start_ordinal"] as? Int) ?? 0
            return
        }
        if ordinal < inheritedUntilOrdinal { return }
        if type == "turn_context" {
            let id = payload["turn_id"] as? String ?? currentTurnID ?? "legacy-\(locator)"
            currentTurnID = id
            updateTurn(id: id, time: time) { turn in
                if let model = validModel(payload["model"]) {
                    turn.requestedModel = model
                    turn.evidence.append(ModelEvidence(kind: .turnContext, model: model, timestamp: time,
                                                       source: source, locator: locator))
                }
                turn.effort = payload["effort"] as? String
                // A context alone proves neither an active turn nor server routing.
            }
            return
        }
        if type == "event_msg" {
            let event = payload["type"] as? String ?? ""
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
        guard let responseID, responseID.hasPrefix("resp_") else { return }
        let model = validModel(response["model"])
        let responseHeaders = serverModelHeaders(response["headers"])
        let headers = responseHeaders.isEmpty ? serverModelHeaders(envelope["headers"]) : responseHeaders
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
