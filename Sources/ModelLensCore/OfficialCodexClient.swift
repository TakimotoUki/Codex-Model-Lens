import Foundation
import Security
import Darwin

public enum OfficialClientError: Error, LocalizedError {
    case unavailable, invalidSignature, noLogin, invalidModel, serviceUnavailable, timeout
    public var errorDescription: String? {
        switch self {
        case .unavailable: "未找到官方 Codex 客户端内置的 CLI。"
        case .invalidSignature: "CLI 签名验证失败，已停止读取登录信息。"
        case .noLogin: "未找到 ChatGPT 文件登录信息，请先在 Codex 中登录。"
        case .invalidModel: "请输入有效模型名。"
        case .serviceUnavailable: "官方接口没有返回可读取数据，请稍后刷新。"
        case .timeout: "读取超时，请稍后重试。"
        }
    }
}

public actor OfficialCodexClient {
    public init() {}
    private func verifiedBinary() async throws -> URL {
        guard let binary = await AgentDiscovery.codexBinary() else { throw OfficialClientError.unavailable }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and identifier \"codex\""
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw OfficialClientError.invalidSignature }
        return binary
    }
    public func probe(model: String, codexHome: URL, dataDirectory: URL) async throws -> ModelProbeReport {
        guard let model = validModel(model) else { throw OfficialClientError.invalidModel }
        let binary = try await verifiedBinary()
        let privateRun = try prepare(codexHome: codexHome, dataDirectory: dataDirectory)
        defer { try? FileManager.default.removeItem(at: privateRun) }
        let process = configuredProcess(binary: binary, privateRun: privateRun)
        process.arguments = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check",
            "--sandbox", "read-only", "--color", "never", "--json", "-C", privateRun.appendingPathComponent("work").path, "-m", model,
            "-c", "model_reasoning_effort=\"low\"", "-c", "approval_policy=\"never\"", "-c", "cli_auth_credentials_store=\"file\"",
            "-c", "notify=[]", "-c", "project_doc_max_bytes=0", "-c", "features.multi_agent=false", "-c", "features.multi_agent_v2=false", "-c", "features.shell_tool=false",
            "-c", "features.unified_exec=false", "-c", "features.apps=false", "-c", "web_search=\"disabled\"",
            "Respond with exactly pong. Do not call tools, read files, run commands, or delegate."]
        process.environment?["RUST_LOG"] = "off,tungstenite::protocol=trace,tungstenite::protocol::frame=off,codex_api::sse=trace"
        var parser = WireProbeParser()
        let started = Date()
        let outcome = try await execute(process, timeout: 90, onOutput: { _, _ in }, onError: { parser.consume($0) })
        return ModelProbeReport(requestedModel: model, testedAt: started, duration: Date().timeIntervalSince(started),
            exitCode: outcome.code, timedOut: outcome.timedOut, frames: parser.frames, errorEvents: parser.errors, responses: parser.responses)
    }
    public func account(codexHome: URL, dataDirectory: URL, credentials: Data? = nil) async throws -> AccountSnapshot {
        let binary = try await verifiedBinary()
        let privateRun = try prepare(codexHome: codexHome, dataDirectory: dataDirectory, credentials: credentials)
        defer { try? FileManager.default.removeItem(at: privateRun) }
        let process = configuredProcess(binary: binary, privateRun: privateRun)
        // Fresh home has no user config, hooks, MCP connections, or third-party providers.
        process.arguments = ["app-server", "--stdio", "-c", "cli_auth_credentials_store=\"file\"", "-c", "notify=[]"]
        let initial: [String: Any] = ["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "model_lens", "version": "1.3.0"], "capabilities": ["experimentalApi": true]]]
        var results: [Int: [String: Any]] = [:]
        var received: Set<Int> = []
        let outcome = try await execute(process, timeout: 35, initial: initial, onOutput: { line, input in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = object["id"] as? Int else { return }
            if id == 0 {
                guard object["result"] != nil else { process.terminate(); return }
                try? Self.send(["method": "initialized"], to: input)
                for (id, method) in [(1, "account/read"), (2, "account/rateLimits/read"), (3, "account/usage/read")] {
                    var request: [String: Any] = ["id": id, "method": method]
                    if id == 1 { request["params"] = ["refreshToken": false] }
                    try? Self.send(request, to: input)
                }
            } else if (1...3).contains(id) {
                received.insert(id)
                results[id] = object["result"] as? [String: Any]
                if received.count == 3 { process.terminate() }
            }
        }, onError: { _ in })
        if results.isEmpty { throw outcome.timedOut ? OfficialClientError.timeout : OfficialClientError.serviceUnavailable }
        var result = AccountSnapshot.parse(account: results[1], quotas: results[2], usage: results[3])
        if results[2] == nil { result.quotaNote = "额度接口暂不可用" }
        if results[3] == nil { result.tokenNote = "此版本或账户暂未提供账户 Token 统计" }
        return result
    }
    private func prepare(codexHome: URL, dataDirectory: URL, credentials override: Data? = nil) throws -> URL {
        let parent = dataDirectory.appendingPathComponent("PrivateRuns")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Recover private credentials left by a previous abnormal process exit.
        for child in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
            guard child.lastPathComponent.hasPrefix("run-"),
                  let owner = try? String(contentsOf: child.appendingPathComponent("owner.pid"), encoding: .utf8),
                  let pid = Int32(owner), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: child)
        }
        let credentials = try override ?? CodexCredentials.read(home: codexHome)
        guard CodexCredentials.isValid(credentials) else { throw OfficialClientError.noLogin }
        let directory = parent.appendingPathComponent("run-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try String(getpid()).write(to: directory.appendingPathComponent("owner.pid"), atomically: true, encoding: .utf8)
            for folder in ["codex", "work"] { try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            let target = directory.appendingPathComponent("codex/auth.json")
            try credentials.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return directory
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    private func configuredProcess(binary: URL, privateRun: URL) -> Process {
        let process = Process(); process.executableURL = binary; process.currentDirectoryURL = privateRun.appendingPathComponent("work")
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "LOG_FORMAT")
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "OPENAI_ACCESS_TOKEN", "CODEX_MANAGED_BY_NPM", "CODEX_MANAGED_BY_BUN"] { env.removeValue(forKey: key) }
        env["CODEX_HOME"] = privateRun.appendingPathComponent("codex").path; env["RUST_LOG"] = "off"; env["NO_COLOR"] = "1"
        process.environment = env; return process
    }
    private static func send(_ object: [String: Any], to input: FileHandle) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object); bytes.append(10); try input.write(contentsOf: bytes)
    }
    private func execute(_ process: Process, timeout: TimeInterval, initial: [String: Any]? = nil,
                         onOutput: (String, FileHandle) -> Void, onError: (String) -> Void) async throws -> (code: Int32, timedOut: Bool) {
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out; process.standardError = err
        process.standardInput = initial == nil ? FileHandle.nullDevice : input
        try process.run()
        out.fileHandleForWriting.closeFile(); err.fileHandleForWriting.closeFile(); input.fileHandleForReading.closeFile()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            out.fileHandleForReading.closeFile(); err.fileHandleForReading.closeFile(); input.fileHandleForWriting.closeFile()
        }
        for fd in [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        if let initial { try Self.send(initial, to: input.fileHandleForWriting) }
        let deadline = Date().addingTimeInterval(timeout)
        var output = BoundedLines(), error = BoundedLines()
        var timedOut = false, stopping: Date?
        var bytes = [UInt8](repeating: 0, count: 8192)
        repeat {
            for (handle, isError) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
                var drained = 0
                while drained < 4 * 1024 * 1024 {
                    let count = read(handle.fileDescriptor, &bytes, bytes.count)
                    guard count > 0 else { break }; drained += count
                    if isError { error.append(Data(bytes.prefix(count)), consume: onError) }
                    else { output.append(Data(bytes.prefix(count))) { onOutput($0, input.fileHandleForWriting) } }
                }
            }
            if Task.isCancelled || Date() > deadline {
                timedOut = !Task.isCancelled
                if process.isRunning {
                    if Task.isCancelled { kill(process.processIdentifier, SIGKILL) }
                    else if stopping == nil { process.terminate(); stopping = Date() }
                    else if Date().timeIntervalSince(stopping!) > 1 { kill(process.processIdentifier, SIGKILL) }
                }
            }
            if process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        } while process.isRunning
        // Drain data already written before the child exited.
        for (handle, isError) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
            while true {
                let count = read(handle.fileDescriptor, &bytes, bytes.count); guard count > 0 else { break }
                if isError { error.append(Data(bytes.prefix(count)), consume: onError) }
                else { output.append(Data(bytes.prefix(count))) { onOutput($0, input.fileHandleForWriting) } }
            }
        }
        output.finish { onOutput($0, input.fileHandleForWriting) }; error.finish(consume: onError)
        try Task.checkCancellation()
        return (process.terminationStatus, timedOut)
    }
}
