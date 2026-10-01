import Foundation
import AppKit
import Security

public enum CaptureLaunchError: Error, LocalizedError {
    case alreadyRunning, unavailable, invalidSignature
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "请先在 Codex / ChatGPT 中结束或暂停任务，再自行退出客户端，然后点击此按钮。不会自动关闭正在运行的客户端。"
        case .unavailable: "未找到 Codex 或 ChatGPT 桌面客户端。"
        case .invalidSignature: "客户端的 OpenAI 签名验证失败，未启动。"
        }
    }
}

public enum ModelCaptureLauncher {
    /// No launchd/global environment, bundle, config, authentication or trust-store changes.
    /// Only subsequent responses can become observable; missing historical events are not inferred.
    @MainActor public static func launch(detailed: Bool = false, environment: [String: String] = [:]) async throws {
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            ["com.openai.codex", "com.openai.chat"].contains($0.bundleIdentifier ?? "")
        }) else { throw CaptureLaunchError.alreadyRunning }
        guard let app = AgentDiscovery.app("com.openai.codex", names: ["Codex"])
            ?? AgentDiscovery.app("com.openai.chat", names: ["ChatGPT"]) else { throw CaptureLaunchError.unavailable }
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and (identifier \"com.openai.codex\" or identifier \"com.openai.chat\")"
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw CaptureLaunchError.invalidSignature }
        let configuration = NSWorkspace.OpenConfiguration()
        var values = environment
        values["RUST_LOG"] = detailed ? detailedLoggingFilter : loggingFilter
        configuration.environment = values
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
    public static let loggingFilter = "warn,codex_core::session=info,codex_core::codex=info"
    public static let detailedLoggingFilter = loggingFilter + ",codex_api::sse=trace,tungstenite::protocol=trace,tungstenite::protocol::frame=off"
}
