import Foundation

enum TransportEventParser {
    static func parse(body: String, target: String, threadID: String?, timestamp: Date,
                      source: String, locator: String) -> ParsedStream? {
        guard ["codex_api::sse", "codex_api::sse::responses", "codex_api::endpoint::responses_websocket",
               "codex_core::stream_events_utils", "tungstenite::protocol"].contains(target),
              body.utf8.count < 2 * 1024 * 1024 else { return nil }
        let message: String
        let span: String
        if let boundary = body.range(of: "}: ") {
            guard let brace = body.firstIndex(of: "{"),
                  body[..<brace].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.".contains($0)) }) else { return nil }
            // Nested tracing spans end at the last boundary preceding the incoming message.
            guard let marker = ["SSE event: ", "Received message "].compactMap({ body.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
            span = String(body[..<marker.lowerBound]); message = String(body[marker.lowerBound...])
            guard boundary.upperBound <= marker.lowerBound else { return nil }
        } else { message = body; span = "" }
        let json: String
        if message.hasPrefix("SSE event: ") { json = String(message.dropFirst(11)) }
        else if message.hasPrefix("Received message ") { json = String(message.dropFirst(17)) }
        else if message.hasPrefix("{") { json = message }
        else { return nil }
        guard var object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let spanThread = capture(#"(?:thread_id|thread\.id)="?([A-Za-z0-9_.-]+)"?"#, span)
        let turn = capture(#"(?:turn_id|turn\.id)="?([A-Za-z0-9_.-]+)"?"#, span)
        if let threadID, let spanThread, threadID != spanThread { return nil }
        // Payload IDs must agree with transport context; never join by timestamp or model name.
        let nested = object["params"] as? [String: Any] ?? object
        if let declared = nested["threadId"] as? String ?? nested["thread_id"] as? String,
           let transport = threadID ?? spanThread, declared != transport { return nil }
        if let declared = nested["turnId"] as? String ?? nested["turn_id"] as? String,
           let turn, declared != turn { return nil }
        object["timestamp"] = timestamp.timeIntervalSince1970
        var stream = ParsedStream()
        if let id = threadID ?? spanThread { stream.thread = ThreadRecord(id: id) }
        stream.currentTurnID = turn
        stream.consume((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), source: source, locator: locator)
        return stream
    }
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
