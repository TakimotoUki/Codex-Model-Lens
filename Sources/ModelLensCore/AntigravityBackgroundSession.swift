import Foundation
import Security
import Darwin

/// A short-lived, owned Google process. Original credentials/config/history are read-only.
/// The official helper refreshes authentication only inside our isolated temporary home.
final class AntigravityBackgroundSession {
    private let process = Process()
    private let input = Pipe()
    private var temporary: URL?
    let csrf = UUID().uuidString
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    static func verify(_ url: URL, identifier: String? = nil) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        var expression = "anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
        if let identifier { expression += " and identifier \"\(identifier)\"" }
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else { throw ProviderReadError.unavailable }
    }
    func start(app: URL) throws {
        try Self.verify(app, identifier: "com.google.antigravity")
        let binary = app.appendingPathComponent("Contents/Resources/bin/language_server").resolvingSymlinksInPath()
        guard binary.path.hasPrefix(app.resolvingSymlinksInPath().path + "/Contents/"), FileManager.default.isExecutableFile(atPath: binary.path) else { throw ProviderReadError.unavailable }
        try Self.verify(binary)
        let credential = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        let attributes = try FileManager.default.attributesOfItem(atPath: credential.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 128 * 1024 else { throw ProviderReadError.missingLogin }
        let bytes = try Data(contentsOf: credential)
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let token = root["token"] as? [String: Any], let refresh = token["refresh_token"] as? String,
              !refresh.isEmpty, refresh.utf8.count <= 16384 else { throw ProviderReadError.missingLogin }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dev.modellens.antigravity-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        temporary = directory
        do {
            let copy = directory.appendingPathComponent("jetski-standalone-oauth-token")
            guard FileManager.default.createFile(atPath: copy.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw ProviderReadError.unavailable }
            process.executableURL = binary; process.currentDirectoryURL = directory
            let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            process.arguments = ["--standalone", "--headless", "--exit_on_stdin_close", "--override_ide_name", "antigravity", "--override_ide_version", version,
                "--override_user_agent_name", "antigravity", "--subclient_type", "hub", "--gemini_dir", directory.path, "--app_data_dir", "lens-probe",
                "--https_server_port", "0", "--csrf_token", csrf, "--limit_go_max_procs", "1", "--use_ls_chrome_devtools_mcp=false",
                "--cloud_code_endpoint", "https://daily-cloudcode-pa.googleapis.com", "--api_server_url", "https://generativelanguage.googleapis.com"]
            var environment = ProcessInfo.processInfo.environment
            for name in ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "NODE_OPTIONS", "ELECTRON_RUN_AS_NODE"] { environment[name] = nil }
            process.environment = environment; process.standardInput = input
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
        } catch { stop(); throw error }
    }
    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        if process.isRunning {
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
    }
    deinit { stop() }
}
