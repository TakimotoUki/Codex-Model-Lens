import Foundation

/// The official core emits this message only after processing ResponseEvent::ServerModel.
/// Request model spans, quoted user input, and safety-buffering hints are excluded.
enum ServerModelLogParser {
    static func parse(body: String, target: String, threadID: String?, timestamp: Date,
                      source: String, locator: String) -> ThreadRecord? {
        guard ["codex_core::session", "codex_core::codex"].contains(target), body.utf8.count < 16384,
              let boundary = body.range(of: "}: ", options: .backwards) else { return nil }
        let span = String(body[..<boundary.upperBound]), message = String(body[boundary.upperBound...])
        guard let brace = span.firstIndex(of: "{"),
              span[..<brace].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.".contains($0)) }),
              let model = capture(#"^server reported model ([A-Za-z0-9][A-Za-z0-9._:/-]*) (?:\(matches requested model\)|while requested model was [A-Za-z0-9][A-Za-z0-9._:/-]*)$"#, message),
              let valid = validModel(model),
              let turn = capture(#"(?:turn_id|turn\.id)="?([A-Za-z0-9_.-]+)"?"#, span) else { return nil }
        let spanThread = capture(#"(?:thread_id|thread\.id)="?([A-Za-z0-9_.-]+)"?"#, span)
        if let threadID, let spanThread, threadID != spanThread { return nil }
        guard let id = threadID ?? spanThread else { return nil }
        var record = ThreadRecord(id: id), value = TurnRecord(id: turn, startedAt: timestamp)
        value.evidence = [ModelEvidence(kind: .serverModel, model: valid, timestamp: timestamp,
            source: source, locator: locator, field: "ResponseEvent::ServerModel")]
        record.turns = [value]; return record
    }
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
