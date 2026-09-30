import Foundation

public struct TokenUsage: Codable, Sendable, Equatable {
    public var input: Int64?
    public var cachedInput: Int64?
    public var output: Int64?
    public var reasoningOutput: Int64?
    public var total: Int64?
    static func parse(_ object: [String: Any]) -> Self {
        func number(_ key: String) -> Int64? { validTokenCount(object[key]) }
        return Self(input: number("input_tokens"), cachedInput: number("cached_input_tokens"),
                    output: number("output_tokens"), reasoningOutput: number("reasoning_output_tokens"), total: number("total_tokens"))
    }
}

public struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var usedPercent: Double?
    public var windowMinutes: Int?
    public var resetsAt: Date?
    public var remainingPercent: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }
    public var label: String {
        guard let minutes = windowMinutes else { return id == "primary" ? "主要额度" : "次要额度" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
}
public struct QuotaBucket: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    public var plan: String?
    public var windows: [QuotaWindow]
    public var creditsBalance: String?
    public var unlimitedCredits: Bool?
}
public struct AccountSnapshot: Codable, Sendable, Equatable {
    public var fetchedAt: Date
    public var plan: String?
    public var buckets: [QuotaBucket]
    public var lifetimeTokens: Int64?
    public var todayTokens: Int64?
    public var tokenNote: String?
    public var quotaNote: String?
    public init(fetchedAt: Date = Date(), plan: String? = nil, buckets: [QuotaBucket] = [],
                lifetimeTokens: Int64? = nil, todayTokens: Int64? = nil, tokenNote: String? = nil, quotaNote: String? = nil) {
        self.fetchedAt = fetchedAt; self.plan = plan; self.buckets = buckets
        self.lifetimeTokens = lifetimeTokens; self.todayTokens = todayTokens
        self.tokenNote = tokenNote; self.quotaNote = quotaNote
    }
    // Strict metadata projection: account email, IDs and authentication tokens are never saved.
    static func parse(account: [String: Any]?, quotas: [String: Any]?, usage: [String: Any]?, now: Date = Date()) -> Self {
        let info = account?["account"] as? [String: Any]
        var result = Self(fetchedAt: now, plan: validModel(info?["planType"]))
        let multi = quotas?["rateLimitsByLimitId"] as? [String: Any]
        var entries: [(String, [String: Any])] = []
        if let multi, !multi.isEmpty { entries = multi.keys.sorted().compactMap { key in (multi[key] as? [String: Any]).map { (key, $0) } } }
        else if let single = quotas?["rateLimits"] as? [String: Any] { entries = [(single["limitId"] as? String ?? "codex", single)] }
        for (key, entry) in entries {
            var windows: [QuotaWindow] = []
            for id in ["primary", "secondary"] {
                guard let object = entry[id] as? [String: Any] else { continue }
                let percent = ProviderParsers.number(object["usedPercent"])
                windows.append(QuotaWindow(id: id, usedPercent: percent.flatMap { $0.isFinite ? max(0, min(100, $0)) : nil },
                    windowMinutes: (object["windowDurationMins"] as? NSNumber).flatMap { $0.intValue > 0 ? $0.intValue : nil },
                    resetsAt: LensDate.parse(object["resetsAt"])))
            }
            let credits = entry["credits"] as? [String: Any]
            let balance = credits?["balance"] as? String
            result.buckets.append(QuotaBucket(id: validModel(key) ?? "codex", name: validModel(entry["limitName"]),
                plan: validModel(entry["planType"]), windows: windows,
                creditsBalance: balance.flatMap { Double($0) != nil ? String($0.prefix(80)) : nil }, unlimitedCredits: credits?["unlimited"] as? Bool))
        }
        result.plan = result.plan ?? result.buckets.compactMap(\.plan).first
        func count(_ value: Any?) -> Int64? { validTokenCount(value) }
        result.lifetimeTokens = count((usage?["summary"] as? [String: Any])?["lifetimeTokens"])
        let date = ISO8601DateFormatter().string(from: now).prefix(10)
        if let daily = usage?["dailyUsageBuckets"] as? [[String: Any]] {
            let todayRows = daily.filter { ($0["startDate"] as? String) == String(date) }
            let today = todayRows.compactMap { count($0["tokens"]) }
            if !today.isEmpty && today.count == todayRows.count {
                result.todayTokens = today.reduce(Int64?(0)) { total, next in guard let total else { return nil }; let sum = total.addingReportingOverflow(next); return sum.overflow ? nil : sum.partialValue }
            }
        }
        return result
    }
}
