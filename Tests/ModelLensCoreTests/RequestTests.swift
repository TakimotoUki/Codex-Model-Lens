import Testing
import Foundation
import CSQLite
@testable import ModelLensCore

@Suite("Transport evidence, privacy and migration")
struct RequestTests {
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    var span: String { "session_loop{thread_id=task-A}:turn{thread.id=task-A turn.id=turn-1 model=gpt-6-astra}: " }
    var response: String {
        span + #"Request completed method=POST url=https://chatgpt.com/backend-api/codex/responses status=200 OK headers={"x-oai-request-id": "req-1", "x-codex-safety-buffering-enabled": "true", "x-codex-safety-buffering-faster-model": "gpt-6-luna", "Authorization": "Bearer SECRET", "set-cookie": "PRIVATE_COOKIE"}"#
    }
    func parse(_ body: String, target: String = "codex_http_client::client", thread: String? = "task-A") -> RequestRecord? {
        TransportLogParser.parse(body: body, target: target, threadID: thread, timestamp: date, source: "/fixture/logs_2.sqlite", locator: "row:1")
    }

    @Test func responseHeadersAreAssociatedAndSanitized() throws {
        let r = try #require(parse(response))
        #expect(r.threadID == "task-A" && r.turnID == "turn-1")
        #expect(r.requestedModel == "gpt-6-astra")
        #expect(r.fasterModel == "gpt-6-luna" && r.isBuffering)
        #expect(r.requestID == "req-1" && r.httpStatus == 200)
        #expect(r.headers.count == 3 && !r.isError)
        let stored = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!stored.contains("SECRET") && !stored.contains("PRIVATE_COOKIE"))
        #expect(!stored.contains("backend-api"))
    }

    @Test func userQuotesUnrelatedEndpointsAndMismatchedIDsAreRejected() {
        #expect(parse(response, target: "codex_core::session::handlers") == nil)
        #expect(parse(response.replacingOccurrences(of: "/responses", with: "/analytics-events/events")) == nil)
        #expect(parse(response, thread: "other-task") == nil)
        #expect(parse("UserInput: " + response) == nil)
    }

    @Test func capacityAndOverloadAreDistinctAndSuccessfulBodyCannotFakeError() throws {
        let failure = span + #"stream error {"error":{"code":"server_is_overloaded","message":"Model at capacity"}} request_id=req-2"#
        let r = try #require(parse(failure, target: "codex_api::sse"))
        #expect(r.isError && r.isOverloaded && r.capacityMessage)
        #expect(r.requestID == "req-2")
        let normal = try #require(parse(response + #" body={"code":"server_is_overloaded","message":"at capacity"}"#))
        #expect(!normal.isError && !normal.capacityMessage)
        let s = RequestSummary([r, r, normal])
        #expect(s.rows == 3 && s.identifiedRequests == 2)
        #expect(s.capacityRows == 2 && s.overloadedRows == 2)
    }

    @Test func safetyEventNeverBecomesDeliveryModel() throws {
        let event: [String: Any] = ["method": "model/safetyBuffering/updated", "timestamp": "2026-09-30T09:00:00Z",
            "params": ["threadId": "task-A", "turnId": "turn-1", "model": "gpt-6-astra", "fasterModel": "gpt-6-luna", "showBufferingUi": true]]
        var stream = ParsedStream()
        stream.consume(try JSONSerialization.data(withJSONObject: event), source: "/fixture", locator: "line:1")
        let turn = try #require(stream.thread?.latestTurn)
        #expect(turn.safetyEvidence.first?.fasterModel == "gpt-6-luna")
        #expect(turn.reportedModel == nil && !turn.hasModelDifference)
    }

    @Test func networkFailureWithoutHTTPStatusIsStillAnError() throws {
        let r = try #require(parse(span + "Request failed method=POST url=https://chatgpt.com/backend-api/codex/responses error=error sending request"))
        #expect(r.httpStatus == nil && r.requestID == nil)
        #expect(r.isError && r.failureReported == true)
        #expect(r.statusLabel == "请求失败")
        let summary = RequestSummary([r])
        #expect(summary.errorRows == 1 && summary.unidentifiedRows == 1)
    }

    @Test func legacyHistoryMigratesAndRequestEvidenceSurvivesPruning() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var archive = HistoryArchive(); archive.threads = [ThreadRecord(id: "legacy", title: "旧记录")]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        object["schemaVersion"] = 1; object.removeValue(forKey: "requests"); object.removeValue(forKey: "logCoverage")
        let file = directory.appendingPathComponent("history.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let old = try HistoryStore.load(from: file)
        #expect(old.schemaVersion == 1 && old.requestRecords.isEmpty)
        let r = try #require(parse(response))
        let merged = HistoryStore.merge(ScanResult(requests: [r]), into: old)
        let repeated = HistoryStore.merge(ScanResult(requests: [r]), into: merged)
        let pruned = HistoryStore.merge(ScanResult(), into: repeated)
        #expect(pruned.schemaVersion == 2 && pruned.threads.first?.title == "旧记录")
        #expect(pruned.requestRecords == [r])
        try HistoryStore.save(pruned, to: file)
        #expect(try HistoryStore.load(from: file).requestRecords == [r])
        let csv = HistoryStore.exportRequestsCSV([r])
        #expect(csv.contains("req-1") && csv.contains("gpt-6-luna") && !csv.contains("SECRET"))
    }

    @Test func removedTasksAndTheirRequestsStayRemovedAfterRescan() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let record = try #require(parse(response))
        let scan = ScanResult(threads: [ThreadRecord(id: "task-A"), ThreadRecord(id: "keep")], requests: [record])
        let original = HistoryStore.merge(scan, into: HistoryArchive())
        let removed = HistoryStore.removingThreads(["task-A"], from: original)
        let file = directory.appendingPathComponent("history.json")
        try HistoryStore.save(removed, to: file)
        let repeated = HistoryStore.merge(scan, into: try HistoryStore.load(from: file))
        #expect(repeated.threads.map(\.id) == ["keep"])
        #expect(repeated.requestRecords.isEmpty)
        #expect(repeated.removedThreadIDs == ["task-A"])
    }

    @Test func databaseScanningIsIncrementalAndRejectsChatHits() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("logs_2.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE logs(id INTEGER PRIMARY KEY,ts INTEGER,target TEXT,thread_id TEXT,feedback_log_body TEXT)", nil, nil, nil) == SQLITE_OK)
        func insert(_ id: Int, target: String) {
            let body = response.replacingOccurrences(of: "'", with: "''")
            let sql = "INSERT INTO logs VALUES(\(id),1790000000,'\(target)','task-A','\(body)')"
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        insert(1, target: "codex_http_client::client"); insert(2, target: "codex_core::session::handlers")
        let scanner = CodexScanner(configuration: ScannerConfiguration(codexHome: directory))
        let first = await scanner.scan()
        #expect(first.requests.count == 1 && first.logCoverage?.rowCount == 2)
        #expect(first.threads.isEmpty)
        #expect(await scanner.scan().requests.count == 1)
        insert(3, target: "codex_http_client::client")
        let next = await scanner.scan()
        #expect(next.requests.count == 2 && RequestSummary(next.requests).identifiedRequests == 1)
        #expect(next.logCoverage?.oldest == date)
    }

    @Test func importedSafetyEventRemainsDiagnosticAndDropsPrivateFields() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let event: [String: Any] = ["method": "model/safetyBuffering/updated", "prompt": "PRIVATE_PROMPT",
            "params": ["threadId": "task-A", "turnId": "turn-1", "model": "gpt-6-astra", "fasterModel": "gpt-6-luna", "showBufferingUi": true, "token": "SECRET"]]
        #expect(try await EvidenceImporter.importFile(JSONSerialization.data(withJSONObject: event), sourceName: "event.json", to: directory) == 1)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("SECRET") && !text.contains("PRIVATE_PROMPT"))
        var stream = ParsedStream(); stream.consume(data, source: "import", locator: "line:1")
        #expect(stream.thread?.latestTurn?.safetyEvidence.count == 1)
        #expect(stream.thread?.latestTurn?.reportedModel == nil)
    }
}
