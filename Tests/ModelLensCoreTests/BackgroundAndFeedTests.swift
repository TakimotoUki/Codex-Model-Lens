import Foundation
import Testing
@testable import ModelLensCore

@Suite("Background quota and official subscriptions") struct BackgroundAndFeedTests {
    @Test func timestampsRemainCorrectUnderConcurrentParsing() async {
        let expected = Date(timeIntervalSince1970: 1790816400)
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<100 {
                group.addTask { LensDate.parse(index.isMultiple(of: 2) ? "2026-10-01T09:00:00+08:00" : "2026-10-01T01:00:00.000Z") == expected }
            }
            for await correct in group { #expect(correct) }
        }
        #expect(LensDate.parse(Double.infinity) == nil)
        #expect(LensDate.parse(Double.nan) == nil)
    }
    @Test func protobufZeroRequiresVerifiedEndpointAndReset() throws {
        let status: [String: Any] = ["userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [["label":"Gemini 3", "quotaInfo":["resetTime":"2026-10-02T17:39:14Z"]]]]]]
        #expect(try ProviderParsers.antigravity(summary: [:], status: status).meters[0].remainingPercent == nil)
        #expect(try ProviderParsers.antigravity(summary: [:], status: status, legacyProtoDefaults: true).meters[0].remainingPercent == 0)
        let malformed: [String: Any] = ["userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [["label":"Gemini 3", "quotaInfo":["resetTime":"invalid", "remainingFraction":NSNull()]]]]]]
        #expect(try ProviderParsers.antigravity(summary: [:], status: malformed, legacyProtoDefaults: true).meters[0].remainingPercent == nil)
    }
    @Test func quotaResponseWrappersAndOptionalSummaryRemainDistinct() throws {
        let payload: [String: Any] = ["groups":[["displayName":"Gemini", "buckets":[["displayName":"Weekly", "remainingFraction":0.01],["displayName":"Disabled", "remainingFraction":1, "disabled":true],["displayName":"Unknown", "remaining":[:]]]]]]
        for wrapper in ["response", "summary", "quotaSummary"] {
            let value = try ProviderParsers.antigravity(summary: [wrapper:payload], status: [:], legacyProtoDefaults: true)
            #expect(value.meters.count == 2 && value.meters[0].remainingPercent == 1 && value.meters[1].remainingPercent == nil)
        }
    }
    func rss(_ items: String) -> Data { Data("<rss><channel>\(items)</channel></rss>".utf8) }
    func item(_ name: String, _ state: String, _ path: String = "1", _ date: String = "Thu, 01 Oct 2026 04:00:00 GMT") -> String {
        "<item><title>\(name)</title><link>https://status.openai.com/incidents/\(path)</link><pubDate>\(date)</pubDate><description><![CDATA[<b>Status:</b> \(state)<br/><b>Affected components</b> Codex CLI]]></description></item>"
    }
    @Test func openAIStatusIncludesAllProductsAndNewestIncidentWins() throws {
        let data = rss(item("Codex recovered", "Resolved") + item("Codex earlier", "Investigating", "1", "Wed, 30 Sep 2026 04:00:00 GMT") + "<item><title>Space errors</title><link>https://status.openai.com/incidents/space</link><description>Status: Investigating Space</description></item>")
        let status = try StatusFeedParser.parse(data, provider: .codex)
        #expect(status.condition == .degraded && status.events.count == 2)
        #expect(status.events.first(where: { $0.url.path.hasSuffix("/1") })?.phase == "resolved")
        #expect(try StatusFeedParser.parse(rss(item("Codex errors", "Monitoring")), provider: .codex).condition == .degraded)
        #expect(try StatusFeedParser.parse(rss(""), provider: .codex).condition == .unknown)
    }
    @Test func feedsRejectExternalEntitiesAndOffDomainLinks() throws {
        #expect(throws: ProviderReadError.self) { try StatusFeedParser.parse(Data("<!DOCTYPE rss [<!ENTITY leak SYSTEM 'file:///etc/passwd'>]><rss/>".utf8), provider: .codex) }
        let fake = item("Codex", "Resolved").replacingOccurrences(of: "https://status.openai.com", with: "https://evil.example")
        #expect(try StatusFeedParser.parse(rss(fake), provider: .codex).events.isEmpty)
    }
    @Test func atomNeverProvesAntigravityHealth() throws {
        let data = Data("<feed xmlns='http://www.w3.org/2005/Atom'><entry><title>RESOLVED: Cloud network</title><updated>2026-10-01T00:00:00Z</updated><link rel='alternate' href='https://status.cloud.google.com/incidents/1'/><summary>Cloud recovered</summary></entry></feed>".utf8)
        let status = try StatusFeedParser.parse(data, provider: .antigravity)
        #expect(status.condition == .unknown && status.events.count == 1 && status.events[0].updatedAt != nil)
    }
}
