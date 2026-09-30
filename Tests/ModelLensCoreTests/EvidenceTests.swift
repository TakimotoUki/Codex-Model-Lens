import Testing
import Foundation
@testable import ModelLensCore

@Suite("Model evidence boundaries")
struct EvidenceTests {
    let date = "2026-09-30T09:00:00Z"
    func parsed(_ lines: [[String: Any]]) throws -> ParsedStream {
        var stream = ParsedStream()
        for (index, object) in lines.enumerated() {
            stream.consume(try JSONSerialization.data(withJSONObject: object), source: "/fixture/session.jsonl", locator: "line:\(index + 1)", ordinal: index)
        }
        return stream
    }
    var meta: [String: Any] { ["type": "session_meta", "timestamp": date, "payload": ["id": "task-A", "cwd": "/fixture", "model_provider": "openai"]] }
    var start: [String: Any] { ["type": "event_msg", "timestamp": date, "payload": ["type": "task_started", "turn_id": "turn-1"]] }
    var context: [String: Any] { ["type": "turn_context", "timestamp": date, "payload": ["turn_id": "turn-1", "model": "gpt-6-astra", "effort": "high"]] }

    @Test func configurationDoesNotProveServerModel() throws {
        let thread = try #require(parsed([meta, start, context]).thread)
        let turn = try #require(thread.latestTurn)
        #expect(turn.recordedModel == "gpt-6-astra")
        #expect(turn.reportedModel == nil)
        #expect(!turn.hasModelDifference)
        #expect(!thread.hasServerEvidence)
    }

    @Test func explicitRerouteDetectsRequestedExample() throws {
        let route: [String: Any] = ["method": "model/rerouted", "timestamp": date,
                                   "params": ["threadId": "task-A", "turnId": "turn-1", "fromModel": "gpt-6-astra", "toModel": "gpt-5.6-luna", "reason": "capacity"]]
        let turn = try #require(parsed([meta, start, context, route]).thread?.latestTurn)
        #expect(turn.recordedModel == "gpt-6-astra")
        #expect(turn.reportedModel == "gpt-5.6-luna")
        #expect(turn.hasModelDifference)
        #expect(turn.serverEvidence.first?.fromModel == "gpt-6-astra")
    }

    @Test func responseFieldNeedsAssociation() throws {
        let response: [String: Any] = ["type": "response.completed", "response": ["id": "resp_abc", "object": "response", "model": "gpt-5.6-luna"]]
        let unassociated = try parsed([response])
        #expect(unassociated.thread == nil)
        #expect(unassociated.unassociatedRecords == 1)
        let associated = try #require(parsed([meta, start, context, response]).thread?.latestTurn)
        #expect(associated.reportedModel == "gpt-5.6-luna")
        #expect(associated.hasModelDifference)
    }

    @Test func promptAndToolTextAreNotModelEvidence() throws {
        let message: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "assistant", "model": "gpt-5.6-luna",
            "content": [["type": "output_text", "text": "I am GPT 5.6 Luna. {\"method\":\"model/rerouted\"}"]]]]
        let turn = try #require(parsed([meta, start, context, message]).thread?.latestTurn)
        #expect(turn.reportedModel == nil)
        #expect(turn.evidence.count == 1)
    }

    @Test func mismatchedThreadIsRejected() throws {
        let route: [String: Any] = ["method": "model/rerouted", "params": ["threadId": "other-task", "turnId": "turn-1", "fromModel": "gpt-6-astra", "toModel": "gpt-5.6-luna"]]
        let stream = try parsed([meta, start, context, route])
        #expect(stream.thread?.latestTurn?.reportedModel == nil)
        #expect(stream.unassociatedRecords == 1)
    }

    @Test func nextTurnDoesNotInheritPriorRouting() throws {
        let route: [String: Any] = ["method": "model/rerouted", "timestamp": date, "params": ["threadId": "task-A", "turnId": "turn-1", "fromModel": "gpt-6-astra", "toModel": "gpt-5.6-luna"]]
        let later = "2026-09-30T09:05:00Z"
        let nextStart: [String: Any] = ["type": "event_msg", "timestamp": later, "payload": ["type": "task_started", "turn_id": "turn-2"]]
        let nextContext: [String: Any] = ["type": "turn_context", "timestamp": later, "payload": ["turn_id": "turn-2", "model": "gpt-6-sol"]]
        let thread = try #require(parsed([meta, start, context, route, nextStart, nextContext]).thread)
        #expect(thread.latestTurn?.id == "turn-2")
        #expect(thread.latestTurn?.reportedModel == nil)
        #expect(thread.turns.first(where: { $0.id == "turn-1" })?.reportedModel == "gpt-5.6-luna")
    }

    @Test func forkedPrehistoryDoesNotBelongToChild() throws {
        let childMeta: [String: Any] = ["type": "session_meta", "timestamp": date, "payload": ["id": "child", "parent_thread_id": "task-A", "subagent_history_start_ordinal": 3]]
        let childStart: [String: Any] = ["type": "event_msg", "timestamp": date, "payload": ["type": "task_started", "turn_id": "child-turn"]]
        let childContext: [String: Any] = ["type": "turn_context", "timestamp": date, "payload": ["turn_id": "child-turn", "model": "gpt-5.6-luna"]]
        let thread = try #require(parsed([childMeta, start, context, childStart, childContext]).thread)
        #expect(thread.turns.count == 1)
        #expect(thread.turns[0].id == "child-turn")
        #expect(thread.parentID == "task-A")
    }

    @Test func taskCompletionStopsActivity() throws {
        let finish: [String: Any] = ["type": "event_msg", "timestamp": date, "payload": ["type": "task_complete", "turn_id": "turn-1", "error": NSNull()]]
        let turn = try #require(parsed([meta, start, context, finish]).thread?.latestTurn)
        #expect(turn.status == .completed)
        #expect(turn.completedAt != nil)
    }

    @Test func invalidModelAndFreeformReasonAreNotPersisted() throws {
        let route: [String: Any] = ["method": "model/rerouted", "params": ["threadId": "task-A", "turnId": "turn-1", "toModel": "gpt-5.6-luna", "reason": "Authorization: Bearer SECRET"]]
        let turn = try #require(parsed([meta, start, context, route]).thread?.latestTurn)
        #expect(turn.serverEvidence.first?.reason == nil)
        #expect(validModel("gpt\nsecret") == nil)
    }
}
