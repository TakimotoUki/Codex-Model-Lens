import Foundation

public enum EvidenceImportError: Error, LocalizedError {
    case noEvidence
    public var errorDescription: String? { "没有找到同时包含任务 ID、轮次 ID 和有效模型字段的支持记录。" }
}

public enum EvidenceImporter {
    public static func importFile(_ data: Data, sourceName: String, to folder: URL) async throws -> Int {
        // Accept a single JSON object, an array of envelopes, or NDJSON. Each entry must associate
        // itself; imports cannot inherit a session context or impersonate selected-model settings.
        let records: [Data]
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let array = object as? [[String: Any]] { records = try array.map { try JSONSerialization.data(withJSONObject: $0) } }
            else { records = [data] }
        } else { records = data.split(separator: 10).map { Data($0) } }
        var sanitized: [Data] = []
        for record in records {
            guard let envelope = try? JSONSerialization.jsonObject(with: record) as? [String: Any] else { continue }
            let type = envelope["type"] as? String ?? ""
            let method = envelope["method"] as? String ?? ""
            guard ["model/rerouted", "model/safetyBuffering/updated"].contains(method) || ["model/rerouted", "model_rerouted", "response.created", "response.completed", "response.in_progress", "response.metadata", "response.failed"].contains(type) || envelope["response"] != nil else { continue }
            var stream = ParsedStream()
            stream.consume(record, source: "import:\(sourceName)", locator: "import")
            guard let thread = stream.thread else { continue }
            for turn in thread.turns {
                for evidence in turn.evidence where evidence.kind.isServerClaim || evidence.kind == .safetyBuffering {
                    var clean: [String: Any] = ["thread_id": thread.id, "turn_id": turn.id]
                    if evidence.timestamp != .distantPast { clean["timestamp"] = ISO8601DateFormatter().string(from: evidence.timestamp) }
                    if evidence.kind == .safetyBuffering {
                        clean["method"] = "model/safetyBuffering/updated"
                        var params: [String: Any] = ["threadId": thread.id, "turnId": turn.id, "model": evidence.model]
                        if let faster = evidence.fasterModel { params["fasterModel"] = faster }
                        if let enabled = evidence.bufferingEnabled { params["showBufferingUi"] = enabled }
                        clean["params"] = params
                    } else if evidence.kind == .reroute {
                        clean["method"] = "model/rerouted"
                        var params: [String: Any] = ["threadId": thread.id, "turnId": turn.id, "toModel": evidence.model]
                        if let from = evidence.fromModel { params["fromModel"] = from }
                        if let reason = evidence.reason { params["reason"] = reason }
                        clean["params"] = params
                    } else {
                        clean["type"] = "response.completed"
                        if evidence.kind == .responseHeader {
                            clean["response"] = ["id": evidence.responseID ?? "", "object": "response", "headers": [evidence.field ?? "openai-model": evidence.model]]
                        } else {
                            clean["response"] = ["id": evidence.responseID ?? "", "object": "response", "model": evidence.model]
                        }
                    }
                    clean["imported_from"] = String(sourceName.prefix(200))
                    sanitized.append(try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]))
                }
            }
        }
        guard !sanitized.isEmpty else { throw EvidenceImportError.noEvidence }
        var output = Data()
        for record in sanitized { output.append(record); output.append(10) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent("evidence-\(stableID(String(decoding: output, as: UTF8.self))).jsonl")
        try output.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return sanitized.count
    }
}
