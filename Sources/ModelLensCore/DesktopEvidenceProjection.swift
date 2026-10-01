import Foundation

/// Keeps only turn identifiers and model evidence from desktop state. It never retains
/// messages, reasoning, tool arguments, outputs, cookies, or authentication material.
public struct DesktopEvidenceProjection: Sendable {
    private struct Identity: Sendable {
        var id: String
        var startedAt: Date
        var model: String?
    }
    private struct State: Sendable {
        var owner: String
        var revision: Int
        var identities: [String: Identity] = [:]
    }
    private var states: [String: State] = [:]
    public private(set) var snapshots = 0
    public private(set) var routingRecords = 0
    public private(set) var needsSnapshot: String?
    public init() {}
    public mutating func reset() { states.removeAll(); needsSnapshot = nil }
    mutating func retainThreads(_ ids: Set<String>) { states = states.filter { ids.contains($0.key) } }

    public mutating func consume(_ data: Data, allowedThreads: Set<String>, now: Date = Date()) -> [ThreadRecord] {
        guard data.count <= 16 * 1024 * 1024,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return consume(o, allowedThreads: allowedThreads, now: now)
    }

    mutating func consume(_ o: [String: Any], allowedThreads: Set<String>, now: Date = Date()) -> [ThreadRecord] {
        needsSnapshot = nil
        guard o["type"] as? String == "broadcast", o["method"] as? String == "thread-stream-state-changed",
              o["version"] as? Int == 11, let owner = o["sourceClientId"] as? String,
              let p = o["params"] as? [String: Any], p["hostId"] as? String == "local",
              let thread = p["conversationId"] as? String, allowedThreads.contains(thread),
              let change = p["change"] as? [String: Any], let revision = change["revision"] as? Int else { return [] }
        var records: [TurnRecord] = []
        if change["type"] as? String == "snapshot", let cs = change["conversationState"] as? [String: Any],
           cs["id"] as? String == thread {
            var state = State(owner: owner, revision: revision)
            let canonical = ((cs["turnHistory"] as? [String: Any])?["history"] as? [String: Any])?["entitiesByKey"] as? [String: Any] ?? [:]
            for (key, value) in canonical.prefix(2048) {
                guard let turn = value as? [String: Any], let identity = identity(turn, thread: thread, now: now) else { continue }
                state.identities[key] = identity
                records += project(turn, identity: identity, thread: thread, now: now)
            }
            for (index, value) in ((cs["turns"] as? [[String: Any]]) ?? []).prefix(2048).enumerated() {
                guard let identity = identity(value, thread: thread, now: now) else { continue }
                state.identities["legacy:\(index)"] = identity
                records += project(value, identity: identity, thread: thread, now: now)
            }
            states[thread] = state; snapshots += 1
        } else if change["type"] as? String == "patches" {
            guard var state = states[thread], state.owner == owner,
                  change["baseRevision"] as? Int == state.revision, revision > state.revision else {
                states.removeValue(forKey: thread); needsSnapshot = thread; return []
            }
            for patch in ((change["patches"] as? [[String: Any]]) ?? []).prefix(4096) {
                guard let path = patch["path"] as? [Any], let op = patch["op"] as? String else { continue }
                var key: String?, tail: [Any] = []
                if path.count >= 4, path[0] as? String == "turnHistory", path[1] as? String == "history",
                   path[2] as? String == "entitiesByKey", let entity = path[3] as? String {
                    key = entity; tail = Array(path.dropFirst(4))
                } else if path.count >= 2, path[0] as? String == "turns", let index = path[1] as? Int {
                    key = "legacy:\(index)"; tail = Array(path.dropFirst(2))
                }
                guard let key else { continue }
                if op == "remove", tail.isEmpty { state.identities.removeValue(forKey: key); continue }
                guard ["add", "replace"].contains(op) else { continue }
                if tail.isEmpty, let turn = patch["value"] as? [String: Any],
                   let identity = identity(turn, thread: thread, now: now) {
                    state.identities[key] = identity
                    records += project(turn, identity: identity, thread: thread, now: now)
                } else if let identity = state.identities[key], tail.first as? String == "items" {
                    // Only whole typed items at the real items path are eligible. A tool's
                    // result or text containing a lookalike model event is never traversed.
                    if tail.count == 2, tail[1] is Int, let item = patch["value"] as? [String: Any],
                       let record = routing(item, identity: identity, thread: thread, now: now) { records.append(record) }
                    if tail.count == 1, let items = patch["value"] as? [[String: Any]] {
                        records += items.compactMap { routing($0, identity: identity, thread: thread, now: now) }
                    }
                }
            }
            if state.identities.count > 4096 { states.removeValue(forKey: thread); needsSnapshot = thread; return [] }
            state.revision = revision; states[thread] = state
        }
        guard !records.isEmpty else { return [] }
        routingRecords += records.count
        var record = ThreadRecord(id: thread); record.turns = records
        return [record]
    }

    private func identity(_ turn: [String: Any], thread: String, now: Date) -> Identity? {
        guard let id = turn["turnId"] as? String, !id.isEmpty, id.utf8.count <= 160 else { return nil }
        let params = turn["params"] as? [String: Any] ?? [:]
        if let declared = params["threadId"] as? String, declared != thread { return nil }
        let milliseconds = (turn["turnStartedAtMs"] as? NSNumber)?.doubleValue
        let time = milliseconds.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil } ?? now
        return Identity(id: id, startedAt: time, model: validModel(params["model"]))
    }
    private func project(_ turn: [String: Any], identity: Identity, thread: String, now: Date) -> [TurnRecord] {
        ((turn["items"] as? [[String: Any]]) ?? []).prefix(10000).compactMap { routing($0, identity: identity, thread: thread, now: now) }
    }
    private func routing(_ item: [String: Any], identity: Identity, thread: String, now: Date) -> TurnRecord? {
        guard item["type"] as? String == "modelRerouted", let to = validModel(item["toModel"]),
              let from = validModel(item["fromModel"]), let id = item["id"] as? String,
              !id.isEmpty, id.utf8.count <= 160 else { return nil }
        var turn = TurnRecord(id: identity.id, startedAt: identity.startedAt)
        turn.requestedModel = identity.model
        let reason = item["reason"] as? String
        turn.evidence = [ModelEvidence(kind: .reroute, model: to, fromModel: from, timestamp: now,
            source: "Codex Desktop IPC", locator: "thread:\(thread)/turn:\(identity.id)/item:\(id)",
            reason: reason == "highRiskCyberActivity" ? reason : nil, field: "model/rerouted.toModel")]
        return turn
    }
}
