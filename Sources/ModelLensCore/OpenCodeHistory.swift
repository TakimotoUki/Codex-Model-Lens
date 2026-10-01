import Foundation
import CoreFoundation

public enum OpenCodeHistory {
    public static var database: URL {
        (ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share"))
            .appendingPathComponent("opencode/opencode.db")
    }
    public static func load(url: URL = database, now: Date = Date()) throws -> UsageSnapshot {
        let database = try ReadOnlySQLite(url: url)
        guard try database.columns("message").isSuperset(of: ["id", "data", "time_created"]),
              try database.columns("part").isSuperset(of: ["message_id", "data"]) else { throw ProviderReadError.unsupported }
        let since = Int64(now.addingTimeInterval(-90 * 86400).timeIntervalSince1970 * 1000)
        var days: [String: Int64] = [:]
        var unknownDays: Set<String> = []
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let sql = """
            WITH eligible AS (
                SELECT id, data, time_created FROM message
                WHERE time_created >= \(since) AND json_valid(data)
                  AND json_extract(data, '$.role') = 'assistant'
                  AND json_extract(data, '$.providerID') = 'opencode-go'
                ORDER BY time_created DESC LIMIT 100000
            )
            SELECT COALESCE(json_extract(p.data, '$.time.created'), e.time_created) AS time_created, p.data
            FROM eligible e JOIN part p ON p.message_id = e.id
            WHERE json_valid(p.data) AND json_extract(p.data, '$.type') = 'step-finish'
            UNION ALL
            SELECT COALESCE(json_extract(e.data, '$.time.created'), e.time_created), e.data FROM eligible e
            WHERE NOT EXISTS (
                SELECT 1 FROM part p WHERE p.message_id = e.id AND json_valid(p.data)
                  AND json_extract(p.data, '$.type') = 'step-finish'
            )
            """
        try database.forEach(sql) { row in
            guard let text = row["data"], text.utf8.count < 2 * 1024 * 1024,
                  let record = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let milliseconds = row["time_created"].flatMap(Double.init), milliseconds.isFinite else { return }
            let day = formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
            let previous = days[day] ?? 0
            let tokens = parseTokens(record["tokens"] as? [String: Any])
            if let tokens {
                let sum = previous.addingReportingOverflow(tokens)
                if sum.overflow { unknownDays.insert(day) } else { days[day] = sum.partialValue }
            } else { unknownDays.insert(day); days[day] = previous }
        }
        guard !days.isEmpty else { throw ProviderReadError.invalidResponse }
        var value = UsageSnapshot(provider: .opencodego, accountID: "device-local", source: "本机 OpenCode SQLite · 最近 90 天")
        value.tokens = unknownDays.isEmpty ? days.values.reduce(Int64?(0)) { accumulator, tokens in
            guard let accumulator else { return nil }
            let sum = accumulator.addingReportingOverflow(tokens); return sum.overflow ? nil : sum.partialValue
        } : nil
        let today = formatter.string(from: now)
        value.todayTokens = unknownDays.contains(today) ? nil : days[today]
        value.note = "Token 为本机 opencode-go 最近 90 天记录，不代表账户全量用量。"
        return value
    }
    static func parseTokens(_ tokens: [String: Any]?) -> Int64? {
        guard let tokens else { return nil }
        if let total = tokens["total"] { return validTokenCount(total) }
        let cache = tokens["cache"] as? [String: Any]
        let fields = [tokens["input"], tokens["output"], tokens["reasoning"], cache?["read"], cache?["write"]]
        var result: Int64 = 0
        for field in fields {
            guard let count = validTokenCount(field) else { return nil }
            let sum = result.addingReportingOverflow(count); guard !sum.overflow else { return nil }; result = sum.partialValue
        }
        return result
    }
}
func validTokenCount(_ value: Any?) -> Int64? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          let parsed = Int64(value.stringValue), parsed >= 0 else { return nil }
    return parsed
}
