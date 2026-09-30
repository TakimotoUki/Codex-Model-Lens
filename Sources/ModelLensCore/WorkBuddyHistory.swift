import Foundation

public enum WorkBuddyHistory {
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> UsageSnapshot {
        let database = try ReadOnlySQLite(url: home.appendingPathComponent(".workbuddy/workbuddy.db"))
        guard try database.columns("session_usage").contains("credit_json") else { throw ProviderReadError.unsupported }
        var byRequest: [String: Double] = [:]
        try database.forEach("SELECT credit_json FROM session_usage WHERE credit_json IS NOT NULL LIMIT 100000") { row in
            guard let text = row["credit_json"], text.utf8.count < 2 * 1024 * 1024,
                  let map = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
            for (id, field) in map {
                if let value = ProviderParsers.number(field), value >= 0 { byRequest[id] = max(byRequest[id] ?? 0, value) }
            }
        }
        guard !byRequest.isEmpty else { throw ProviderReadError.invalidResponse }
        let total = byRequest.values.reduce(0, +); guard total.isFinite else { throw ProviderReadError.invalidResponse }
        var value = UsageSnapshot(provider: .workbuddy, accountID: "device-local-workbuddy", source: "WorkBuddy 本机用量库")
        value.spentCredits = total
        value.note = "本机已记录积分消耗，按请求去重。新版加密登录暂不提供直接余额读取；剩余积分、重置与账户全量用量请查看官网。"
        return value
    }
}
