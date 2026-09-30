import Foundation
import CryptoKit

public enum EvidenceKind: String, Codable, Sendable {
    case threadSetting, turnContext, runtimeTrace, reroute, responseModel, responseHeader, safetyBuffering

    public var label: String {
        switch self {
        case .threadSetting: "任务设置"
        case .turnContext: "轮次记录"
        case .runtimeTrace: "运行日志"
        case .reroute: "明确路由事件"
        case .responseModel: "响应模型字段"
        case .responseHeader: "服务端模型响应头"
        case .safetyBuffering: "安全缓冲事件"
        }
    }
    public var isServerClaim: Bool { self == .reroute || self == .responseModel || self == .responseHeader }
}

public struct ModelEvidence: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: EvidenceKind
    public var model: String
    public var fromModel: String?
    public var timestamp: Date
    public var source: String
    public var locator: String
    public var responseID: String?
    public var reason: String?
    public var fasterModel: String?
    public var bufferingEnabled: Bool?
    public var field: String?

    public init(kind: EvidenceKind, model: String, fromModel: String? = nil,
                timestamp: Date, source: String, locator: String,
                responseID: String? = nil, reason: String? = nil,
                fasterModel: String? = nil, bufferingEnabled: Bool? = nil, field: String? = nil) {
        self.kind = kind; self.model = model; self.fromModel = fromModel
        self.timestamp = timestamp; self.source = source; self.locator = locator
        self.responseID = responseID; self.reason = reason
        self.fasterModel = fasterModel; self.bufferingEnabled = bufferingEnabled
        self.field = field
        var identity = [kind.rawValue, model, fromModel ?? "", source, locator, responseID ?? ""]
        if let field { identity.append(field) }
        id = stableID(identity.joined(separator: "\u{1f}"))
    }
}

public enum TurnStatus: String, Codable, Sendable {
    case running, unconfirmed, completed, interrupted, failed, unknown
    public var label: String {
        switch self {
        case .running: "运行中"
        case .unconfirmed: "活动待确认"
        case .completed: "已完成"
        case .interrupted: "已中断"
        case .failed: "失败"
        case .unknown: "状态未知"
        }
    }
}

public struct TurnRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var startedAt: Date
    public var completedAt: Date?
    public var lastActivity: Date
    public var status: TurnStatus
    public var requestedModel: String?
    public var effort: String?
    public var tokenUsage: TokenUsage?
    public var evidence: [ModelEvidence]

    public init(id: String, startedAt: Date, status: TurnStatus = .unknown) {
        self.id = id; self.startedAt = startedAt; self.lastActivity = startedAt
        self.status = status; self.evidence = []
    }

    public var serverEvidence: [ModelEvidence] { evidence.filter { $0.kind.isServerClaim } }
    public var safetyEvidence: [ModelEvidence] { evidence.filter { $0.kind == .safetyBuffering } }
    public var effectiveServerEvidence: [ModelEvidence] {
        let claims = serverEvidence
        var headerResponseIDs = Set(claims.filter { $0.kind == .responseHeader }.compactMap(\.responseID))
        // Metadata can precede the ID. Its header takes precedence over the next
        // response model in that same source, never every subsequent response in a turn.
        for header in claims where header.kind == .responseHeader && header.responseID == nil {
            if let next = claims.filter({ $0.kind == .responseModel && $0.source == header.source && $0.timestamp >= header.timestamp })
                .sorted(by: { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }).first?.responseID {
                headerResponseIDs.insert(next)
            }
        }
        return claims.filter { $0.kind != .responseModel || $0.responseID.map { !headerResponseIDs.contains($0) } ?? true }
    }
    public var reportedModel: String? { effectiveServerEvidence.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }.last?.model }
    public var recordedModel: String? {
        requestedModel ?? evidence.last(where: { $0.kind == .turnContext || $0.kind == .runtimeTrace })?.model
    }
    public var hasModelDifference: Bool {
        effectiveServerEvidence.contains { e in
            guard e.kind.isServerClaim else { return false }
            if let from = e.fromModel { return from != e.model }
            return requestedModel.map { $0 != e.model } ?? false
        }
    }
    public var isOpen: Bool { status == .running || status == .unconfirmed }
}

