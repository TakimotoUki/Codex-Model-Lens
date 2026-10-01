import Foundation

public struct ServiceEvent: Sendable, Equatable, Identifiable {
    public var id: String { url.absoluteString }
    public var title: String
    public var url: URL
    public var updatedAt: Date?
    public var phase: String?
}
public enum StatusFeedParser {
    public static func parse(_ data: Data, provider: UsageProvider, now: Date = Date()) throws -> ServiceStatus {
        guard data.count <= 2 * 1024 * 1024 else { throw ProviderReadError.tooLarge }
        let text = String(decoding: data, as: UTF8.self).uppercased()
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw ProviderReadError.invalidResponse }
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.validRoot, !delegate.invalid else { throw ProviderReadError.invalidResponse }
        var events: [ServiceEvent] = []
        for fields in delegate.items {
            let title = clean(fields["title"] ?? "")
            let body = clean(fields["description"] ?? fields["summary"] ?? fields["content:encoded"] ?? "")
            guard !title.isEmpty else { continue }
            if provider == .codex, !title.localizedCaseInsensitiveContains("codex"), !body.localizedCaseInsensitiveContains("codex") { continue }
            guard let url = URL(string: fields["link"] ?? fields["guid"] ?? fields["id"] ?? ""), url.scheme == "https",
                  url.host == provider.statusURL.host, url.user == nil, url.password == nil else { continue }
            let stamp = fields["updated"] ?? fields["pubDate"] ?? fields["published"]
            let date = stamp.flatMap(date)
            let phase = capture(#"(?i)\bStatus:\s*(resolved|postmortem|monitoring|identified|investigating|scheduled|in_progress|completed)\b"#, body)
                ?? capture(#"(?i)^(RESOLVED|MONITORING|IDENTIFIED|INVESTIGATING):"#, title)
            let event = ServiceEvent(title: String(title.prefix(180)), url: url, updatedAt: date, phase: phase?.lowercased())
            if let index = events.firstIndex(where: { $0.id == event.id }) {
                if (event.updatedAt ?? .distantPast) > (events[index].updatedAt ?? .distantPast) { events[index] = event }
            } else { events.append(event) }
        }
        events.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        let active = events.contains { ["monitoring", "identified", "investigating", "in_progress"].contains($0.phase ?? "") }
        let condition: ServiceCondition = provider == .antigravity ? .unknown : active ? .degraded : events.isEmpty || events.contains(where: { $0.phase == nil }) ? .unknown : .operational
        let detail = provider == .antigravity ? "Google Cloud 参考订阅 · 未覆盖 Antigravity" : active ? "官方订阅有未解决事件" : condition == .operational ? "官方订阅暂无未解决事件" : "官方订阅未提供当前组件状态"
        return ServiceStatus(condition: condition, detail: detail, fetchedAt: now, events: Array(events.prefix(3)))
    }
    private static func clean(_ value: String) -> String {
        let stripped = value.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        return stripped.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func capture(_ pattern: String, _ value: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern), let match = r.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    private static func date(_ value: String) -> Date? {
        if let date = LensDate.parse(value) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: value)
    }
}
private final class FeedDelegate: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    var validRoot = false, invalid = false
    private var depth = 0, itemDepth = 0
    private var fields: [String: String] = [:]
    private var field: String?
    private var fieldDepth = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1 { validRoot = name == "rss" || name == "feed" }
        guard depth <= 32, items.count < 128 else { invalid = true; parser.abortParsing(); return }
        if name == "item" || name == "entry" { itemDepth = depth; fields = [:]; field = nil }
        else if itemDepth > 0, depth == itemDepth + 1 {
            if name == "link", let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" { fields["link"] = href }
            if ["title", "link", "guid", "id", "pubDate", "updated", "published", "description", "summary", "content:encoded"].contains(name) {
                field = name; fieldDepth = depth
                if fields[name] == nil { fields[name] = "" }
            }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string, parser: parser) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { append(String(decoding: CDATABlock, as: UTF8.self), parser: parser) }
    private func append(_ value: String, parser: XMLParser) {
        guard let field else { return }
        guard (fields[field]?.utf8.count ?? 0) + value.utf8.count <= 128 * 1024 else { invalid = true; parser.abortParsing(); return }
        fields[field, default: ""] += value
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if depth == fieldDepth { field = nil }
        if depth == itemDepth { items.append(fields); fields = [:]; itemDepth = 0; field = nil }
        depth -= 1
    }
}
