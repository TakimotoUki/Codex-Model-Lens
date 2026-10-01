import Foundation

public struct ScannerConfiguration: Sendable {
    public var codexHome: URL
    public var desktopLogs: URL?
    public var importedEvidence: URL?
    public init(codexHome: URL, desktopLogs: URL? = nil, importedEvidence: URL? = nil) {
        self.codexHome = codexHome; self.desktopLogs = desktopLogs; self.importedEvidence = importedEvidence
    }
}

private struct FileCursor {
    var offset: UInt64 = 0
    var lineNumber = 0
    var inode: UInt64 = 0
    var size: UInt64 = 0
    var modifiedAt: Date = .distantPast
    var stream = ParsedStream()
}

public actor CodexScanner {
    private let configuration: ScannerConfiguration
    private var cursors: [String: FileCursor] = [:]
    private var externalEvidence: [String: ThreadRecord] = [:]
    private var lastLogID: Int64 = 0
    private var logDatabasePath: String?
    private var logDatabaseInode: UInt64?
    private var cachedLogCoverage: LogCoverage?
    private var requests: [String: RequestRecord] = [:]

    public init(configuration: ScannerConfiguration) { self.configuration = configuration }

    public func scan(now: Date = Date(), clientIsRunning: Bool = true) -> ScanResult {
        let begin = Date()
        var result = ScanResult(scannedAt: now)
        var records: [String: ThreadRecord] = [:]
        let root = configuration.codexHome
        guard FileManager.default.fileExists(atPath: root.path) else {
            result.diagnostics.append(ScanDiagnostic(source: root.path, message: "Codex 数据目录不存在。请在设置中选择正确目录。"))
            result.sources?.append(ScanSourceStatus(id: "home", title: "Codex 数据目录", path: root.path, state: .missing, detail: "目录不存在"))
            return result
        }
        let children: [URL]
        do { children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch {
            result.diagnostics.append(ScanDiagnostic(source: root.path, message: error.localizedDescription))
            result.sources?.append(ScanSourceStatus(id: "home", title: "Codex 数据目录", path: root.path, state: .unreadable, detail: "请检查目录访问权限"))
            return result
        }
        if let state = latestDatabase(children, prefix: "state_") {
            do {
                let db = try ReadOnlySQLite(url: state)
                let columns = try db.columns("threads")
                let wanted = ["id", "title", "cwd", "model_provider", "model", "source", "archived", "updated_at", "rollout_path"]
                guard columns.contains("id") else { throw SQLiteReadError.query("缺少 threads.id 字段") }
                let rows = try db.query("SELECT \(wanted.filter { columns.contains($0) }.joined(separator: ",")) FROM threads")
                for row in rows {
                    guard let id = row["id"] else { continue }
                    var thread = ThreadRecord(id: id, title: row["title"] ?? "未命名任务", cwd: row["cwd"] ?? "",
                                              provider: row["model_provider"] ?? "", source: row["source"] ?? "local",
                                              updatedAt: numericDate(row["updated_at"]) ?? .distantPast)
                    thread.selectedModel = validModel(row["model"])
                    thread.rolloutPath = row["rollout_path"]
                    thread.archived = row["archived"] == "1"
                    records[id] = thread
                }
                result.sources?.append(ScanSourceStatus(id: "index", title: "任务索引", path: state.path, state: .available, detail: "\(rows.count) 个任务"))
            } catch {
                result.diagnostics.append(ScanDiagnostic(source: state.path, message: error.localizedDescription))
                result.sources?.append(ScanSourceStatus(id: "index", title: "任务索引", path: state.path, state: .unreadable, detail: "数据库读取失败"))
            }
        } else {
            result.diagnostics.append(ScanDiagnostic(source: root.path, message: "没有任务索引数据库；从会话日志恢复任务。"))
            result.sources?.append(ScanSourceStatus(id: "index", title: "任务索引", path: root.path, state: .missing, detail: "使用会话记录恢复任务"))
        }

        let rolloutDiagnosticStart = result.diagnostics.count
        var rolloutURLs: Set<URL> = []
        for folder in ["sessions", "archived_sessions"] {
            for url in enumerate(root.appendingPathComponent(folder), suffix: "jsonl", diagnostics: &result.diagnostics) {
                rolloutURLs.insert(url)
            }
        }
        for record in records.values {
            if let path = record.rolloutPath {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                // Never read arbitrary paths from an index. Every source must remain inside Codex home.
                if isInside(url, root: root), FileManager.default.fileExists(atPath: url.path) { rolloutURLs.insert(url) }
            }
        }
        var existingPaths: Set<String> = []
        for url in rolloutURLs.sorted(by: { $0.path < $1.path }) {
            existingPaths.insert(url.path)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let modified = attributes[.modificationDate] as? Date ?? .distantPast
                var cursor = cursors[url.path] ?? FileCursor()
                if cursor.inode != inode || size < cursor.offset || (size == cursor.size && modified != cursor.modifiedAt) {
                    cursor = FileCursor()
                }
                if size != cursor.size || modified != cursor.modifiedAt || cursors[url.path] == nil {
                    let report = try LineReader.read(url: url, offset: cursor.offset, lineNumber: cursor.lineNumber) { data, line in
                        if cursor.stream.thread != nil && line - 1 < cursor.stream.inheritedUntilOrdinal { return }
                        let head = String(decoding: data.prefix(240), as: UTF8.self)
                        let metadataEvent = head.contains("event_msg") && ["task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted", "task_interrupted", "thread_settings_applied", "model_reroute", "token_count"].contains(where: head.contains)
                        guard head.contains("session_meta") || head.contains("turn_context") || metadataEvent ||
                                head.contains("rerouted") || head.contains("response.created") || head.contains("response.completed") || head.contains("model/safetyBuffering/updated") else { return }
                        cursor.stream.consume(data, source: url.path, locator: "line:\(line)", ordinal: line - 1)
                    }
                    cursor.offset = report.offset; cursor.lineNumber = report.lineNumber
                    result.bytesRead += report.bytes; result.filesRead += 1
                    if report.rejectedLines > 0 {
                        result.diagnostics.append(ScanDiagnostic(source: url.path, message: "\(report.rejectedLines) 条记录超过 8 MB，未解析；覆盖范围不完整。"))
                    }
                }
                cursor.inode = inode; cursor.size = size; cursor.modifiedAt = modified
                cursors[url.path] = cursor
                if cursor.stream.malformedRecords > 0 {
                    result.diagnostics.append(ScanDiagnostic(source: url.path, message: "\(cursor.stream.malformedRecords) 条元数据记录格式异常。"))
                }
                if var thread = cursor.stream.thread {
                    thread.rolloutPath = url.path
                    thread.archived = url.path.contains("/archived_sessions/")
                    if let index = thread.turns.indices.max(by: { thread.turns[$0].startedAt < thread.turns[$1].startedAt }) {
                        thread.turns[index].lastActivity = max(thread.turns[index].lastActivity, modified)
                    }
                    merge(thread, into: &records, preferMetadata: false)
                }
            } catch { result.diagnostics.append(ScanDiagnostic(source: url.path, message: error.localizedDescription)) }
        }
        // Keep cached state bounded when files are archived or removed.
        cursors = cursors.filter { existingPaths.contains($0.key) || $0.key.hasPrefix("external:") }
        result.sources?.append(ScanSourceStatus(id: "sessions", title: "会话元数据", path: root.path,
            state: result.diagnostics.count > rolloutDiagnosticStart ? .partial : rolloutURLs.isEmpty ? .missing : .available,
            detail: "\(rolloutURLs.count) 个会话文件 · 支持增量读取"))

        if let history = latestDatabase(children, prefix: "thread_history_") {
            do {
                let db = try ReadOnlySQLite(url: history)
                let columns = try db.columns("thread_turns")
                if columns.isSuperset(of: ["thread_id", "turn_id", "status", "started_at", "completed_at"]) {
                    let rows = try db.query("SELECT thread_id,turn_id,status,started_at,completed_at FROM thread_turns")
                    for row in rows {
                        guard let threadID = row["thread_id"], let turnID = row["turn_id"] else { continue }
                        var record = records[threadID] ?? ThreadRecord(id: threadID)
                        let started = numericDate(row["started_at"])
                        var turn = record.turns.first(where: { $0.id == turnID }) ?? TurnRecord(id: turnID, startedAt: started ?? .distantPast)
                        if let started { turn.startedAt = started }
                        turn.completedAt = numericDate(row["completed_at"])
                        turn.status = statusFromDB(row["status"])
                        turn.lastActivity = max(turn.lastActivity, turn.completedAt ?? .distantPast)
                        record.turns.removeAll { $0.id == turnID }; record.turns.append(turn)
                        records[threadID] = record
                    }
                    result.sources?.append(ScanSourceStatus(id: "turns", title: "轮次状态", path: history.path, state: .available, detail: "\(rows.count) 个轮次"))
                } else {
                    result.diagnostics.append(ScanDiagnostic(source: history.path, message: "轮次数据库结构不受支持；使用会话事件判断状态。"))
                    result.sources?.append(ScanSourceStatus(id: "turns", title: "轮次状态", path: history.path, state: .partial, detail: "使用会话事件补充状态"))
                }
            } catch {
                result.diagnostics.append(ScanDiagnostic(source: history.path, message: error.localizedDescription))
                result.sources?.append(ScanSourceStatus(id: "turns", title: "轮次状态", path: history.path, state: .unreadable, detail: "数据库读取失败"))
            }
        } else {
            result.sources?.append(ScanSourceStatus(id: "turns", title: "轮次状态", path: root.path, state: .missing, detail: "使用会话事件判断状态"))
        }
        if let logs = latestDatabase(children, prefix: "logs_") { scanLogs(logs, result: &result) }
        else { result.sources?.append(ScanSourceStatus(id: "transport", title: "通信日志", path: root.path, state: .missing, detail: "没有可访问的日志数据库")) }
        result.requests = requests.values.sorted { $0.timestamp > $1.timestamp }
        if let desktop = configuration.desktopLogs {
            scanExternalFolder(desktop, suffix: "log", isDesktop: true, result: &result)
        } else {
            result.sources?.append(ScanSourceStatus(id: "desktop", title: "桌面客户端日志", path: "", state: .disabled, detail: "可在检测设置中启用"))
        }
        if let imported = configuration.importedEvidence {
            scanExternalFolder(imported, suffix: "jsonl", isDesktop: false, result: &result)
        }
        for external in externalEvidence.values { merge(external, into: &records, preferMetadata: false) }
        let evaluatedAt = now.addingTimeInterval(Date().timeIntervalSince(begin))
        for (id, var thread) in records {
            for index in thread.turns.indices {
                // In-progress records survive crashes. Fresh events plus a live client are the
                // only basis for the running badge; an older unclosed turn stays unconfirmed.
                if thread.turns[index].isOpen {
                    let freshness = evaluatedAt.timeIntervalSince(thread.turns[index].lastActivity)
                    thread.turns[index].status = clientIsRunning && freshness >= -30 && freshness < 180 ? .running : .unconfirmed
                }
                let deduplicated = Dictionary(thread.turns[index].evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                thread.turns[index].evidence = deduplicated.values.sorted { $0.timestamp < $1.timestamp }
            }
            thread.turns.sort { $0.startedAt > $1.startedAt }
            records[id] = thread
        }
        result.threads = records.values.sorted { $0.updatedAt > $1.updatedAt }
        result.scannedAt = evaluatedAt
        result.duration = Date().timeIntervalSince(begin)
        return result
    }

    private func scanLogs(_ url: URL, result: inout ScanResult) {
        do {
            let db = try ReadOnlySQLite(url: url)
            let columns = try db.columns("logs")
            guard columns.isSuperset(of: ["id", "ts", "target", "feedback_log_body"]) else {
                throw SQLiteReadError.query("日志数据库缺少必要字段")
            }
            let inode = (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
            if logDatabasePath != url.path || logDatabaseInode != inode {
                lastLogID = 0; cachedLogCoverage = nil; logDatabasePath = url.path; logDatabaseInode = inode
            }
            let maxID = Int64(try db.query("SELECT max(id) AS value FROM logs").first?["value"] ?? "0") ?? 0
            if maxID < lastLogID { lastLogID = 0; cachedLogCoverage = nil }
            // Counting every log row is expensive. Coverage is a dated snapshot, refreshed at
            // most every five minutes; incoming transport evidence still uses the ID cursor.
            if cachedLogCoverage == nil || Date().timeIntervalSince(cachedLogCoverage!.scannedAt) >= 300 {
                let coverage = try db.query("SELECT count(*) AS rows,min(ts) AS oldest,max(ts) AS newest FROM logs").first ?? [:]
                cachedLogCoverage = LogCoverage(source: url.path, oldest: numericDate(coverage["oldest"]),
                    newest: numericDate(coverage["newest"]), rowCount: Int(coverage["rows"] ?? "0") ?? 0, scannedAt: Date())
            }
            result.logCoverage = cachedLogCoverage
            let fields = ["id", "ts", "ts_nanos", "target", "thread_id", "process_uuid", "feedback_log_body"].filter { columns.contains($0) }.joined(separator: ",")
            let modelSQL = """
                SELECT \(fields) FROM logs WHERE id > \(lastLogID) AND id <= \(maxID)
                AND target IN ('codex_core::session','codex_core::codex')
                AND feedback_log_body LIKE '%server reported model %' ORDER BY id
                """
            for row in try db.query(modelSQL) {
                guard let body = row["feedback_log_body"], let target = row["target"], let date = numericDate(row["ts"]) else { continue }
                let precise = date.addingTimeInterval((Double(row["ts_nanos"] ?? "0") ?? 0) / 1_000_000_000)
                if let thread = ServerModelLogParser.parse(body: body, target: target, threadID: row["thread_id"],
                    timestamp: precise, source: url.path, locator: "row:\(row["id"] ?? "?")") {
                    merge(thread, into: &externalEvidence, preferMetadata: false)
                }
            }
            let transportSQL = """
                SELECT \(fields) FROM logs WHERE id > \(lastLogID) AND id <= \(maxID)
                AND (target = 'codex_http_client::client' OR target IN ('codex_api::sse','codex_api::endpoint::responses','codex_core::stream_events_utils'))
                AND (feedback_log_body LIKE '%Request completed%' OR feedback_log_body LIKE '%Request failed%'
                     OR feedback_log_body LIKE '%stream error%' OR feedback_log_body LIKE '%SSE error%' OR feedback_log_body LIKE '%SSE event:%')
                ORDER BY id
                """
            for row in try db.query(transportSQL) {
                guard let body = row["feedback_log_body"], let target = row["target"],
                      let date = numericDate(row["ts"]) else { continue }
                let preciseDate = date.addingTimeInterval((Double(row["ts_nanos"] ?? "0") ?? 0) / 1_000_000_000)
                if let request = TransportLogParser.parse(body: body, target: target, threadID: row["thread_id"],
                    timestamp: preciseDate, source: url.path, locator: "row:\(row["id"] ?? "?")", processID: row["process_uuid"] ?? "") {
                    requests[request.id] = request
                    if let model = request.reportedModel, let id = request.threadID, let turnID = request.turnID {
                        var record = ThreadRecord(id: id)
                        var turn = TurnRecord(id: turnID, startedAt: preciseDate)
                        turn.evidence = request.headers.keys.sorted().filter { ["openai-model", "x-openai-model"].contains($0) }.map {
                            ModelEvidence(kind: .responseHeader, model: request.headers[$0] ?? model,
                                timestamp: preciseDate, source: url.path, locator: request.locator,
                                responseID: request.requestID, field: $0)
                        }
                        record.turns = [turn]; merge(record, into: &externalEvidence, preferMetadata: false)
                    }
                }
            }
            // Whitelisted internal transport targets only. Tool calls and feedback tags can contain
            // arbitrary user text, so those are never eligible as model evidence.
            let sql = """
                SELECT \(fields) FROM logs WHERE id > \(lastLogID) AND id <= \(maxID)
                AND (target LIKE 'codex_api::%' OR target IN ('codex_core::stream_events_utils','tungstenite::protocol'))
                AND (feedback_log_body LIKE '%model/rerouted%' OR feedback_log_body LIKE '%model_rerout%'
                     OR feedback_log_body LIKE '%response.created%' OR feedback_log_body LIKE '%response.completed%' OR feedback_log_body LIKE '%response.metadata%'
                     OR feedback_log_body LIKE '%model/safetyBuffering/updated%')
                ORDER BY id
                """
            for row in try db.query(sql) {
                guard let body = row["feedback_log_body"], let target = row["target"], let date = numericDate(row["ts"]),
                      let stream = TransportEventParser.parse(body: body, target: target, threadID: row["thread_id"],
                        timestamp: date, source: url.path, locator: "row:\(row["id"] ?? "?")") else { continue }
                if let thread = stream.thread, !thread.turns.isEmpty { merge(thread, into: &externalEvidence, preferMetadata: false) }
                if stream.unassociatedRecords > 0 {
                    result.diagnostics.append(ScanDiagnostic(source: url.path, message: "发现未提供任务或轮次 ID 的模型事件，未关联到任何任务。"))
                }
            }
            lastLogID = maxID
            result.sources?.append(ScanSourceStatus(id: "transport", title: "通信日志", path: url.path, state: .available,
                detail: "\(result.logCoverage?.rowCount ?? 0) 行 · \(requests.count) 条可识别通信记录"))
        } catch {
            result.diagnostics.append(ScanDiagnostic(source: url.path, message: error.localizedDescription))
            result.sources?.append(ScanSourceStatus(id: "transport", title: "通信日志", path: url.path, state: .unreadable, detail: "数据库读取失败"))
        }
    }

    private func scanExternalFolder(_ folder: URL, suffix: String, isDesktop: Bool, result: inout ScanResult) {
        let start = result.diagnostics.count
        let exists = FileManager.default.fileExists(atPath: folder.path)
        let files = enumerate(folder, suffix: suffix, diagnostics: &result.diagnostics)
        for url in files {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let modified = attributes[.modificationDate] as? Date ?? .distantPast
                let key = "external:" + url.path
                var cursor = cursors[key] ?? FileCursor()
                if cursor.inode != inode || size < cursor.offset || (size == cursor.size && modified != cursor.modifiedAt) { cursor = FileCursor() }
                if size == cursor.size && modified == cursor.modifiedAt && cursors[key] != nil { continue }
                let report = try LineReader.read(url: url, offset: cursor.offset, lineNumber: cursor.lineNumber) { data, line in
                    var candidate = data
                    if isDesktop {
                        let header = String(decoding: data.prefix(1024), as: UTF8.self)
                        guard header.contains("rerouted") || header.contains("response.created") || header.contains("response.completed") || header.contains("response.metadata") || header.contains("model/safetyBuffering/updated"),
                              header.contains("[app-server") || header.contains("[model-routing") || header.contains("[codex-api") else { return }
                        let text = String(decoding: data, as: UTF8.self)
                        guard let start = text.firstIndex(of: "{") else { return }
                        candidate = Data(text[start...].utf8)
                    }
                    var stream = ParsedStream()
                    stream.consume(candidate, source: url.path, locator: "line:\(line)")
                    if let thread = stream.thread { merge(thread, into: &externalEvidence, preferMetadata: false) }
                    if stream.malformedRecords > 0 || stream.unassociatedRecords > 0 {
                        result.diagnostics.append(ScanDiagnostic(source: url.path, message: "第 \(line) 行缺少有效结构或明确关联 ID，未作为证据使用。"))
                    }
                }
                cursor.offset = report.offset; cursor.lineNumber = report.lineNumber
                cursor.inode = inode; cursor.size = size; cursor.modifiedAt = modified
                cursors[key] = cursor; result.bytesRead += report.bytes; result.filesRead += 1
                if report.rejectedLines > 0 {
                    result.diagnostics.append(ScanDiagnostic(source: url.path, message: "跳过 \(report.rejectedLines) 条超大记录；覆盖范围不完整。"))
                }
            } catch { result.diagnostics.append(ScanDiagnostic(source: url.path, message: error.localizedDescription)) }
        }
        result.sources?.append(ScanSourceStatus(id: isDesktop ? "desktop" : "imports", title: isDesktop ? "桌面客户端日志" : "外部模型证据",
            path: folder.path, state: !exists ? .missing : result.diagnostics.count > start ? .partial : .available,
            detail: !exists ? (isDesktop ? "日志目录不存在" : "尚未导入") : "\(files.count) 个文件"))
    }
}

private func latestDatabase(_ children: [URL], prefix: String) -> URL? {
    children.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite" }
        .max { lhs, rhs in
            let left = Int(lhs.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)) ?? 0
            let right = Int(rhs.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)) ?? 0
            return left < right
        }
}

