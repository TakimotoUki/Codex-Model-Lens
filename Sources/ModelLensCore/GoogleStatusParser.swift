import Foundation

/// Public status sources. Never uses the user's Google login or personal API key.
public enum GoogleStatusParser {
    public static func cloud(_ root: Any, now: Date = Date()) throws -> ServiceStatus {
        guard let rows = root as? [[String: Any]], rows.count <= 512 else { throw ProviderReadError.invalidResponse }
        var events: [ServiceEvent] = [], activeImpacts: [String] = []
        for row in rows {
            guard let title = row["external_desc"] as? String, !title.isEmpty,
                  let began = LensDate.parse(row["begin"]),
                  let path = row["uri"] as? String, path.hasPrefix("incidents/"), !path.contains(".."),
                  let url = URL(string: path, relativeTo: URL(string: "https://status.cloud.google.com/")!)?.absoluteURL,
                  url.scheme == "https", url.host == "status.cloud.google.com", url.user == nil, url.password == nil else {
                throw ProviderReadError.invalidResponse
            }
            let ended = LensDate.parse(row["end"])
            if let value = row["end"], !(value is NSNull), ended == nil { throw ProviderReadError.invalidResponse }
            let active = began <= now && (ended == nil || ended! > now)
            if active { activeImpacts.append(row["status_impact"] as? String ?? "") }
            events.append(ServiceEvent(title: String(title.prefix(180)), url: url,
                updatedAt: LensDate.parse(row["modified"]) ?? began, phase: active ? "investigating" : "resolved"))
        }
        events.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        let condition: ServiceCondition = activeImpacts.contains("SERVICE_OUTAGE") ? .outage : activeImpacts.isEmpty ? .operational : .degraded
        return ServiceStatus(condition: condition,
            detail: activeImpacts.isEmpty ? "全部服务暂无公开未解决事件" : "有公开未解决事件", fetchedAt: now, events: Array(events.prefix(3)))
    }

    /// Anonymous ListIncidentsHistory JSON+protobuf response used by Google's status page.
    public static func gemini(_ data: Data, now: Date = Date()) throws -> ServiceStatus {
        guard data.count <= 2 * 1024 * 1024,
              let outer = try JSONSerialization.jsonObject(with: data) as? [Any], outer.count == 1,
              let group = outer.first as? [Any], group.count == 1,
              let rows = group.first as? [[Any]], rows.count <= 512 else { throw ProviderReadError.invalidResponse }
        var active = false, events: [ServiceEvent] = []
        for row in rows {
            guard row.count >= 4, let id = row[0] as? String, !id.isEmpty, id.count <= 200,
                  let title = row[1] as? String, !title.isEmpty,
                  let updates = row[3] as? [[Any]], !updates.isEmpty, updates.count <= 128 else { throw ProviderReadError.invalidResponse }
            var latest: (Date, Int)?
            for update in updates {
                guard update.count >= 3, let phase = update[0] as? NSNumber,
                      CFGetTypeID(phase) != CFBooleanGetTypeID(), phase.doubleValue == Double(phase.intValue),
                      (1...5).contains(phase.intValue), let stamp = update[2] as? [Any],
                      let seconds = stamp.first as? String, let number = Double(seconds), number.isFinite, number >= 0, number < 100_000_000_000,
                      let date = LensDate.parse(number), date <= now.addingTimeInterval(300) else {
                    throw ProviderReadError.invalidResponse
                }
                if latest == nil || date > latest!.0 { latest = (date, phase.intValue) }
            }
            guard let latest else { throw ProviderReadError.invalidResponse }
            if latest.1 != 4 { active = true }
            var parts = URLComponents(string: "https://aistudio.google.com/status")!
            parts.fragment = id
            events.append(ServiceEvent(title: String(title.prefix(180)), url: parts.url!, updatedAt: latest.0,
                phase: latest.1 == 4 ? "resolved" : "investigating"))
        }
        events.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return ServiceStatus(condition: active ? .degraded : .operational,
            detail: active ? "有未解决事件" : "全部服务暂无未解决事件", fetchedAt: now, events: Array(events.prefix(3)))
    }

    static func publicClientKey(_ html: Data) -> String? {
        let text = String(decoding: html, as: UTF8.self)
        let pattern = #""WIu0Nc"\s*:\s*"(AIza[A-Za-z0-9_-]{35})""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
