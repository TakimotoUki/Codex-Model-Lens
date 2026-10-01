import Foundation

public enum UsageProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case codex, antigravity, opencodego, deepseek, workbuddy
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .opencodego: "OpenCode Go"
        case .deepseek: "DeepSeek"
        case .workbuddy: "WorkBuddy"
        }
    }
    public var symbol: String {
        switch self {
        case .codex: "terminal"
        case .antigravity: "sparkles"
        case .opencodego: "chevron.left.forwardslash.chevron.right"
        case .deepseek: "water.waves"
        case .workbuddy: "briefcase"
        }
    }
    public var statusURL: URL {
        let value = switch self {
        case .codex: "https://status.openai.com/"
        case .deepseek: "https://status.deepseek.com/"
        case .antigravity: "https://status.cloud.google.com/"
        case .opencodego: "https://opencode.ai/"
        case .workbuddy: "https://www.workbuddy.cn/docs/workbuddy/Usage"
        }
        return URL(string: value)!
    }
    public var supportsServiceStatus: Bool { [.codex, .antigravity, .deepseek].contains(self) }
    public var statusScope: String {
        switch self {
        case .codex: "OpenAI 服务状态"
        case .antigravity: "Google 服务状态"
        case .deepseek: "DeepSeek 服务状态"
        case .opencodego, .workbuddy: ""
        }
    }
}

public struct UsageMeter: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var remainingPercent: Double?
    public var resetsAt: Date?
    public init(id: String, title: String, remainingPercent: Double? = nil, resetsAt: Date? = nil) {
        self.id = id; self.title = title; self.remainingPercent = remainingPercent; self.resetsAt = resetsAt
    }
}
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var provider: UsageProvider
    public var accountID: String
    public var fetchedAt: Date = Date()
    public var plan: String?
    public var meters: [UsageMeter] = []
    public var balance: Double?
    public var paidBalance: Double?
    public var grantedBalance: Double?
    public var creditTotal: Double?
    public var currency: String?
    public var tokens: Int64?
    public var todayTokens: Int64?
    public var spentCredits: Double?
    public var availableResetCards: Int64?
    public var resetCardExpiresAt: Date?
    public var source: String
    public var note: String?
    public init(provider: UsageProvider, accountID: String, source: String) {
        self.provider = provider; self.accountID = accountID; self.source = source
    }
}
public struct UsageAccount: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var provider: UsageProvider
    public var label: String
    public var credentialKind: String
    public init(id: String = UUID().uuidString, provider: UsageProvider, label: String, credentialKind: String = "apiKey") {
        self.id = id; self.provider = provider; self.label = label; self.credentialKind = credentialKind
    }
}
public enum CompactNumber {
    public static func tokens(_ value: Int64) -> String {
        let magnitude = Double(value)
        let divisor: Double, suffix: String
        if abs(magnitude) >= 100_000_000 { divisor = 1_000_000_000; suffix = "B" }
        else if abs(magnitude) >= 1_000_000 { divisor = 1_000_000; suffix = "M" }
        else if abs(magnitude) >= 1_000 { divisor = 1_000; suffix = "k" }
        else { return String(value) }
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), magnitude / divisor)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + suffix
    }
}
