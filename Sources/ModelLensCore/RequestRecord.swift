import Foundation

public struct RequestRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var timestamp: Date
    public var threadID: String?
    public var turnID: String?
    public var requestedModel: String?
    public var requestID: String?
    public var httpStatus: Int?
    public var safetyBuffering: Bool?
    public var fasterModel: String?
    public var errorCode: String?
    public var failureReported: Bool?
    public var capacityMessage: Bool
    public var source: String
    public var locator: String
    public var target: String
    public var headers: [String: String]

    public init(timestamp: Date, threadID: String? = nil, turnID: String? = nil,
                requestedModel: String? = nil, requestID: String? = nil, httpStatus: Int? = nil,
                safetyBuffering: Bool? = nil, fasterModel: String? = nil, errorCode: String? = nil,
                capacityMessage: Bool = false, failureReported: Bool = false, source: String, locator: String, target: String,
                headers: [String: String] = [:], processID: String = "") {
        self.timestamp = timestamp; self.threadID = threadID; self.turnID = turnID
        self.requestedModel = requestedModel; self.requestID = requestID; self.httpStatus = httpStatus
        self.safetyBuffering = safetyBuffering; self.fasterModel = fasterModel; self.errorCode = errorCode
        self.failureReported = failureReported
        self.capacityMessage = capacityMessage; self.source = source; self.locator = locator
        self.target = target; self.headers = headers
        id = stableID([source, locator, String(timestamp.timeIntervalSince1970), requestID ?? "", processID].joined(separator: "\u{1f}"))
    }
    public var reportedModel: String? { headers["openai-model"] ?? headers["x-openai-model"] }
    public var isError: Bool { (failureReported ?? false) || (httpStatus ?? 0) >= 400 || errorCode != nil || capacityMessage }
    public var isOverloaded: Bool { errorCode == "server_is_overloaded" }
    public var isBuffering: Bool { safetyBuffering == true }
    public var statusLabel: String {
        if let errorCode { return errorCode }
        if capacityMessage { return "at capacity" }
        if failureReported == true { return "请求失败" }
        return httpStatus.map { "HTTP \($0)" } ?? "未记录状态"
    }
    public var utcTimestamp: String { ISO8601DateFormatter().string(from: timestamp) }
}

public struct LogCoverage: Codable, Sendable, Equatable {
    public var source: String
    public var oldest: Date?
    public var newest: Date?
    public var rowCount: Int
    public var scannedAt: Date
    public init(source: String, oldest: Date?, newest: Date?, rowCount: Int, scannedAt: Date) {
        self.source = source; self.oldest = oldest; self.newest = newest
        self.rowCount = rowCount; self.scannedAt = scannedAt
    }
}

public struct RequestSummary: Sendable {
    public var rows: Int
    public var identifiedRequests: Int
    public var unidentifiedRows: Int
    public var bufferingRows: Int
    public var errorRows: Int
    public var capacityRows: Int
    public var overloadedRows: Int
    public init(_ records: [RequestRecord]) {
        rows = records.count
        identifiedRequests = Set(records.compactMap(\.requestID)).count
        unidentifiedRows = records.filter { $0.requestID == nil }.count
        bufferingRows = records.filter(\.isBuffering).count
        errorRows = records.filter(\.isError).count
        capacityRows = records.filter(\.capacityMessage).count
        overloadedRows = records.filter(\.isOverloaded).count
    }
}

