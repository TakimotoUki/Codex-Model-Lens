import Foundation
import AppKit
import Observation
import ModelLensCore

@MainActor @Observable final class NetworkCaptureController {
    var ready = false
    var busy = false
    var isRunning = false
    var message = "网络响应采集未启用"
    private let session: NetworkCaptureSession
    private var task: Task<Void, Never>?
    init(directory: URL) {
        session = NetworkCaptureSession(directory: directory)
        Task { ready = await session.ready() }
    }
    func install() {
        guard !busy else { return }; busy = true; message = "正在下载并校验官方组件（约 52 MB）…"
        task = Task {
            defer { busy = false; task = nil }
            do { try await session.install(); ready = true; message = "网络采集组件已就绪" }
            catch { message = "组件准备失败：\(error.localizedDescription)" }
        }
    }
    func launch(outputDirectory: URL, codexHome: URL, dataDirectory: URL) {
        guard !busy, !isRunning else { return }
        guard !NSWorkspace.shared.runningApplications.contains(where: { ["com.openai.codex", "com.openai.chat"].contains($0.bundleIdentifier ?? "") }) else {
            message = CaptureLaunchError.alreadyRunning.localizedDescription; return
        }
        guard let script = Bundle.main.url(forResource: "model_capture", withExtension: "py", subdirectory: "NetworkCapture") else {
            message = "缺少网络采集脚本"; return
        }
        busy = true; message = "正在启动本进程的采集代理…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let environment = try await session.start(script: script, outputDirectory: outputDirectory)
                message = "正在验证官方 Codex 的 TLS 与账户读取…"
                _ = try await OfficialCodexClient().account(codexHome: codexHome, dataDirectory: dataDirectory, captureEnvironment: environment)
                try await ModelCaptureLauncher.launch(environment: environment)
                isRunning = true; message = "网络采集已启用 · 等待对应任务的新响应"
            } catch { await session.stop(); message = error.localizedDescription }
        }
    }
    func stop() {
        guard !NSWorkspace.shared.runningApplications.contains(where: { ["com.openai.codex", "com.openai.chat"].contains($0.bundleIdentifier ?? "") }) else {
            message = "请先退出使用采集代理的客户端，再停止采集，避免中断正在进行的请求。"; return
        }
        task?.cancel()
        Task { await session.stop(); isRunning = false; message = "网络采集已停止；正常打开 Codex 即可恢复原连接" }
    }
    func shutdown() { task?.cancel(); Task { await session.stop(); isRunning = false } }
}
