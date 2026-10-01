import Testing
import Foundation
@testable import ModelLensCore

@Suite("Desktop routing projection and server model logs")
struct DesktopModelTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var item: [String: Any] { ["id": "route-1", "type": "modelRerouted", "fromModel": "gpt-6-astra", "toModel": "gpt-5.6-luna", "reason": "highRiskCyberActivity"] }
    var turn: [String: Any] { ["turnId": "turn-1", "params": ["threadId": "task-1", "model": "gpt-6-astra", "input": "PRIVATE_PROMPT"], "turnStartedAtMs": now.timeIntervalSince1970 * 1000, "items": [item]] }
    func envelope(_ change: [String: Any], thread: String = "task-1", owner: String = "desktop", version: Int = 11) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "broadcast", "sourceClientId": owner, "method": "thread-stream-state-changed", "version": version,
            "params": ["conversationId": thread, "hostId": "local", "change": change]])
    }
    func snapshot(canonical: Bool = true, value: [String: Any]? = nil) throws -> Data {
        var cs: [String: Any] = ["id": "task-1", "latestModel": "gpt-6-astra"]
        if canonical { cs["turnHistory"] = ["kind": "canonical", "history": ["entitiesByKey": ["tail:0:local:key": value ?? turn], "islands": []]] }
        else { cs["turns"] = [value ?? turn] }
        return try envelope(["type": "snapshot", "revision": 4, "conversationState": cs])
    }
    @Test func currentCanonicalHistoryAndLegacyTurnsDetectActualRouting() throws {
        for canonical in [true, false] {
            var p = DesktopEvidenceProjection()
            let records = p.consume(try snapshot(canonical: canonical), allowedThreads: ["task-1"], now: now)
            let t = try #require(records.first?.turns.first)
            #expect(t.reportedModel == "gpt-5.6-luna" && t.requestedModel == "gpt-6-astra" && t.hasModelDifference)
            #expect(t.evidence[0].source == "Codex Desktop IPC")
            let stored = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
            #expect(!stored.contains("PRIVATE_PROMPT"))
        }
    }
    @Test func wholeTypedItemPatchUsesExplicitTurnMapping() throws {
        var empty = turn; empty["items"] = []
        var p = DesktopEvidenceProjection()
        #expect(p.consume(try snapshot(value: empty), allowedThreads: ["task-1"]).isEmpty)
        let data = try envelope(["type": "patches", "baseRevision": 4, "revision": 5, "patches": [
            ["op": "add", "path": ["turnHistory", "history", "entitiesByKey", "tail:0:local:key", "items", 1] as [Any], "value": item]]])
        #expect(p.consume(data, allowedThreads: ["task-1"]).first?.turns.first?.id == "turn-1")
    }
    @Test func toolOutputAndRequestedModelsCannotBecomeServerEvidence() throws {
        var fake = turn
        fake["items"] = [["type": "mcpToolCall", "id": "call", "result": item], ["type": "agentMessage", "id": "message", "text": "modelRerouted gpt-5.6-luna"]]
        var p = DesktopEvidenceProjection()
        #expect(p.consume(try snapshot(value: fake), allowedThreads: ["task-1"]).isEmpty)
        let data = try envelope(["type": "patches", "baseRevision": 4, "revision": 5, "patches": [
            ["op": "add", "path": ["turnHistory", "history", "entitiesByKey", "tail:0:local:key", "items", 0, "result"] as [Any], "value": item]]])
        #expect(p.consume(data, allowedThreads: ["task-1"]).isEmpty)
    }
    @Test func wrongIdentityAndUnsupportedVersionAreRejected() throws {
        var fake = turn; fake["params"] = ["threadId": "other-task", "model": "gpt-6-astra"]
        var p = DesktopEvidenceProjection()
        #expect(p.consume(try snapshot(value: fake), allowedThreads: ["task-1"]).isEmpty)
        #expect(p.consume(try snapshot(), allowedThreads: ["other-task"]).isEmpty)
        let wrong = try envelope(["type": "snapshot", "revision": 1, "conversationState": ["id": "task-1", "turns": [turn]]], version: 12)
        #expect(p.consume(wrong, allowedThreads: ["task-1"]).isEmpty)
    }
    @Test func missingPatchRevisionAndOwnerChangeRequireNewSnapshot() throws {
        var p = DesktopEvidenceProjection()
        _ = p.consume(try snapshot(), allowedThreads: ["task-1"])
        let gap = try envelope(["type": "patches", "baseRevision": 3, "revision": 5, "patches": []])
        #expect(p.consume(gap, allowedThreads: ["task-1"]).isEmpty && p.needsSnapshot == "task-1")
        _ = p.consume(try snapshot(), allowedThreads: ["task-1"])
        let other = try envelope(["type": "patches", "baseRevision": 4, "revision": 5, "patches": []], owner: "another-owner")
        #expect(p.consume(other, allowedThreads: ["task-1"]).isEmpty && p.needsSnapshot == "task-1")
    }
    @Test func liveHistoryDoesNotLoseRunningStatusOrResurrectRemovedTasks() throws {
        var p = DesktopEvidenceProjection()
        let records = p.consume(try snapshot(), allowedThreads: ["task-1"], now: now)
        var current = ThreadRecord(id: "task-1", title: "Original task")
        current.turns = [TurnRecord(id: "turn-1", startedAt: now, status: .running)]
        var other = ThreadRecord(id: "other-task"); other.turns = [TurnRecord(id: "other-turn", startedAt: now, status: .running)]
        var archive = HistoryArchive(); archive.threads = [current, other]
        let merged = HistoryStore.addingEvidence(records + records, to: archive)
        #expect(merged.threads[0].title == "Original task" && merged.threads[0].turns[0].isOpen)
        #expect(merged.threads[1].isRunning && merged.threads[0].turns[0].serverEvidence.count == 1)
        archive.removedThreadIDs = ["task-1"]
        #expect(HistoryStore.addingEvidence(records, to: archive).threads[0].turns[0].serverEvidence.isEmpty)
    }
    @Test func sameAndDifferentServerModelLogsArePositiveEvidence() throws {
        let prefix = "session_loop{thread_id=task-1}:turn{turn.id=turn-1 model=gpt-6-astra}: "
        for message in ["server reported model gpt-6-astra (matches requested model)", "server reported model gpt-5.6-luna while requested model was gpt-6-astra"] {
            let record = try #require(ServerModelLogParser.parse(body: prefix + message, target: "codex_core::session", threadID: "task-1", timestamp: now, source: "logs", locator: "row:1"))
            #expect(record.turns[0].serverEvidence.count == 1 && record.turns[0].evidence[0].kind == .serverModel)
        }
    }
    @Test func serverModelLogRejectsQuotesWrongTargetAndMissingTurn() {
        let message = "server reported model gpt-5.6-luna (matches requested model)"
        let span = "session_loop{thread_id=task-1}:turn{turn.id=turn-1}: "
        func parse(_ body: String, _ target: String = "codex_core::session", _ id: String? = "task-1") -> ThreadRecord? {
            ServerModelLogParser.parse(body: body, target: target, threadID: id, timestamp: now, source: "logs", locator: "row:1")
        }
        #expect(parse(span + message, "codex_core::session::handlers") == nil)
        #expect(parse(span + "UserInput: " + message) == nil)
        #expect(parse(span + message, "codex_core::session", "wrong-task") == nil)
        #expect(parse("session_loop{thread_id=task-1}: " + message) == nil)
        #expect(parse(span + message + " PRIVATE_BODY") == nil)
    }
}