enum TransportLogParser {
    // Read metadata from actual transport messages, never from chat/feedback/tool targets.
    static func parse(body: String, target: String, threadID: String?, timestamp: Date,
                      source: String, locator: String, processID: String = "") -> RequestRecord? {
        guard body.utf8.count <= 1024 * 1024 else { return nil }
        let isHTTP = target == "codex_http_client::client"
        let isStream = ["codex_api::sse", "codex_api::endpoint::responses", "codex_core::stream_events_utils"].contains(target)
        guard isHTTP || isStream else { return nil }
        let message: String
        if let boundary = body.range(of: "}: ", options: .backwards) {
            guard let firstBrace = body.firstIndex(of: "{"),
                  body[..<firstBrace].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.".contains($0)) }) else { return nil }
            message = String(body[boundary.upperBound...])
        }
        else { message = body }
        let isCompleted = isHTTP && message.hasPrefix("Request completed ")
        let isFailure = (isHTTP && message.hasPrefix("Request failed ")) ||
            (isStream && ["stream error", "SSE error", "SSE event: {\"type\":\"error\"", "SSE event: {\"type\":\"response.failed\""].contains(where: message.hasPrefix))
        guard isCompleted || isFailure else { return nil }
        // Ignore analytics, model catalogs, telemetry and unrelated HTTP endpoints.
        if isHTTP {
            guard let urlString = capture(#"\burl=(https?://[^\s]+)"#, in: message),
                  let url = URL(string: urlString),
                  url.path.hasSuffix("/responses") || url.path.hasSuffix("/responses/compact") else { return nil }
        }
        var headers: [String: String] = [:]
        // Header section only: unrelated JSON or error text cannot impersonate response headers.
        if let start = message.range(of: "headers={") ?? message.range(of: "headers: {") {
            let headerText = String(message[start.upperBound...].prefix(64 * 1024))
            let section = String(headerText.prefix { $0 != "}" })
            for key in ["x-oai-request-id", "x-request-id", "x-codex-safety-buffering-enabled", "x-codex-safety-buffering-faster-model", "openai-model", "x-openai-model"] {
                if let value = capture("\"" + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*"([^"\r\n]{1,200})""#, in: section) {
                    if key.contains("faster-model") || key.contains("openai-model") {
                        if let model = validModel(value) { headers[key] = model }
                    } else if key.contains("enabled") {
                        if ["true", "false"].contains(value) { headers[key] = value }
                    } else if validIdentifier(value) != nil { headers[key] = value }
                }
            }
        }
        let span = body.range(of: "}: ", options: .backwards).map { String(body[..<$0.upperBound]) } ?? ""
        let spanThread = capture(#"(?:thread_id|thread\.id)="?([A-Za-z0-9_.-]+)"?"#, in: span)
        if let threadID, let spanThread, threadID != spanThread { return nil }
        let turn = capture(#"(?:turn_id|turn\.id)="?([A-Za-z0-9_.-]+)"?"#, in: span)
        let model = validModel(capture(#"\bmodel="?([A-Za-z0-9_.:/-]+)"?"#, in: span))
        let status = capture(#"\bstatus=(\d{3})\b"#, in: message).flatMap(Int.init)
        let code = isFailure || (status ?? 0) >= 400 ?
            capture(#""code"\s*:\s*"([A-Za-z0-9_-]{1,100})""#, in: message) : nil
        let capacity = isFailure || (status ?? 0) >= 400 ? message.localizedCaseInsensitiveContains("at capacity") : false
        let request = headers["x-oai-request-id"] ?? headers["x-request-id"] ??
            validIdentifier(capture(#"\brequest_id="?([A-Za-z0-9_.-]+)"?"#, in: message))
        return RequestRecord(timestamp: timestamp, threadID: threadID ?? spanThread, turnID: turn,
                             requestedModel: model, requestID: request, httpStatus: status,
                             safetyBuffering: headers["x-codex-safety-buffering-enabled"].map { $0 == "true" },
                             fasterModel: headers["x-codex-safety-buffering-faster-model"], errorCode: code,
                             capacityMessage: capacity, failureReported: isFailure, source: source, locator: locator, target: target,
                             headers: headers, processID: processID)
    }

    private static func validIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 200,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) else { return nil }
        return value
    }
    private static func capture(_ pattern: String, in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(result.range(at: 1), in: string) else { return nil }
        return String(string[range])
    }
}
