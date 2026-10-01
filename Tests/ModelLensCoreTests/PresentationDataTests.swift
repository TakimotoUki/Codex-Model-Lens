import Foundation
import Testing
@testable import ModelLensCore

@Suite("Presentation provenance and broad service status") struct PresentationDataTests {
    @Test func captureSourcesAndManualImportsRemainDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let imports = root.appendingPathComponent("ImportedEvidence"), network = root.appendingPathComponent("NetworkEvidence")
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
        func record(_ id: String, imported: Bool = false) throws -> Data {
            var object: [String: Any] = ["type":"response.created", "thread_id":id, "turn_id":"turn", "origin":"networkCapture",
                "response":["id":"resp_" + id, "model":"server-model"]]
            if imported { object["imported_from"] = "external.json" }
            return try JSONSerialization.data(withJSONObject: object) + Data([10])
        }
        try record("capture").write(to: network.appendingPathComponent("capture.jsonl"))
        try record("manual").write(to: imports.appendingPathComponent("evidence-manual.jsonl"))
        try record("legacy").write(to: imports.appendingPathComponent("network-models-" + UUID().uuidString + ".jsonl"))
        try record("spoof", imported: true).write(to: imports.appendingPathComponent("network-models-" + UUID().uuidString + ".jsonl"))
        let result = await CodexScanner(configuration: ScannerConfiguration(codexHome: root, importedEvidence: imports, networkEvidence: network)).scan()
        let evidence = Dictionary(uniqueKeysWithValues: result.threads.map { ($0.id, $0.latestTurn?.serverEvidence.first?.origin) })
        #expect(evidence["capture"] == .some(.networkCapture))
        #expect(evidence["legacy"] == .some(.networkCapture))
        #expect(evidence["manual"] == .some(.manualImport))
        #expect(evidence["spoof"] == .some(.manualImport))
    }
    @Test func oldHistoryCanAcquireProvenanceWithoutDuplicateEvidence() {
        var old = TurnRecord(id: "turn", startedAt: Date())
        old.evidence = [ModelEvidence(kind: .responseModel, model: "server-model", timestamp: Date(), source: "source", locator: "1", responseID: "resp_1")]
        var new = old; new.evidence[0].origin = .networkCapture
        let merged = HistoryStore.mergeTurns([old], [new])
        #expect(merged[0].evidence.count == 1 && merged[0].evidence[0].origin == .networkCapture)
        #expect(HistoryStore.mergeTurns([new], [old])[0].evidence[0].origin == .networkCapture)
    }
    @Test func unsupportedProvidersDoNotOfferStatus() {
        #expect(UsageProvider.codex.supportsServiceStatus && UsageProvider.antigravity.supportsServiceStatus && UsageProvider.deepseek.supportsServiceStatus)
        #expect(!UsageProvider.opencodego.supportsServiceStatus && !UsageProvider.workbuddy.supportsServiceStatus)
    }
    @Test func cloudIncludesAllServicesAndRequiresValidEndTime() throws {
        let now = Date(timeIntervalSince1970: 1790800000)
        let row: [String: Any] = ["external_desc":"Cloud Storage interruption", "begin":"2026-09-30T00:00:00Z", "uri":"incidents/storage", "end":NSNull(), "status_impact":"SERVICE_OUTAGE"]
        #expect(try GoogleStatusParser.cloud([row], now: now).condition == .outage)
        var resolved = row; resolved["end"] = "2026-09-30T02:00:00Z"
        #expect(try GoogleStatusParser.cloud([resolved], now: now).condition == .operational)
        resolved["end"] = "unrecognized"
        #expect(throws: ProviderReadError.self) { try GoogleStatusParser.cloud([resolved], now: now) }
    }
    @Test func geminiUsesNewestUpdateAcrossAllServicesAndTiers() throws {
        func response(_ phase: Any) throws -> Data {
            let records: [[Any]] = [["api", "Gemini API", 1, [[4,"",["1780000000"]], [phase,"",["1781000000"]]],1],
                ["studio", "AI Studio", 1, [[4,"",["1780000000"]]],3]]
            return try JSONSerialization.data(withJSONObject: [[records]])
        }
        #expect(try GoogleStatusParser.gemini(response(1)).condition == .degraded)
        #expect(try GoogleStatusParser.gemini(response(4)).condition == .operational)
        #expect(try GoogleStatusParser.gemini(response(5)).condition == .degraded)
        #expect(throws: ProviderReadError.self) { try GoogleStatusParser.gemini(response(77)) }
        #expect(throws: ProviderReadError.self) { try GoogleStatusParser.gemini(response(true)) }
        #expect(GoogleStatusParser.publicClientKey(Data(#"{"WIu0Nc":"invalid"}"#.utf8)) == nil)
    }
}
