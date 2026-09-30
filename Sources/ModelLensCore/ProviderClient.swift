import Foundation
import Security
import AppKit
import Darwin

@MainActor public enum AgentDiscovery {
    public static func app(_ identifier: String, names: [String]) -> URL? {
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier), FileManager.default.fileExists(atPath: registered.path) { return registered }
        let directories = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return directories.flatMap { parent in names.map { parent.appendingPathComponent($0 + ".app") } }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    public static func codexBinary() -> URL? {
        for id in ["com.openai.codex", "com.openai.chat"] {
            if let app = app(id, names: ["Codex", "ChatGPT"]) {
                let binary = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
            }
        }
        for folder in ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path] {
            let executable = URL(fileURLWithPath: folder).appendingPathComponent("codex").resolvingSymlinksInPath()
            let vendor = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vendor/aarch64-apple-darwin/codex/codex")
            for candidate in [executable, vendor] where FileManager.default.isExecutableFile(atPath: candidate.path) {
                if candidate.pathExtension != "js" { return candidate }
            }
        }
        return nil
    }
}

private final class MetadataSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let localPort: Int?
    init(localPort: Int? = nil) { self.localPort = localPort }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Credentials never follow redirects, including a different account's endpoint.
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let localPort, challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == localPort,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
}