private func numericDate(_ value: String?) -> Date? {
    guard let value, let number = Double(value) else { return nil }
    return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
}

private func statusFromDB(_ value: String?) -> TurnStatus {
    switch value {
    case "inProgress", "in_progress": .running
    case "completed": .completed
    case "interrupted": .interrupted
    case "failed": .failed
    default: .unknown
    }
}

private func isInside(_ url: URL, root: URL) -> Bool {
    url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
}

private func enumerate(_ directory: URL, suffix: String, diagnostics: inout [ScanDiagnostic]) -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    var errors: [ScanDiagnostic] = []
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                    options: [.skipsHiddenFiles], errorHandler: { url, error in
        errors.append(ScanDiagnostic(source: url.path, message: error.localizedDescription)); return true
    })
    var urls: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            enumerator?.skipDescendants(); continue
        }
        if url.pathExtension == suffix && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { urls.append(url) }
    }
    diagnostics.append(contentsOf: errors)
    return urls
}

private func merge(_ incoming: ThreadRecord, into records: inout [String: ThreadRecord], preferMetadata: Bool) {
    guard var existing = records[incoming.id] else { records[incoming.id] = incoming; return }
    existing.turns = HistoryStore.mergeTurns(existing.turns, incoming.turns)
    existing.updatedAt = max(existing.updatedAt, incoming.updatedAt)
    if existing.cwd.isEmpty { existing.cwd = incoming.cwd }
    if existing.provider.isEmpty { existing.provider = incoming.provider }
    if existing.title == "未命名任务" || preferMetadata { existing.title = incoming.title }
    existing.parentID = existing.parentID ?? incoming.parentID
    existing.rolloutPath = incoming.rolloutPath ?? existing.rolloutPath
    existing.selectedModel = existing.selectedModel ?? incoming.selectedModel
    if incoming.archived { existing.archived = true }
    records[incoming.id] = existing
}
