import Foundation

public enum ServiceCondition: String, Sendable { case operational, degraded, outage, unknown }
public struct ServiceStatus: Sendable, Equatable {
    public var condition: ServiceCondition
    public var detail: String
    public var fetchedAt: Date
    public init(condition: ServiceCondition, detail: String, fetchedAt: Date = Date()) {
        self.condition = condition; self.detail = detail; self.fetchedAt = fetchedAt
    }
}

public enum ServiceStatusParser {
    public static func parse(_ data: Data, provider: UsageProvider, now: Date = Date()) throws -> ServiceStatus {
        let root = try JSONSerialization.jsonObject(with: data)
        if provider == .codex, let object = root as? [String: Any],
           let summary = object["summary"] as? [String: Any] {
            return try incidentIO(summary, now: now)
        }
        if provider == .antigravity {
            // Google Cloud has no dedicated Antigravity component. Never translate
            // unrelated Cloud incidents or an empty feed into an Antigravity health claim.
            guard root is [[String: Any]] else { throw ProviderReadError.invalidResponse }
            return ServiceStatus(condition: .unknown, detail: "Google Cloud 参考状态 · 未覆盖 Antigravity", fetchedAt: now)
        }
        guard [.codex, .deepseek].contains(provider), let object = root as? [String: Any],
              let components = object["components"] as? [[String: Any]] else { throw ProviderReadError.invalidResponse }
        let relevant = components.filter { row in
            guard let name = row["name"] as? String else { return false }
            if provider == .codex { return name.localizedCaseInsensitiveContains("codex") || name == "CLI" }
            return name.localizedCaseInsensitiveContains("api") || name.localizedCaseInsensitiveContains("chat")
        }
        guard !relevant.isEmpty else {
            return ServiceStatus(condition: .unknown, detail: "官方状态页未提供该服务的组件状态", fetchedAt: now)
        }
        let states = relevant.compactMap { $0["status"] as? String }
        let recognized = Set(["operational", "degraded_performance", "partial_outage", "major_outage", "under_maintenance"])
        guard states.count == relevant.count, states.allSatisfy({ recognized.contains($0) }) else {
            return ServiceStatus(condition: .unknown, detail: "官方组件状态尚未识别", fetchedAt: now)
        }
        if states.contains("major_outage") { return ServiceStatus(condition: .outage, detail: "官方报告服务中断", fetchedAt: now) }
        if states.contains(where: { $0 != "operational" }) { return ServiceStatus(condition: .degraded, detail: "官方报告部分服务异常或维护", fetchedAt: now) }
        // Active incidents can remain after a component has recovered. Only incidents
        // linked to this provider's components count; other OpenAI products are excluded.
        let ids = Set(relevant.compactMap { $0["id"] as? String })
        let incidents = object["incidents"] as? [[String: Any]] ?? []
        let active = incidents.contains { row in
            guard let status = row["status"] as? String, status != "resolved", status != "postmortem",
                  let affected = row["components"] as? [[String: Any]] else { return false }
            return affected.contains { ($0["id"] as? String).map(ids.contains) ?? false }
        }
        let scope = provider == .codex && relevant.allSatisfy({ $0["name"] as? String == "CLI" }) ? "Codex CLI · " : ""
        return ServiceStatus(condition: active ? .degraded : .operational,
                             detail: scope + (active ? "官方报告相关事件仍在处理" : "官方报告服务正常"), fetchedAt: now)
    }

    private static func incidentIO(_ summary: [String: Any], now: Date) throws -> ServiceStatus {
        guard let structure = summary["structure"] as? [String: Any],
              let items = structure["items"] as? [[String: Any]],
              let affected = summary["affected_components"] as? [[String: Any]] else { throw ProviderReadError.invalidResponse }
        var ids: Set<String> = []
        for item in items {
            if let group = item["group"] as? [String: Any], group["hidden"] as? Bool != true,
               let children = group["components"] as? [[String: Any]] {
                for child in children where child["hidden"] as? Bool != true {
                    if (group["name"] as? String)?.localizedCaseInsensitiveContains("codex") == true ||
                       (child["name"] as? String)?.localizedCaseInsensitiveContains("codex") == true,
                       let id = child["component_id"] as? String { ids.insert(id) }
                }
            }
            if let component = item["component"] as? [String: Any], component["hidden"] as? Bool != true,
               (component["name"] as? String)?.localizedCaseInsensitiveContains("codex") == true,
               let id = component["component_id"] as? String { ids.insert(id) }
        }
        guard !ids.isEmpty else { return ServiceStatus(condition: .unknown, detail: "官方状态未提供 Codex 组件", fetchedAt: now) }
        // A complete incident.io affected_components list defines unchanged leaves
        // as operational. Missing lists and unrecognized states never become healthy.
        let relevant = affected.filter { ($0["component_id"] as? String).map(ids.contains) ?? false }
        let states = relevant.compactMap { $0["status"] as? String }
        guard states.count == relevant.count else { throw ProviderReadError.invalidResponse }
        let known = Set(["operational", "degraded_performance", "partial_outage", "major_outage", "under_maintenance"])
        guard states.allSatisfy({ known.contains($0) }) else {
            return ServiceStatus(condition: .unknown, detail: "官方组件状态尚未识别", fetchedAt: now)
        }
        if states.contains("major_outage") { return ServiceStatus(condition: .outage, detail: "官方报告 Codex 服务中断", fetchedAt: now) }
        if states.contains(where: { $0 != "operational" }) { return ServiceStatus(condition: .degraded, detail: "官方报告 Codex 部分服务异常", fetchedAt: now) }
        return ServiceStatus(condition: .operational, detail: "官方报告 Codex 服务正常", fetchedAt: now)
    }
}

private final class StatusSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public actor ServiceStatusClient {
    public init() {}
    public func fetch(_ provider: UsageProvider) async -> ServiceStatus {
        let endpoint: String
        switch provider {
        case .codex: endpoint = "https://status.openai.com/proxy/status.openai.com"
        case .deepseek: endpoint = "https://status.deepseek.com/api/v2/summary.json"
        case .antigravity: endpoint = "https://status.cloud.google.com/incidents.json"
        case .opencodego, .workbuddy:
            return ServiceStatus(condition: .unknown, detail: "暂未提供独立的官方状态数据")
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: StatusSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: URL(string: endpoint)!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.expectedContentLength <= 2 * 1024 * 1024 else { throw ProviderReadError.invalidResponse }
            var data = Data(); data.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                guard data.count < 2 * 1024 * 1024 else { throw ProviderReadError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try ServiceStatusParser.parse(data, provider: provider)
        } catch {
            return ServiceStatus(condition: .unknown, detail: "官方状态读取失败 · 点击查看网站")
        }
    }
}
