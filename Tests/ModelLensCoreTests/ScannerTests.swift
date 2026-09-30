import Testing
import Foundation
import CSQLite
@testable import ModelLensCore

func fixtureDirectory() throws -> URL {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = project.appendingPathComponent("Data/TestRuns/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeLines(_ lines: [[String: Any]], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = Data()
    for line in lines { data.append(try JSONSerialization.data(withJSONObject: line)); data.append(10) }
    try data.write(to: url)
}

@Suite("Incremental scanner and storage")
struct ScannerTests {
    func lines(id: String, turnID: String, date: Date) -> [[String: Any]] {
        let stamp = ISO8601DateFormatter().string(from: date)
        return [
            ["type": "session_meta", "timestamp": stamp, "payload": ["id": id]],
            ["type": "event_msg", "timestamp": stamp, "payload": ["type": "task_started", "turn_id": turnID]],
            ["type": "turn_context", "timestamp": stamp, "payload": ["turn_id": turnID, "model": "gpt-6-astra"]]
        ]
    }

    @Test func multipleLiveTasksAndIncrementalAppend() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), file = directory.appendingPathComponent("sessions/a.jsonl")
        try writeLines(lines(id: "a", turnID: "a1", date: now), to: file)
        try writeLines(lines(id: "b", turnID: "b1", date: now), to: directory.appendingPathComponent("sessions/b.jsonl"))
        let scanner = CodexScanner(configuration: ScannerConfiguration(codexHome: directory))
        let first = await scanner.scan(now: now)
        #expect(first.threads.filter(\.isRunning).count == 2)
        #expect(first.threads.allSatisfy { !$0.hasServerEvidence })
        let unchanged = await scanner.scan(now: now)
        #expect(unchanged.bytesRead == 0)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        let finish: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now), "payload": ["type": "task_complete", "turn_id": "a1"]]
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: finish)); try handle.write(contentsOf: Data([10])); try handle.close()
        let updated = await scanner.scan(now: now)
        #expect(updated.threads.first(where: { $0.id == "a" })?.latestTurn?.status == .completed)
        #expect(updated.threads.filter(\.isRunning).count == 1)
    }

    @Test func inactiveClientAndOldOpenTurnStayUnconfirmed() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), file = directory.appendingPathComponent("sessions/a.jsonl")
        try writeLines(lines(id: "a", turnID: "a1", date: now.addingTimeInterval(-1000)), to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1000)], ofItemAtPath: file.path)
        let scanner = CodexScanner(configuration: ScannerConfiguration(codexHome: directory))
        #expect(await scanner.scan(now: now).threads.first?.latestTurn?.status == .unconfirmed)
        #expect(await scanner.scan(now: now.addingTimeInterval(-950), clientIsRunning: false).threads.first?.latestTurn?.status == .unconfirmed)
    }

    @Test func partialTailAndFileReplacement() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(), file = directory.appendingPathComponent("sessions/a.jsonl")
        try writeLines(lines(id: "a", turnID: "a1", date: now), to: file)
        let scanner = CodexScanner(configuration: ScannerConfiguration(codexHome: directory))
        _ = await scanner.scan(now: now)
        let route: [String: Any] = ["method": "model/rerouted", "params": ["threadId": "a", "turnId": "a1", "fromModel": "gpt-6-astra", "toModel": "gpt-5.6-luna"]]
        let data = try JSONSerialization.data(withJSONObject: route)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: data.prefix(data.count / 2))
        #expect(await scanner.scan(now: now).threads.first?.hasServerEvidence == false)
        try handle.write(contentsOf: data.suffix(data.count - data.count / 2)); try handle.write(contentsOf: Data([10])); try handle.close()
        #expect(await scanner.scan(now: now).threads.first?.hasModelDifference == true)
        try writeLines(lines(id: "replacement", turnID: "r1", date: now), to: file)
        let replaced = await scanner.scan(now: now)
        #expect(replaced.threads.first?.id == "replacement")
        #expect(replaced.threads.first?.hasServerEvidence == false)
    }

    @Test func futureDatabaseSchemaFallsBackToLogs() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.appendingPathComponent("state_9.sqlite").path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO threads VALUES ('a','=formula-title')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        try writeLines(lines(id: "a", turnID: "a1", date: Date()), to: directory.appendingPathComponent("sessions/a.jsonl"))
        let result = await CodexScanner(configuration: ScannerConfiguration(codexHome: directory)).scan()
        #expect(result.threads.first?.title == "=formula-title")
        #expect(result.threads.first?.latestTurn?.recordedModel == "gpt-6-astra")
        let csv = HistoryStore.exportCSV(result.threads)
        #expect(csv.contains("'=formula-title"))
    }

    @Test func historyPreservesEvidenceAfterSourceDisappearsAndDeduplicates() throws {
        var thread = ThreadRecord(id: "a")
        var turn = TurnRecord(id: "a1", startedAt: Date(), status: .running)
        turn.evidence = [ModelEvidence(kind: .reroute, model: "gpt-5.6-luna", fromModel: "gpt-6-astra", timestamp: Date(), source: "/fixture", locator: "line:4")]
        thread.turns = [turn]
        let result = ScanResult(threads: [thread])
        let initial = HistoryStore.merge(result, into: HistoryArchive())
        let repeated = HistoryStore.merge(result, into: initial)
        #expect(repeated.threads[0].turns[0].evidence.count == 1)
        let removed = HistoryStore.merge(ScanResult(), into: repeated)
        #expect(removed.threads.count == 1)
        #expect(removed.threads[0].turns[0].status == .unconfirmed)
        #expect(removed.threads[0].hasModelDifference)
    }

    @Test func historyRoundTripAndCorruptFileIsPreserved() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        var archive = HistoryArchive(); archive.threads = [ThreadRecord(id: "a", title: "保存测试")]
        try HistoryStore.save(archive, to: file)
        #expect(try HistoryStore.load(from: file).threads == archive.threads)
        let corrupted = Data("invalid-json".utf8); try corrupted.write(to: file)
        #expect(throws: (any Error).self) { try HistoryStore.load(from: file) }
        #expect(try Data(contentsOf: file) == corrupted)
    }

    @Test func importerSanitizesPrivateBodiesAndRequiresIdentity() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let object: [String: Any] = ["type": "response.completed", "thread_id": "a", "turn_id": "a1", "headers": ["Authorization": "SECRET"],
                                  "response": ["id": "resp_demo", "object": "response", "model": "gpt-5.6-luna", "output": ["PRIVATE_PROMPT"]]]
        let count = try await EvidenceImporter.importFile(JSONSerialization.data(withJSONObject: object), sourceName: "fixture.json", to: directory)
        #expect(count == 1)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let sanitized = try String(contentsOf: file, encoding: .utf8)
        #expect(!sanitized.contains("SECRET"))
        #expect(!sanitized.contains("PRIVATE_PROMPT"))
        #expect(sanitized.contains("gpt-5.6-luna"))
        let result = await CodexScanner(configuration: ScannerConfiguration(codexHome: directory, importedEvidence: directory)).scan()
        #expect(result.threads.first?.latestTurn?.reportedModel == "gpt-5.6-luna")
    }

    @Test func missingDirectoryIsDiagnosticNotSuccess() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let result = await CodexScanner(configuration: ScannerConfiguration(codexHome: directory.appendingPathComponent("missing"))).scan()
        #expect(result.threads.isEmpty)
        #expect(!result.diagnostics.isEmpty)
    }

    @Test func scannerIncludesCumulativeTokenEvents() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var values = lines(id: "a", turnID: "a1", date: Date())
        values.append(["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "cached_input_tokens": 25, "output_tokens": 10, "total_tokens": 110]]]])
        try writeLines(values, to: directory.appendingPathComponent("sessions/a.jsonl"))
        let value = await CodexScanner(configuration: ScannerConfiguration(codexHome: directory)).scan()
        #expect(value.threads.first?.latestTurn?.tokenUsage?.total == 110)
    }

}
