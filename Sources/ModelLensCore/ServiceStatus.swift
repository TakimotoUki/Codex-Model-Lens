import Foundation

public enum ServiceCondition: String, Sendable { case operational, degraded, outage, unknown }
public struct ServiceStatusItem: Sendable, Equatable, Identifiable {
    public var id: String { url.absoluteString }
    public var title: String
    public var condition: ServiceCondition
    public var detail: String
    public var url: URL
    public init(title: String, condition: ServiceCondition, detail: String, url: URL) {
        self.title = title; self.condition = condition; self.detail = detail; self.url = url
    }
}
public struct ServiceStatus: Sendable, Equatable {
    public var condition: ServiceCondition
    public var detail: String
    public var fetchedAt: Date
    public var events: [ServiceEvent]
    public var items: [ServiceStatusItem]
    public init(condition: ServiceCondition, detail: String, fetchedAt: Date = Date(), events: [ServiceEvent] = [], items: [ServiceStatusItem] = []) {
        self.condition = condition; self.detail = detail; self.fetchedAt = fetchedAt; self.events = events
        self.items = items
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
            return try GoogleStatusParser.cloud(root, now: now)
        }
        guard [.codex, .deepseek].contains(provider), let object = root as? [String: Any],
              let components = object["components"] as? [[String: Any]] else { throw ProviderReadError.invalidResponse }
        let relevant = components.filter { row in
            guard let name = row["name"] as? String else { return false }
            if provider == .codex { return row["hidden"] as? Bool != true }
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
        // OpenAI now covers every public component, including ChatGPT and API.
        let ids = Set(relevant.compactMap { $0["id"] as? String })
        let incidents = object["incidents"] as? [[String: Any]] ?? []
        let active = incidents.contains { row in
            guard let status = row["status"] as? String, status != "resolved", status != "postmortem",
                  let affected = row["components"] as? [[String: Any]] else { return false }
            return affected.contains { ($0["id"] as? String).map(ids.contains) ?? false }
        }
        return ServiceStatus(condition: active ? .degraded : .operational,
                             detail: active ? "官方报告相关事件仍在处理" : "官方报告全部服务正常", fetchedAt: now)
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
                    if let id = child["component_id"] as? String { ids.insert(id) }
                }
            }
            if let component = item["component"] as? [String: Any], component["hidden"] as? Bool != true,
               let id = component["component_id"] as? String { ids.insert(id) }
        }
        guard !ids.isEmpty else { return ServiceStatus(condition: .unknown, detail: "官方状态未提供公开组件", fetchedAt: now) }
        // A complete incident.io affected_components list defines unchanged leaves
        // as operational. Missing lists and unrecognized states never become healthy.
        let relevant = affected.filter { ($0["component_id"] as? String).map(ids.contains) ?? false }
        let states = relevant.compactMap { $0["status"] as? String }
        guard states.count == relevant.count else { throw ProviderReadError.invalidResponse }
        let known = Set(["operational", "degraded_performance", "partial_outage", "major_outage", "under_maintenance"])
        guard states.allSatisfy({ known.contains($0) }) else {
            return ServiceStatus(condition: .unknown, detail: "官方组件状态尚未识别", fetchedAt: now)
        }
        if states.contains("major_outage") { return ServiceStatus(condition: .outage, detail: "官方报告部分服务中断", fetchedAt: now) }
        if states.contains(where: { $0 != "operational" }) { return ServiceStatus(condition: .degraded, detail: "官方报告部分服务异常", fetchedAt: now) }
        return ServiceStatus(condition: .operational, detail: "官方报告全部公开服务正常", fetchedAt: now)
    }
}

private final class StatusSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public actor ServiceStatusClient {
    private var publicGoogleKey: (String, Date)?
    public init() {}
    public func fetch(_ provider: UsageProvider) async -> ServiceStatus {
        let feed: String
        switch provider {
        case .codex: feed = "https://status.openai.com/feed.rss"
        case .deepseek: feed = "https://status.deepseek.com/feed.rss"
        case .antigravity: feed = "https://status.cloud.google.com/en/feed.atom"
        case .opencodego, .workbuddy: return ServiceStatus(condition: .unknown, detail: "暂未提供独立的官方状态数据")
        }
        async let subscription = read(feed, accept: "application/rss+xml, application/atom+xml, application/xml")
        var status: ServiceStatus?
        if provider == .codex, let data = await read("https://status.openai.com/proxy/status.openai.com", accept: "application/json") {
            status = try? ServiceStatusParser.parse(data, provider: provider)
        }
        if provider == .antigravity, let data = await read("https://status.cloud.google.com/incidents.json", accept: "application/json") {
            status = try? ServiceStatusParser.parse(data, provider: provider)
        }
        if let data = await subscription, let parsed = try? StatusFeedParser.parse(data, provider: provider) {
            if status != nil { status?.events = parsed.events }
            else { status = parsed }
        }
        if provider == .antigravity {
            let gemini = await geminiStatus()
            let sources: [(String, ServiceStatus?, URL)] = [
                ("Gemini API / AI Studio", gemini, URL(string: "https://aistudio.google.com/status")!),
                ("Google Cloud", status, provider.statusURL)
            ]
            let items = sources.compactMap { title, value, url -> ServiceStatusItem? in
                guard let value, value.condition != .unknown else { return nil }
                return ServiceStatusItem(title: title, condition: value.condition, detail: value.detail, url: url)
            }
            if !items.isEmpty {
                let states = items.map(\.condition)
                let condition: ServiceCondition = states.contains(.outage) ? .outage : states.contains(.degraded) ? .degraded : .operational
                let events = sources.compactMap { $0.1 }.flatMap(\.events).sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                return ServiceStatus(condition: condition, detail: "官方公开状态 · \(items.count) 个数据源", events: Array(events.prefix(3)), items: items)
            }
        }
        return status ?? ServiceStatus(condition: .unknown, detail: "官方状态读取失败 · 点击查看网站")
    }
    private func geminiStatus() async -> ServiceStatus? {
        var key = publicGoogleKey.flatMap { Date().timeIntervalSince($0.1) < 3600 ? $0.0 : nil }
        if key == nil, let html = await read("https://aistudio.google.com/status", accept: "text/html"),
           let value = GoogleStatusParser.publicClientKey(html) {
            publicGoogleKey = (value, Date()); key = value
        }
        guard let key else { return nil }
        var request = URLRequest(url: URL(string: "https://alkalimakersuite-pa.clients6.google.com/$rpc/google.internal.alkali.applications.makersuite.v1.MakerSuiteService/ListIncidentsHistory")!)
        request.httpMethod = "POST"; request.httpBody = Data("[]".utf8)
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("https://aistudio.google.com", forHTTPHeaderField: "Origin")
        request.setValue("https://aistudio.google.com/", forHTTPHeaderField: "Referer")
        guard let data = await read(request), let result = try? GoogleStatusParser.gemini(data) else {
            publicGoogleKey = nil; return nil
        }
        return result
    }
    private func read(_ endpoint: String, accept: String) async -> Data? {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return await read(request)
    }
    private func read(_ request: URLRequest) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: StatusSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.expectedContentLength <= 2 * 1024 * 1024 else { return nil }
            var data = Data(); data.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                guard data.count < 2 * 1024 * 1024 else { return nil }; data.append(byte)
            }
            try Task.checkCancellation(); return data
        } catch { return nil }
    }
}
