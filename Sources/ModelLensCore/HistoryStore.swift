import Foundation

public struct HistoryArchive: Codable, Sendable {
    public var schemaVersion = 2
    public var savedAt: Date = Date()
    public var threads: [ThreadRecord] = []
    public var requests: [RequestRecord]?
    public var logCoverage: LogCoverage?
    public var removedThreadIDs: [String]?
    public var requestRecords: [RequestRecord] { requests ?? [] }
    public init() {}
}

public enum HistoryError: Error, LocalizedError {
    case incompatibleVersion(Int)
    public var errorDescription: String? {
        switch self { case .incompatibleVersion(let version): "历史文件版本 \(version) 不受当前应用支持；原文件已保留。" }
    }
}

public enum HistoryStore {
    public static func load(from url: URL) throws -> HistoryArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return HistoryArchive() }
        let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: url))
        guard (1...2).contains(archive.schemaVersion) else { throw HistoryError.incompatibleVersion(archive.schemaVersion) }
        return archive
    }

    public static func save(_ archive: HistoryArchive, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        // Atomic replacement retains the old file if encoding or writing fails.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func merge(_ result: ScanResult, into archive: HistoryArchive) -> HistoryArchive {
        let removed = Set(archive.removedThreadIDs ?? [])
        var threads = Dictionary(archive.threads.filter { !removed.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let detected = Set(result.threads.map(\.id))
        for (id, var record) in threads where !detected.contains(id) {
            for index in record.turns.indices where record.turns[index].status == .running {
                record.turns[index].status = .unconfirmed
            }
            threads[id] = record
        }
        for var current in result.threads where !removed.contains(current.id) {
            if let old = threads[current.id] {
                current.firstDetectedAt = old.firstDetectedAt
                let detectedTurns = Set(current.turns.map(\.id))
                current.turns = mergeTurns(old.turns, current.turns)
                for index in current.turns.indices where !detectedTurns.contains(current.turns[index].id) && current.turns[index].status == .running {
                    current.turns[index].status = .unconfirmed
                }
            } else { current.firstDetectedAt = result.scannedAt }
            current.lastDetectedAt = result.scannedAt
            threads[current.id] = current
        }
        var next = HistoryArchive(); next.savedAt = result.scannedAt
        next.removedThreadIDs = archive.removedThreadIDs
        next.threads = threads.values.sorted { $0.updatedAt > $1.updatedAt }
        next.requests = Dictionary((archive.requestRecords + result.requests).filter { !removed.contains($0.threadID ?? "") }.map { ($0.id, $0) },
                                   uniquingKeysWith: { _, last in last }).values.sorted { $0.timestamp > $1.timestamp }
        next.logCoverage = result.logCoverage ?? archive.logCoverage
        return next
    }

    public static func removingThreads(_ ids: Set<String>, from archive: HistoryArchive) -> HistoryArchive {
        var next = archive
        next.removedThreadIDs = Set(archive.removedThreadIDs ?? []).union(ids).sorted()
        next.threads.removeAll { ids.contains($0.id) }
        next.requests = archive.requestRecords.filter { !ids.contains($0.threadID ?? "") }
        next.savedAt = Date()
        return next
    }

    static func mergeTurns(_ old: [TurnRecord], _ new: [TurnRecord]) -> [TurnRecord] {
        var turns = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for var current in new {
            if let prior = turns[current.id] {
                let evidence = Dictionary((prior.evidence + current.evidence).map { ($0.id, $0) },
                                          uniquingKeysWith: { first, _ in first })
                current.evidence = evidence.values.sorted {
                    $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
                }
                current.requestedModel = current.requestedModel ?? prior.requestedModel
                current.effort = current.effort ?? prior.effort
                current.tokenUsage = current.tokenUsage ?? prior.tokenUsage
                if current.status == .unknown { current.status = prior.status }
                current.completedAt = current.completedAt ?? prior.completedAt
                current.lastActivity = max(current.lastActivity, prior.lastActivity)
                if current.startedAt == .distantPast { current.startedAt = prior.startedAt }
                else if prior.startedAt != .distantPast { current.startedAt = min(current.startedAt, prior.startedAt) }
            }
            turns[current.id] = current
        }
        return turns.values.sorted { $0.startedAt > $1.startedAt }
    }

    public static func exportCSV(_ threads: [ThreadRecord]) -> String {
        func quote(_ value: String) -> String {
            // Prevent formula execution when task titles are opened in Excel/Numbers.
            let protected = ["=", "+", "-", "@", "\t", "\r", "\n"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
            return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        var rows = ["任务ID,标题,轮次ID,开始时间,状态,轮次请求模型,服务端报告模型,模型差异,证据类型,证据模型,原模型,路由原因,事件时间,来源,定位,响应ID,可重试模型,缓冲界面状态,模型字段"]
        for thread in threads {
            for turn in thread.turns {
                let entries: [ModelEvidence?] = turn.evidence.isEmpty ? [nil] : turn.evidence.map { Optional($0) }
                for evidence in entries {
                    rows.append([thread.id, thread.title, turn.id, formatter.string(from: turn.startedAt),
                                 turn.status.label, turn.recordedModel ?? "", turn.reportedModel ?? "",
                                 turn.hasModelDifference ? "是" : "未发现明确差异", evidence?.kind.label ?? "",
                                 evidence?.model ?? "", evidence?.fromModel ?? "", evidence?.reason ?? "",
                                 evidence.flatMap { $0.timestamp == .distantPast ? nil : formatter.string(from: $0.timestamp) } ?? "",
                                 evidence?.source ?? "", evidence?.locator ?? "", evidence?.responseID ?? "",
                                 evidence?.fasterModel ?? "", evidence?.bufferingEnabled.map { $0 ? "true" : "false" } ?? "", evidence?.field ?? ""]
                        .map(quote).joined(separator: ","))
                }
            }
        }
        return "\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n"
    }

    public static func exportRequestsCSV(_ records: [RequestRecord]) -> String {
        func quote(_ text: String) -> String {
            let safe = ["=", "+", "-", "@", "\t", "\r", "\n"].contains(where: text.hasPrefix) ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let header = "时间UTC,任务ID,轮次ID,请求模型,请求ID,HTTP状态,安全缓冲,可重试模型,错误代码,容量文字,来源,定位,日志模块,相关响应头,报告失败"
        let rows = records.map { r in
            [r.utcTimestamp, r.threadID ?? "", r.turnID ?? "", r.requestedModel ?? "", r.requestID ?? "",
             r.httpStatus.map(String.init) ?? "", r.safetyBuffering.map { $0 ? "true" : "false" } ?? "",
             r.fasterModel ?? "", r.errorCode ?? "", r.capacityMessage ? "true" : "false", r.source,
             r.locator, r.target, r.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"),
             r.failureReported == true ? "true" : "false"]
                .map(quote).joined(separator: ",")
        }
        return "\u{FEFF}" + ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}