public struct ThreadRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var cwd: String
    public var provider: String
    public var selectedModel: String?
    public var source: String
    public var parentID: String?
    public var archived: Bool
    public var updatedAt: Date
    public var rolloutPath: String?
    public var turns: [TurnRecord]
    public var firstDetectedAt: Date
    public var lastDetectedAt: Date

    public init(id: String, title: String = "未命名任务", cwd: String = "", provider: String = "",
                source: String = "local", updatedAt: Date = .distantPast) {
        self.id = id; self.title = title; self.cwd = cwd; self.provider = provider
        self.source = source; self.archived = false; self.updatedAt = updatedAt
        self.turns = []; self.firstDetectedAt = Date(); self.lastDetectedAt = Date()
    }
    public var latestTurn: TurnRecord? { turns.max { $0.startedAt < $1.startedAt } }
    public var conciseTitle: String {
        let line = title.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? title
        return line.count > 72 ? String(line.prefix(72)) + "…" : line
    }
    public var isRunning: Bool { turns.contains { $0.status == .running } }
    public var isUnconfirmed: Bool { !isRunning && turns.contains { $0.status == .unconfirmed } }
    public var hasModelDifference: Bool { turns.contains { $0.hasModelDifference } }
    public var hasServerEvidence: Bool { turns.contains { !$0.serverEvidence.isEmpty } }
    public var isInternal: Bool {
        source.contains("review") || source.contains("memory") ||
        (selectedModel?.hasPrefix("codex-auto-") ?? false) ||
        (latestTurn?.recordedModel?.hasPrefix("codex-auto-") ?? false)
    }
    public var displayModel: String { latestTurn?.reportedModel ?? latestTurn?.recordedModel ?? selectedModel ?? "暂无模型记录" }
    public var statusLabel: String {
        isRunning ? "运行中" : isUnconfirmed ? "活动待确认" : latestTurn?.status.label ?? "暂无轮次"
    }
}

public struct ScanDiagnostic: Codable, Identifiable, Sendable, Equatable {
    public var id: String { source + message }
    public var source: String
    public var message: String
    public init(source: String, message: String) { self.source = source; self.message = message }
}

public struct ScanResult: Codable, Sendable {
    public var scannedAt: Date
    public var threads: [ThreadRecord]
    public var diagnostics: [ScanDiagnostic]
    public var filesRead: Int
    public var bytesRead: UInt64
    public var duration: TimeInterval
    public var requests: [RequestRecord]
    public var logCoverage: LogCoverage?
    public var sources: [ScanSourceStatus]?
    public init(scannedAt: Date = Date(), threads: [ThreadRecord] = [], diagnostics: [ScanDiagnostic] = [],
                filesRead: Int = 0, bytesRead: UInt64 = 0, duration: TimeInterval = 0,
                requests: [RequestRecord] = [], logCoverage: LogCoverage? = nil, sources: [ScanSourceStatus] = []) {
        self.scannedAt = scannedAt; self.threads = threads; self.diagnostics = diagnostics
        self.filesRead = filesRead; self.bytesRead = bytesRead; self.duration = duration
        self.requests = requests; self.logCoverage = logCoverage
        self.sources = sources
    }
}

public struct ScanSourceStatus: Codable, Identifiable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case available, partial, missing, disabled, unreadable
        public var label: String {
            switch self {
            case .available: "已读取"
            case .partial: "部分读取"
            case .missing: "未找到"
            case .disabled: "未启用"
            case .unreadable: "无法读取"
            }
        }
    }
    public var id: String
    public var title: String
    public var path: String
    public var state: State
    public var detail: String
    public init(id: String, title: String, path: String, state: State, detail: String) {
        self.id = id; self.title = title; self.path = path; self.state = state; self.detail = detail
    }
}

public func stableID(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

public enum LensDate {
    public static func parse(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
