import Testing
import Foundation
import CSQLite
@testable import ModelLensCore

@Suite("Provider units, account boundaries and local tokens")
struct ProviderTests {
    @Test func compactNumberThresholds() {
        #expect(CompactNumber.tokens(999) == "999")
        #expect(CompactNumber.tokens(1500) == "1.5k")
        #expect(CompactNumber.tokens(67_494_336) == "67.49M")
        #expect(CompactNumber.tokens(100_000_000) == "0.1B")
        #expect(CompactNumber.tokens(6_398_515_949) == "6.4B")
    }
    @Test func opencodeUsesPercentNotFractionAndUnknownReset() throws {
        let value = try ProviderParsers.opencode(["usage": ["rolling": ["percent": 0.5], "weekly": ["percent": 1], "monthly": ["percent": 100]]], account: "a")
        #expect(value.accountID == "a" && value.meters.map(\.remainingPercent) == [99.5, 99, 0])
        #expect(value.meters.allSatisfy { $0.resetsAt == nil })
        #expect(throws: ProviderReadError.self) { try ProviderParsers.opencode(["usage": [:]], account: "a") }
    }
    @Test func opencodeRelativeReset() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let value = try ProviderParsers.opencode(["usage": ["rolling": ["percent": 25, "resetInSec": 600]]], account: "a", now: now)
        #expect(value.meters.first?.resetsAt == now.addingTimeInterval(600))
    }
    @Test func deepseekBalancesKeepPaidAndGrantedSeparate() throws {
        let root: [String: Any] = ["balance_infos": [["currency": "USD", "total_balance": "12.5", "topped_up_balance": "10", "granted_balance": "2.5"]], "is_available": true, "access_token": "PRIVATE"]
        let value = try ProviderParsers.deepseek(root, account: "accountA")
        #expect(value.balance == 12.5 && value.paidBalance == 10 && value.grantedBalance == 2.5)
        #expect(value.tokens == nil)
        #expect(!String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("PRIVATE"))
    }
    @Test func antigravityUsesRealStarterTierAndUnknownFraction() throws {
        let value = try ProviderParsers.antigravity(summary: [:], status: ["userStatus": ["userTier": ["name": "Antigravity Starter Quota"], "planStatus": ["planInfo": ["planName": "Pro"]], "cascadeModelConfigData": ["clientModelConfigs": [["label": "Gemini 3", "quotaInfo": ["resetTime": "2026-10-02T17:39:14Z"]], ["label": "Claude Sonnet", "quotaInfo": ["remainingFraction": 0.001059]]]]]])
        #expect(value.plan == "Antigravity Starter Quota")
        #expect(value.meters[0].remainingPercent == nil && abs((value.meters[1].remainingPercent ?? -1) - 0.1059) < 0.000001)
        #expect(value.tokens == nil && value.meters[0].resetsAt != nil)
    }
    @Test func antigravityWeeklySummaryHandlesOneofZero() throws {
        let value = try ProviderParsers.antigravity(summary: ["groups": [["displayName": "Gemini", "buckets": [["displayName": "Weekly", "remaining": ["case": "remainingFraction", "value": 0]]]]]], status: [:])
        #expect(value.meters.first?.remainingPercent == 0 && value.meters.first?.title == "Gemini · Weekly")
    }
    @Test func workbuddyPersonalCreditsAndZeroAreNotMoney() throws {
        let value = try ProviderParsers.workbuddy(["code": 0, "data": ["Response": ["Data": ["Accounts": [["CycleCapacitySizePrecise": "100", "CycleCapacityRemainPrecise": "0", "PackageName": "Starter"]]]]]], account: "a", enterprise: false)
        #expect(value.balance == 0 && value.currency == "积分" && value.tokens == nil && value.meters.first?.remainingPercent == 0)
        #expect(throws: ProviderReadError.self) { try ProviderParsers.workbuddy(["code": 401], account: "a", enterprise: false) }
    }
    @Test func workbuddyEnterpriseUnlimitedAndMissingAreDistinct() throws {
        let value = try ProviderParsers.workbuddy(["data": ["limitNum": -1]], account: "a", enterprise: true)
        #expect(value.balance == nil && value.note?.contains("不限量") == true)
        #expect(throws: ProviderReadError.self) { try ProviderParsers.workbuddy(["data": [:]], account: "a", enterprise: true) }
    }
    @Test func countsRejectBooleanFractionsNegativeAndOverflow() {
        for value: Any in [true, 1.5, -1, "12", NSNumber(value: UInt64.max)] { #expect(validTokenCount(value) == nil) }
        #expect(validTokenCount(NSNumber(value: Int64.max)) == Int64.max)
        #expect(OpenCodeHistory.parseTokens(["input": 1, "output": 2, "reasoning": 3, "cache": ["read": 4, "write": 5]]) == 15)
        #expect(OpenCodeHistory.parseTokens(["input": 1]) == nil)
        #expect(OpenCodeHistory.parseTokens(["input": Int64.max, "output": 2, "reasoning": 0, "cache": ["read": 0, "write": 0]]) == nil)
    }
    @Test func accountDailyOverflowStaysUnknown() {
        let now = Date(); let day = String(ISO8601DateFormatter().string(from: now).prefix(10))
        let value = AccountSnapshot.parse(account: nil, quotas: nil, usage: ["dailyUsageBuckets": [["startDate": day, "tokens": Int64.max], ["startDate": day, "tokens": 1]]], now: now)
        #expect(value.todayTokens == nil)
    }
    @Test func credentialFingerprintUsesAccountIdentityAndDropsSecrets() throws {
        func auth(_ id: String, _ token: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["access_token": token, "account_id": id]]) }
        let a = try auth("a", "secret1"), b = try auth("b", "secret1")
        #expect(CodexCredentials.isValid(a))
        #expect(CodexCredentials.fingerprint(a) == CodexCredentials.fingerprint(try auth("a", "changed")))
        #expect(CodexCredentials.fingerprint(a) != CodexCredentials.fingerprint(b))
        #expect(!CodexCredentials.fingerprint(a).contains("secret"))
    }
    @Test func sqliteTokensPreferStepsAndExcludesOtherProviders() throws {
        let dir = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("opencode.db"); var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK); defer { sqlite3_close(db) }
        func sql(_ value: String) throws { guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else { throw ProviderReadError.invalidResponse } }
        try sql("CREATE TABLE message (id TEXT, data TEXT, time_created INTEGER); CREATE TABLE part (message_id TEXT, data TEXT)")
        func insert(_ table: String, _ id: String, _ data: [String: Any]) throws {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            try sql(table == "message" ? "INSERT INTO message VALUES ('\(id)', '\(json)', \(Int64(Date().timeIntervalSince1970 * 1000)))" : "INSERT INTO part VALUES ('\(id)', '\(json)')")
        }
        try insert("message", "m", ["role": "assistant", "providerID": "opencode-go", "cost": 99, "tokens": ["total": 999]])
        try insert("part", "m", ["type": "step-finish", "cost": 1.25, "tokens": ["total": 100]])
        try insert("part", "m", ["type": "step-finish", "cost": 2, "tokens": ["total": 200]])
        try insert("message", "other", ["role": "assistant", "providerID": "openai", "cost": 1000])
        let value = try OpenCodeHistory.load(url: file)
        #expect(value.tokens == 300 && value.todayTokens == 300)
        #expect(value.accountID == "device-local")
        #expect(throws: SQLiteReadError.self) { try ReadOnlySQLite(url: file).query("DELETE FROM message") }
    }

    @Test func workbuddyLocalCreditsDeduplicateRequests() throws {
        let dir = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".workbuddy"), withIntermediateDirectories: true)
        var db: OpaquePointer?; #expect(sqlite3_open(dir.appendingPathComponent(".workbuddy/workbuddy.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE session_usage (credit_json TEXT); INSERT INTO session_usage VALUES ('{\"reqA\":1.25,\"reqB\":2}'), ('{\"reqA\":1.25}')", nil, nil, nil) == SQLITE_OK)
        let value = try WorkBuddyHistory.load(home: dir)
        #expect(value.spentCredits == 3.25 && value.balance == nil && value.tokens == nil)
    }
    @Test func openCodeConsoleMicroCentsAndWorkspaceBoundary() throws {
        let value = try ProviderParsers.opencodeConsole(["access": ["endsAt": "2026-11-01T00:00:00Z", "meters": ["month": ["usedMicroCents": "50000000", "limitMicroCents": "100000000"]]]], billing: ["balanceMicroCents": "250000000"], account: "org-scoped")
        #expect(value.balance == 2.5 && value.meters.first?.remainingPercent == 50)
        #expect(value.meters.first?.resetsAt != nil && value.tokens == nil)
        let prepaid = try ProviderParsers.opencodeConsole([:], billing: ["balanceMicroCents": "0"], account: "zero")
        #expect(prepaid.balance == 0 && prepaid.meters.isEmpty)
    }

}
