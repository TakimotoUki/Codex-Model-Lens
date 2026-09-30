import Foundation

public struct ProbeResponse: Codable, Identifiable, Sendable, Equatable {
    public var responseID: String
    public var models: [String] = []
    public var headerModels: [String] = []
    public var hasOutput = false
    public var status: String?
    public var createdAt: Date?
    public var id: String { responseID }
    public var allModels: [String] { Array(Set(models + headerModels)).sorted() }
    public var effectiveModels: [String] { Array(Set(headerModels.isEmpty ? models : headerModels)).sorted() }
}
public struct ModelProbeReport: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID().uuidString
    public var requestedModel: String
    public var testedAt: Date
    public var duration: TimeInterval
    public var exitCode: Int32
    public var timedOut: Bool
    public var frames: Int
    public var errorEvents: Int
    public var responses: [ProbeResponse]
    public var outputResponses: [ProbeResponse] { responses.filter { $0.hasOutput } }
    public var deliveredModels: [String] { Array(Set(outputResponses.flatMap(\.effectiveModels))).sorted() }
    public var isConfirmed: Bool {
        exitCode == 0 && !timedOut && errorEvents == 0 && !outputResponses.isEmpty &&
        outputResponses.allSatisfy { $0.status == "completed" && $0.effectiveModels.count == 1 }
    }
    public var hasDifference: Bool { isConfirmed && deliveredModels.contains { $0 != requestedModel } }
    public var label: String { isConfirmed ? hasDifference ? "发现模型差异" : "响应模型一致" : "本次核验未确认" }
}

struct WireProbeParser {
    var responses: [ProbeResponse] = []
    var frames = 0
    var errors = 0
    private var currentID: String?
    private var pendingHeaders: [String] = []
    mutating func consume(_ line: String) {
        let marker = line.range(of: "tungstenite::protocol: Received message ") ?? line.range(of: "SSE event: ")
        guard let marker, line.utf8.count <= 2 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(line[marker.upperBound...].utf8)) as? [String: Any] else { return }
        guard let type = object["type"] as? String, type.hasPrefix("response.") || type == "error" else { return }
        frames += 1
        let response = object["response"] as? [String: Any] ?? [:]
        let id = response["id"] as? String ?? object["response_id"] as? String
        let responseHeaders = serverModelHeaders(response["headers"])
        let incomingHeaders = (responseHeaders.isEmpty ? serverModelHeaders(object["headers"]) : responseHeaders).map(\.1)
        if type == "response.metadata", id == nil,
           currentID == nil || responses.first(where: { $0.id == currentID })?.status == "completed" {
            pendingHeaders = Array(Set(pendingHeaders + incomingHeaders)).sorted(); return
        }
        if let id, id.hasPrefix("resp_"), id.count <= 200,
           id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) {
            currentID = id
            if !responses.contains(where: { $0.id == id }), responses.count < 128 {
                var entry = ProbeResponse(responseID: id); entry.headerModels = pendingHeaders
                responses.append(entry); pendingHeaders = []
            }
        }
        if type == "error" || type == "response.failed" { errors += 1 }
        guard let currentID, let index = responses.firstIndex(where: { $0.id == currentID }) else { return }
        if let model = validModel(response["model"]), !responses[index].models.contains(model) { responses[index].models.append(model) }
        for model in incomingHeaders {
            if !responses[index].headerModels.contains(model) { responses[index].headerModels.append(model) }
        }
        if let status = validModel(response["status"]) { responses[index].status = status }
        if let date = LensDate.parse(response["created_at"]) { responses[index].createdAt = date }
        if (type == "response.output_text.delta" || type == "response.output_text.done") && id == currentID { responses[index].hasOutput = true }
        if type == "response.completed" {
            responses[index].status = "completed"
            if let output = response["output"] as? [[String: Any]], output.contains(where: { $0["type"] as? String == "message" }) {
                responses[index].hasOutput = true
            }
        }
    }
}

struct BoundedLines {
    private var pending = Data()
    private var discarding = false
    mutating func append(_ data: Data, consume: (String) -> Void) {
        for part in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
            if part.offset > 0 {
                if !discarding { consume(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: true); discarding = false
            }
            if pending.count + part.element.count > 2 * 1024 * 1024 { pending.removeAll(keepingCapacity: false); discarding = true }
            if !discarding { pending.append(contentsOf: part.element) }
        }
    }
    mutating func finish(consume: (String) -> Void) {
        if !discarding && !pending.isEmpty { consume(String(decoding: pending, as: UTF8.self)) }
        pending.removeAll()
    }
}
