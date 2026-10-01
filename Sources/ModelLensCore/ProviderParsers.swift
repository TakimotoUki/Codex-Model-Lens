import Foundation
import CoreFoundation

public enum ProviderReadError: Error, LocalizedError {
    case missingLogin, unavailable, invalidResponse, rejected, tooLarge, unsupported, encryptedLogin
    public var errorDescription: String? {
        switch self {
        case .missingLogin: "未找到可用登录凭据，请登录对应 Agent 或添加账户。"
        case .unavailable: "用量服务暂不可用；已保留原缓存时间。"
        case .invalidResponse: "接口没有返回可确认的用量字段。"
        case .rejected: "登录已过期或接口拒绝访问，请重新登录。"
        case .tooLarge: "响应超过元数据大小限制，已停止读取。"
        case .encryptedLogin: "WorkBuddy 新版加密登录尚不支持余额读取；请查看官方套餐与用量页面。"
        case .unsupported: "当前版本尚未提供支持的用量接口。"
        }
    }
}
enum ProviderParsers {
    static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty, string.count <= 200,
              !string.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else { return nil }
        return string
    }
    static func deepseek(_ root: [String: Any], account: String) throws -> UsageSnapshot {
        guard let rows = root["balance_infos"] as? [[String: Any]],
              let balance = rows.first(where: { $0["currency"] as? String == "USD" }) ?? rows.first,
              let total = number(balance["total_balance"]), let currency = text(balance["currency"]) else { throw ProviderReadError.invalidResponse }
        var value = UsageSnapshot(provider: .deepseek, accountID: account, source: "DeepSeek 官方余额 API")
        value.balance = total; value.currency = currency
        value.paidBalance = number(balance["topped_up_balance"]); value.grantedBalance = number(balance["granted_balance"])
        value.note = root["is_available"] as? Bool == false ? "余额当前不可用于 API 调用" : "API Key 提供余额；Token 需要平台账户用量报告。"
        return value
    }
    static func opencode(_ root: [String: Any], account: String, now: Date = Date()) throws -> UsageSnapshot {
        guard let usage = root["usage"] as? [String: Any] else { throw ProviderReadError.invalidResponse }
        var value = UsageSnapshot(provider: .opencodego, accountID: account, source: "OpenCode Go 官方 Usage API")
        for (key, title) in [("rolling", "5 小时额度"), ("weekly", "周额度"), ("monthly", "月额度")] {
            guard let meter = usage[key] as? [String: Any], let used = number(meter["percent"]) else { continue }
            let reset = LensDate.parse(meter["resetAt"] ?? meter["resetTime"]) ?? number(meter["resetInSec"]).flatMap { $0 >= 0 ? now.addingTimeInterval($0) : nil }
            value.meters.append(UsageMeter(id: key, title: title, remainingPercent: max(0, min(100, 100 - used)), resetsAt: reset))
        }
        guard !value.meters.isEmpty else { throw ProviderReadError.invalidResponse }
        value.plan = "OpenCode Go"; return value
    }
    static func opencodeConsole(_ root: [String: Any], billing: [String: Any], account: String) throws -> UsageSnapshot {
        var value = UsageSnapshot(provider: .opencodego, accountID: account, source: "OpenCode 官方工作区 API")
        let access = root["access"] as? [String: Any] ?? [:]
        let meters = access["meters"] as? [String: Any] ?? [:]
        for (key, title) in [("fiveHour", "5 小时额度"), ("week", "周额度"), ("month", "月额度")] {
            guard let meter = meters[key] as? [String: Any], let used = number(meter["usedMicroCents"]), let limit = number(meter["limitMicroCents"]), used >= 0, limit > 0 else { continue }
            value.meters.append(UsageMeter(id: key, title: title, remainingPercent: max(0, min(100, 100 * (1 - used / limit))),
                resetsAt: LensDate.parse(meter["resetsAt"] ?? meter["resetAt"]) ?? (key == "month" ? LensDate.parse(access["endsAt"]) : nil)))
        }
        if let balance = number(billing["balanceMicroCents"]) { value.balance = balance / 100_000_000; value.currency = "USD" }
        guard !value.meters.isEmpty || value.balance != nil else { throw ProviderReadError.invalidResponse }
        value.plan = "OpenCode Go · 工作区"; value.note = "官方工作区额度；不混入本机其他账户的 Token。"
        return value
    }
    static func antigravity(summary: [String: Any], status: [String: Any], account: String = "local") throws -> UsageSnapshot {
        let user = status["userStatus"] as? [String: Any] ?? [:]
        var value = UsageSnapshot(provider: .antigravity, accountID: account, source: "Antigravity 本机语言服务")
        // userTier is the real quota plan; planStatus can contain a legacy generic Pro template.
        value.plan = text((user["userTier"] as? [String: Any])?["name"])
        let payload = summary["quotaSummary"] as? [String: Any] ?? summary
        if let groups = payload["groups"] as? [[String: Any]] {
            for (index, group) in groups.enumerated() {
                guard let label = text(group["displayName"]), let buckets = group["buckets"] as? [[String: Any]] else { continue }
                for (ordinal, bucket) in buckets.enumerated() {
                    let remaining = bucket["remaining"] as? [String: Any] ?? [:]
                    let fraction = number(remaining["remainingFraction"]) ?? (remaining["case"] as? String == "remainingFraction" ? number(remaining["value"]) : nil)
                    value.meters.append(UsageMeter(id: "\(index)-\(ordinal)", title: label + " · " + (text(bucket["displayName"]) ?? "额度"),
                        remainingPercent: fraction.map { max(0, min(100, $0 * 100)) }, resetsAt: LensDate.parse(bucket["resetTime"] ?? bucket["resetAt"])))
                }
            }
        }
        if value.meters.isEmpty, let configs = user["cascadeModelConfigData"] as? [String: Any], let rows = configs["clientModelConfigs"] as? [[String: Any]] {
            for (family, label) in [("gemini", "Gemini Models"), ("other", "Claude / GPT models")] {
                let matching = rows.filter { row in
                    let name = (row["label"] as? String ?? "").lowercased()
                    return family == "gemini" ? name.contains("gemini") : name.contains("claude") || name.contains("gpt")
                }.compactMap { $0["quotaInfo"] as? [String: Any] }
                guard !matching.isEmpty else { continue }
                let fractions = matching.compactMap { number($0["remainingFraction"]) }
                let reset = matching.compactMap { LensDate.parse($0["resetTime"]) }.min()
                let percent = fractions.min().map { max(0, min(100, $0 * 100)) }
                value.meters.append(UsageMeter(id: family, title: label, remainingPercent: percent, resetsAt: reset))
            }
            value.note = "旧版模型额度接口未标注额度周期；缺失比例保持未知。Token 统计未由此接口提供。"
        } else { value.note = "额度来自语言服务；Token 统计未由此接口提供。" }
        guard !value.meters.isEmpty else { throw ProviderReadError.invalidResponse }
        return value
    }
    static func workbuddy(_ root: [String: Any], account: String, enterprise: Bool) throws -> UsageSnapshot {
        if let code = number(root["code"]), code != 0 { throw ProviderReadError.rejected }
        var value = UsageSnapshot(provider: .workbuddy, accountID: account, source: "WorkBuddy 官方计费 API")
        let data = root["data"] as? [String: Any] ?? [:]
        if enterprise {
            let usage = data["data"] as? [String: Any] ?? data
            guard let total = number(usage["limitNum"]) else { throw ProviderReadError.invalidResponse }
            if total == -1 { value.note = "企业账户报告不限量"; value.plan = "企业"; return value }
            guard let used = number(usage["credit"]), total >= 0, used >= 0 else { throw ProviderReadError.invalidResponse }
            value.creditTotal = total; value.balance = max(0, total - used); value.currency = "积分"; value.plan = "企业"
            value.meters = [UsageMeter(id: "enterprise", title: "积分额度", remainingPercent: total > 0 ? max(0, 100 * (total - used) / total) : 0, resetsAt: LensDate.parse(usage["cycleResetTime"]))]
        } else {
            let response = data["Response"] as? [String: Any] ?? [:]
            let content = response["Data"] as? [String: Any] ?? [:]
            guard let accounts = content["Accounts"] as? [[String: Any]], !accounts.isEmpty else { throw ProviderReadError.invalidResponse }
            var total = 0.0, left = 0.0
            for (index, entry) in accounts.enumerated() {
                guard let capacity = number(entry["CycleCapacitySizePrecise"]), let remain = number(entry["CycleCapacityRemainPrecise"]), capacity >= 0, remain >= 0 else { throw ProviderReadError.invalidResponse }
                total += capacity; left += remain
                guard total.isFinite && left.isFinite else { throw ProviderReadError.invalidResponse }
                value.meters.append(UsageMeter(id: String(index), title: text(entry["PackageName"]) ?? "积分包",
                    remainingPercent: capacity > 0 ? min(100, remain / capacity * 100) : 0, resetsAt: LensDate.parse(entry["CycleEndTime"]).map { $0.addingTimeInterval(1) }))
            }
            value.creditTotal = total; value.balance = left; value.currency = "积分"; value.plan = text(accounts.first?["PackageName"])
        }
        value.note = "积分不是 Token 或货币；此接口未提供 Token 总数。"; return value
    }
}
