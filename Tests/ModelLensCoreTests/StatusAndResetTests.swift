import Foundation
import Testing
@testable import ModelLensCore

@Suite("Reset cards and scoped service health")
struct StatusAndResetTests {
    @Test func resetCardsAreIndependentOfPurchaseBalance() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let value = AccountSnapshot.parse(account: nil, quotas: [
            "rateLimits": ["credits": ["balance": "0"]],
            "rateLimitResetCredits": ["availableCount": 1, "credits": [[
                "id": "PRIVATE-REDEMPTION-ID", "status": "available", "resetType": "codexRateLimits", "expiresAt": 2000
            ]]]
        ], usage: nil, now: now)
        #expect(value.availableResetCards == 1)
        #expect(value.buckets.first?.creditsBalance == "0")
        #expect(value.resetCardExpiresAt == Date(timeIntervalSince1970: 2000))
        #expect(!String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("PRIVATE"))
    }
    @Test func resetCardCountUsesSummaryAndRejectsInvalidValues() {
        for field: Any in [true, 1.5, -1, "1", NSNumber(value: UInt64.max)] {
            #expect(AccountSnapshot.parse(account: nil, quotas: ["rateLimitResetCredits": ["availableCount": field]], usage: nil).availableResetCards == nil)
        }
        #expect(AccountSnapshot.parse(account: nil, quotas: nil, usage: nil).availableResetCards == nil)
        #expect(AccountSnapshot.parse(account: nil, quotas: ["rateLimitResetCredits": ["availableCount": 0]], usage: nil).availableResetCards == 0)
        #expect(AccountSnapshot.parse(account: nil, quotas: ["rateLimitResetCredits": ["availableCount": 3, "credits": []]], usage: nil).availableResetCards == 3)
    }
    @Test func oldAccountArchiveLoadsWithoutResetFields() throws {
        let bytes = Data(#"{"fetchedAt":0,"buckets":[]}"#.utf8)
        let value = try JSONDecoder().decode(AccountSnapshot.self, from: bytes)
        #expect(value.availableResetCards == nil)
    }
    private func status(_ components: [[String: Any]], incidents: [[String: Any]] = [], provider: UsageProvider = .codex) throws -> ServiceStatus {
        try ServiceStatusParser.parse(JSONSerialization.data(withJSONObject: ["components": components, "incidents": incidents]), provider: provider)
    }
    @Test func otherOpenAIProductsDoNotMarkCodexDown() throws {
        let value = try status([["id": "codex", "name": "Codex", "status": "operational"], ["id": "chat", "name": "ChatGPT", "status": "major_outage"]],
                               incidents: [["status": "investigating", "components": [["id": "chat"]]]])
        #expect(value.condition == .operational)
        #expect(try status([["name": "ChatGPT", "status": "operational"]]).condition == .unknown)
    }
    @Test func relevantIncidentsAndUnknownComponentStatesAreConservative() throws {
        #expect(try status([["id": "c", "name": "Codex", "status": "operational"]], incidents: [["status": "monitoring", "components": [["id": "c"]]]]).condition == .degraded)
        #expect(try status([["name": "Codex", "status": "brand_new_state"]]).condition == .unknown)
        #expect(try status([["name": "Codex", "status": "major_outage"]]).condition == .outage)
        #expect(try status([["name": "API", "status": "degraded_performance"]], provider: .deepseek).condition == .degraded)
    }
    @Test func cloudFeedNeverClaimsAntigravityIsHealthy() throws {
        #expect(try ServiceStatusParser.parse(Data("[]".utf8), provider: .antigravity).condition == .unknown)
        #expect(throws: ProviderReadError.self) { try ServiceStatusParser.parse(Data("{}".utf8), provider: .antigravity) }
    }
    @Test func nativeOpenAIStatusRespectsGroupAndMissingAffectedList() throws {
        let structure: [String: Any] = ["items": [["group": ["name": "Codex", "components": [["component_id": "c", "name": "CLI"]]]],
                                               ["group": ["name": "ChatGPT", "components": [["component_id": "g", "name": "Login"]]]]]]
        func parse(_ affected: [[String: Any]]?) throws -> ServiceStatus {
            var summary: [String: Any] = ["structure": structure]
            if let affected { summary["affected_components"] = affected }
            return try ServiceStatusParser.parse(JSONSerialization.data(withJSONObject: ["summary": summary]), provider: .codex)
        }
        #expect(try parse([["component_id": "g", "status": "major_outage"]]).condition == .operational)
        #expect(try parse([["component_id": "c", "status": "partial_outage"]]).condition == .degraded)
        #expect(throws: ProviderReadError.self) { try parse(nil) }
    }
}