public actor ProviderClient {
    public init() {}
    public func fetch(_ provider: UsageProvider, credential: String? = nil, accountID: String = "local") async throws -> UsageSnapshot {
        switch provider {
        case .deepseek:
            guard let key = credential ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? ProcessInfo.processInfo.environment["DEEPSEEK_KEY"], !key.isEmpty else { throw ProviderReadError.missingLogin }
            return try ProviderParsers.deepseek(await request("https://api.deepseek.com/user/balance", headers: ["Authorization": "Bearer " + key]), account: accountID)
        case .opencodego:
            if let credential, let bytes = credential.data(using: .utf8),
               let web = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
               let cookie = web["cookie"], let workspace = web["workspace"], cookie.utf8.count <= 8192,
               !cookie.contains(where: { $0.isNewline }), workspace.hasPrefix("org_"), workspace.count <= 100,
               workspace.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
                let headers = ["Cookie": cookie, "x-org-id": workspace]
                let status = try await request("https://opencode.ai/console/api/go/status", headers: headers)
                let billing = (try? await request("https://opencode.ai/console/api/billing/status", headers: headers)) ?? [:]
                return try ProviderParsers.opencodeConsole(status, billing: billing, account: accountID)
            }
            if credential?.hasPrefix("{") == true { throw CredentialError.invalid }
            let local = credential == nil ? try? OpenCodeHistory.load() : nil
            do {
                let key = try credential ?? openCodeKey()
                var value = try ProviderParsers.opencode(await request("https://opencode.ai/zen/go/v1/usage", headers: ["Authorization": "Bearer " + key]), account: accountID)
                if let history = local {
                    value.dailyCosts = history.dailyCosts; value.recordedCost = history.recordedCost
                    value.tokens = history.tokens; value.todayTokens = history.todayTokens; value.note = history.note
                }
                return value
            } catch {
                if var history = local { history.note = (history.note ?? "") + " 官方额度未读取成功。"; return history }
                throw error
            }
        case .workbuddy:
            do { return try await workbuddy(accountID: accountID) }
            catch ProviderReadError.encryptedLogin {
                return try WorkBuddyHistory.load()
            }
        case .antigravity: return try await antigravity()
        case .codex: throw ProviderReadError.unsupported
        }
    }
    private func openCodeKey() throws -> String {
        if let key = ProcessInfo.processInfo.environment["OPENCODE_API_KEY"], !key.isEmpty { return key }
        let root = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let file = root.appendingPathComponent("opencode/auth.json")
        guard let data = try? Data(contentsOf: file), data.count < 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderReadError.missingLogin }
        for id in ["opencode-go", "opencode"] {
            if let entry = object[id] as? [String: Any], entry["type"] as? String == "api", let key = entry["key"] as? String, !key.isEmpty { return key }
        }
        throw ProviderReadError.missingLogin
    }
    private func workbuddy(accountID: String) async throws -> UsageSnapshot {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info")
        guard let bytes = try? Data(contentsOf: file), bytes.count < 1024 * 1024,
              let authFile = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let auth = authFile["auth"] as? [String: Any], let account = authFile["account"] as? [String: Any],
              let uid = account["uid"] as? String else { throw ProviderReadError.missingLogin }
        if let wrapper = auth["accessToken"] as? [String: Any], wrapper["$wbEncrypted"] as? Int == 1 { throw ProviderReadError.encryptedLogin }
        guard let token = auth["accessToken"] as? String, !token.isEmpty else { throw ProviderReadError.missingLogin }
        guard let app = await AgentDiscovery.app("com.tencent.workbuddy", names: ["WorkBuddy"]) else { throw ProviderReadError.unavailable }
        let productURL = app.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/product.json")
        let product = (try? Data(contentsOf: productURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let endpoint = product?["endpoint"] as? String, let base = URL(string: endpoint), base.scheme == "https",
              ["www.workbuddy.cn", "www.workbuddy.ai", "www.codebuddy.ai", "copilot.tencent.com"].contains(base.host ?? ""),
              base.user == nil, base.password == nil, base.port == nil else { throw ProviderReadError.unsupported }
        var headers = ["Authorization": "Bearer " + token, "X-User-Id": uid]
        if let domain = auth["domain"] as? String { headers["X-Domain"] = domain }
        let enterpriseID = account["enterpriseId"] as? String
        let enterprise = enterpriseID.map { !$0.isEmpty } ?? false
        if let enterpriseID { headers["X-Enterprise-Id"] = enterpriseID; headers["X-Tenant-Id"] = enterpriseID }
        let path = enterprise ? "/v2/billing/meter/get-enterprise-user-usage" : "/v2/billing/meter/get-user-resource"
        let body: [String: Any] = enterprise ? [:] : ["PageNumber": 1, "PageSize": 100, "ProductCode": "p_tcaca", "Status": [0, 3], "OnlyValidPeriod": true]
        return try ProviderParsers.workbuddy(await request(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path, headers: headers, body: body), account: stableID(uid), enterprise: enterprise)
    }
    private func antigravity() async throws -> UsageSnapshot {
        guard let app = await AgentDiscovery.app("com.google.antigravity", names: ["Antigravity", "Antigravity IDE"]) else { throw ProviderReadError.unavailable }
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\" and identifier \"com.google.antigravity\"" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw ProviderReadError.unsupported }
        let running = await MainActor.run { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.google.antigravity" } }
        if !running {
            await MainActor.run {
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false; configuration.hides = true
                NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in }
            }
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(250))
                let processes = try await command("/bin/ps", ["-U", String(getuid()), "-o", "command="])
                if processes.contains(app.path + "/Contents/") && processes.contains("language_server") { break }
            }
        }
        let listing = try await command("/bin/ps", ["-U", String(getuid()), "-o", "pid=,command="])
        for line in listing.split(separator: "\n") {
            guard line.contains("language_server"), let pid = Int32(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""),
                  let token = capture(#"--csrf_token(?:=|\s+)([^\s]+)"#, String(line)) else { continue }
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let binary = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().path
            guard binary.hasPrefix(app.resolvingSymlinksInPath().path + "/Contents/"), binary.contains("language_server") else { continue }
            let sockets = try await command("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)])
            let regex = try NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#)
            let ports = Set(regex.matches(in: sockets, range: NSRange(sockets.startIndex..., in: sockets)).compactMap { Range($0.range(at: 1), in: sockets).flatMap { Int(sockets[$0]) } })
            for port in ports.sorted() {
                for scheme in ["https", "http"] {
                    let base = "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/"
                    let headers = ["X-Codeium-Csrf-Token": token, "Connect-Protocol-Version": "1"]
                    let summary = (try? await request(base + "RetrieveUserQuotaSummary", headers: headers, body: ["forceRefresh": true], localPort: port)) ?? [:]
                    let status = (try? await request(base + "GetUserStatus", headers: headers, body: ["metadata": ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"]], localPort: port)) ?? [:]
                    if var value = try? ProviderParsers.antigravity(summary: summary, status: status) {
                        let user = status["userStatus"] as? [String: Any]
                        let identity = user?["email"] as? String ?? user?["userId"] as? String
                        value.accountID = identity.map(stableID) ?? "local-antigravity"
                        return value
                    }
                    try Task.checkCancellation()
                }
            }
        }
        throw ProviderReadError.unavailable
    }
    private func request(_ value: String, headers: [String: String], body: [String: Any]? = nil, localPort: Int? = nil) async throws -> [String: Any] {
        guard let url = URL(string: value) else { throw ProviderReadError.invalidResponse }
        var request = URLRequest(url: url); request.timeoutInterval = localPort == nil ? 15 : 3
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 20
        if localPort != nil { config.connectionProxyDictionary = [:] }
        let session = URLSession(configuration: config, delegate: MetadataSessionDelegate(localPort: localPort), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderReadError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderReadError.rejected }
        guard (200...299).contains(http.statusCode) else { throw ProviderReadError.unavailable }
        var data = Data(); data.reserveCapacity(16 * 1024)
        for try await byte in stream {
            guard data.count < 2 * 1024 * 1024 else { throw ProviderReadError.tooLarge }; data.append(byte)
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        // OpenCode's Go status is JSON null for prepaid-only accounts. Billing remains
        // available; other parsers still require their own provider-specific fields.
        if object is NSNull { return [:] }
        guard let dictionary = object as? [String: Any] else { throw ProviderReadError.invalidResponse }
        return dictionary
    }
    private func command(_ path: String, _ arguments: [String]) async throws -> String {
        let process = Process(); let out = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = out; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run(); out.fileHandleForWriting.closeFile()
        _ = fcntl(out.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        defer { if process.isRunning { process.terminate() }; out.fileHandleForReading.closeFile() }
        let deadline = Date().addingTimeInterval(5); var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        repeat {
            while true {
                let count = read(out.fileHandleForReading.fileDescriptor, &buffer, buffer.count); guard count > 0 else { break }
                guard data.count + count < 1024 * 1024 else { throw ProviderReadError.tooLarge }; data.append(contentsOf: buffer.prefix(count))
            }
            try Task.checkCancellation()
            if Date() > deadline { process.terminate(); throw ProviderReadError.unavailable }
            if process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        } while process.isRunning
        while true {
            let count = read(out.fileHandleForReading.fileDescriptor, &buffer, buffer.count); guard count > 0 else { break }
            guard data.count + count < 1024 * 1024 else { throw ProviderReadError.tooLarge }; data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }
    private func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
