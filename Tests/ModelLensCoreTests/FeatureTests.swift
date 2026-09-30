import Testing
import Foundation
@testable import ModelLensCore

@Suite("Wire models, account usage and timer reliability")
struct FeatureTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func wire(_ object: [String: Any]) throws -> String {
        "2026-09-30 TRACE tungstenite::protocol: Received message " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func report(_ parser: WireProbeParser, exit: Int32 = 0, timeout: Bool = false) -> ModelProbeReport {
        ModelProbeReport(requestedModel: "gpt-6-astra", testedAt: now, duration: 1, exitCode: exit, timedOut: timeout,
                         frames: parser.frames, errorEvents: parser.errors, responses: parser.responses)
    }
    @Test func metadataHeaderSupportsArrayAndCase() throws {
        let object: [String: Any] = ["type": "response.metadata", "response_id": "resp_A", "thread_id": "task", "turn_id": "turn",
            "headers": ["OpenAI-Model": ["gpt-5.6-luna"], "authorization": "SECRET"]]
        var stream = ParsedStream(); stream.consume(try JSONSerialization.data(withJSONObject: object), source: "test", locator: "1")
        let evidence = try #require(stream.thread?.latestTurn?.serverEvidence.first)
        #expect(evidence.kind == .responseHeader && evidence.field == "openai-model")
        #expect(evidence.model == "gpt-5.6-luna" && evidence.responseID == "resp_A")
        #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("SECRET"))
    }
    @Test func transportSpanAssociatesTheIncomingResponse() throws {
        let body = #"session_loop{thread_id=task}:turn{turn.id=turn model=gpt-6-astra}: SSE event: {"type":"response.created","response":{"id":"resp_A","model":"gpt-5.6-luna"}}"#
        let stream = try #require(TransportEventParser.parse(body: body, target: "codex_api::sse", threadID: "task", timestamp: now, source: "test", locator: "1"))
        #expect(stream.thread?.latestTurn?.reportedModel == "gpt-5.6-luna")
        #expect(TransportEventParser.parse(body: body, target: "codex_api::sse", threadID: "other", timestamp: now, source: "test", locator: "1") == nil)
        #expect(TransportEventParser.parse(body: body, target: "codex_core::session::handlers", threadID: "task", timestamp: now, source: "test", locator: "1") == nil)
        let outgoing = body.replacingOccurrences(of: "SSE event: ", with: "Sending frame ")
        #expect(TransportEventParser.parse(body: outgoing, target: "tungstenite::protocol", threadID: "task", timestamp: now, source: "test", locator: "1") == nil)
    }
    @Test func responseWithoutTurnCannotBeAttachedByTime() throws {
        let stream = try #require(TransportEventParser.parse(body: #"Received message {"type":"response.completed","response":{"id":"resp_A","model":"gpt-6-astra"}}"#,
            target: "tungstenite::protocol", threadID: "task", timestamp: now, source: "test", locator: "1"))
        #expect(stream.thread?.turns.isEmpty == true && stream.unassociatedRecords == 1)
    }
    @Test func headerImportRetainsProvenanceAndDropsBody() async throws {
        let dir = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let object: [String: Any] = ["type": "response.completed", "thread_id": "task", "turn_id": "turn",
            "response": ["id": "resp_A", "headers": ["x-openai-model": "gpt-6-astra", "authorization": "SECRET"], "output": ["PRIVATE"]]]
        #expect(try await EvidenceImporter.importFile(JSONSerialization.data(withJSONObject: object), sourceName: "fixture", to: dir) == 1)
        let file = try #require(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: file); let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("x-openai-model") && !text.contains("SECRET") && !text.contains("PRIVATE"))
        var stream = ParsedStream(); stream.consume(data, source: file.path, locator: "1")
        #expect(stream.thread?.latestTurn?.serverEvidence.first?.kind == .responseHeader)
    }
    @Test func oldEvidenceIDsRemainStable() {
        let e = ModelEvidence(kind: .responseModel, model: "gpt-6-astra", timestamp: now, source: "source", locator: "1", responseID: "resp_A")
        #expect(e.id == stableID(["responseModel", "gpt-6-astra", "", "source", "1", "resp_A"].joined(separator: "\u{1f}")))
    }
    @Test func noOutputWarmupCannotConfirmModel() throws {
        var parser = WireProbeParser()
        parser.consume(try wire(["type": "response.completed", "response": ["id": "resp_warm", "model": "gpt-5.6-luna", "status": "completed"]]))
        #expect(!report(parser).isConfirmed && !report(parser).hasDifference)
    }
    @Test func actualOutputIsSeparatedFromWarmup() throws {
        var parser = WireProbeParser()
        parser.consume(try wire(["type": "response.completed", "response": ["id": "resp_warm", "model": "gpt-5.6-luna"]]))
        parser.consume(try wire(["type": "response.created", "response": ["id": "resp_output", "model": "gpt-6-astra"]]))
        parser.consume(try wire(["type": "response.output_text.delta", "response_id": "resp_output", "delta": "PRIVATE_REPLY", "authorization": "SECRET"]))
        parser.consume(try wire(["type": "response.completed", "response": ["id": "resp_output"]]))
        let result = report(parser)
        #expect(result.isConfirmed && !result.hasDifference && result.deliveredModels == ["gpt-6-astra"])
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("PRIVATE_REPLY") && !json.contains("SECRET"))
        #expect(!report(parser, exit: 1).isConfirmed && !report(parser, timeout: true).isConfirmed)
    }
    @Test func outputModelDifferenceIsDetected() throws {
        var parser = WireProbeParser()
        parser.consume(try wire(["type": "response.completed", "response": ["id": "resp_A", "model": "gpt-5.6-luna", "output": [["type": "message", "content": "PRIVATE"]]]]))
        #expect(report(parser).hasDifference)
    }
    @Test func outgoingAndChatQuotesDoNotConfirmProbe() {
        var parser = WireProbeParser()
        parser.consume(#"Sending frame {"type":"response.completed","response":{"id":"resp_A","model":"gpt-6-astra"}}"#)
        #expect(parser.frames == 0 && parser.responses.isEmpty)
    }
    @Test func boundedLinesHandlesUTF8AndOversizeRecovery() {
        var lines = BoundedLines(); var result: [String] = []
        let value = Data("模型\n第二行\n".utf8)
        lines.append(value.prefix(2)) { result.append($0) }; lines.append(value.dropFirst(2)) { result.append($0) }
        lines.append(Data(repeating: 65, count: 2 * 1024 * 1024 + 1)) { result.append($0) }
        lines.append(Data("\nrecovered\n".utf8)) { result.append($0) }
        #expect(result == ["模型", "第二行", "recovered"])
    }
    @Test func quotasPreferMultipleBucketsAndClamp() {
        let snapshot = AccountSnapshot.parse(account: ["account": ["planType": "pro", "email": "PRIVATE"]], quotas: [
            "rateLimits": ["primary": ["usedPercent": 90]],
            "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 12.5, "windowDurationMins": 300, "resetsAt": 1_790_001_000]],
                "codex_other": ["primary": ["usedPercent": 150], "secondary": ["windowDurationMins": 10080]]]], usage: nil, now: now)
        #expect(snapshot.plan == "pro" && snapshot.buckets.count == 2)
        #expect(snapshot.buckets[0].windows.first?.remainingPercent == 87.5)
        #expect(snapshot.buckets[1].windows.first?.remainingPercent == 0)
        #expect(snapshot.buckets[1].windows.last?.remainingPercent == nil)
        #expect(snapshot.lifetimeTokens == nil && snapshot.todayTokens == nil)
    }
    @Test func accountTokensAreProjectedWithoutCredentials() throws {
        let date = String(ISO8601DateFormatter().string(from: now).prefix(10))
        let snapshot = AccountSnapshot.parse(account: ["account": ["planType": "pro", "email": "PRIVATE"]], quotas: nil,
            usage: ["summary": ["lifetimeTokens": 4000], "dailyUsageBuckets": [["startDate": date, "tokens": 100], ["startDate": "2025-01-01", "tokens": 200]]], now: now)
        #expect(snapshot.lifetimeTokens == 4000 && snapshot.todayTokens == 100)
        #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("PRIVATE"))
    }
    @Test func localTokenRecordsAreCumulativeNotDeltaSum() throws {
        var parser = ParsedStream(); parser.thread = ThreadRecord(id: "task"); parser.currentTurnID = "turn"
        for count in [100, 250] {
            parser.consume(try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": count, "input_tokens": count - 10, "output_tokens": 10]]]]), source: "test", locator: "\(count)")
        }
        #expect(parser.thread?.latestTurn?.tokenUsage?.total == 250)
    }
    @Test func timerPauseResumeAndSleepFinishExactlyOnce() {
        var timer = PomodoroState(); timer.focusMinutes = 2; timer.start(at: now)
        #expect(timer.remaining(at: now.addingTimeInterval(30)) == 90)
        timer.pause(at: now.addingTimeInterval(30)); #expect(timer.remaining(at: now.addingTimeInterval(600)) == 90)
        timer.resume(at: now.addingTimeInterval(600)); #expect(timer.finishIfDue(at: now.addingTimeInterval(700)) == .focus)
        #expect(timer.finishIfDue(at: now.addingTimeInterval(701)) == nil && !timer.isRunning)
    }
    @Test func timerRestCustomDurationsAndRoundTrip() throws {
        var timer = PomodoroState(); timer.focusMinutes = 999; timer.restMinutes = 0; timer.start(.rest, at: now)
        #expect(timer.focusMinutes == 240 && timer.restMinutes == 1 && timer.remaining(at: now) == 60)
        let restored = try JSONDecoder().decode(PomodoroState.self, from: JSONEncoder().encode(timer))
        #expect(restored == timer)
        #expect(restored.remaining(at: now.addingTimeInterval(-1)) == 61)
    }
    @Test func missingSourcesHaveExplicitStatus() async throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let result = await CodexScanner(configuration: ScannerConfiguration(codexHome: directory)).scan()
        #expect(result.sources?.contains(where: { $0.id == "index" && $0.state == .missing }) == true)
        #expect(result.sources?.contains(where: { $0.id == "transport" && $0.state == .missing }) == true)
    }

    @Test func anonymousOutputCannotConfirmPrewarmAndConflictingHeadersStayUnconfirmed() throws {
        var parser = WireProbeParser()
        parser.consume(try wire(["type": "response.created", "response": ["id": "resp_warm", "model": "gpt-6-astra"]]))
        parser.consume(try wire(["type": "response.output_text.delta", "delta": "pong"]))
        parser.consume(try wire(["type": "response.completed", "response": ["id": "resp_warm"]]))
        #expect(!report(parser).isConfirmed)
        var conflict = WireProbeParser()
        conflict.consume(try wire(["type": "response.completed", "response": ["id": "resp_output", "model": "gpt-6-astra", "headers": ["openai-model": "gpt-5.6-luna"], "output": [["type": "message"]]]]))
        #expect(!report(conflict).isConfirmed && report(conflict).deliveredModels.count == 2)
    }

}
