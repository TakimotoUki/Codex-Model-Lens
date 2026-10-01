import Foundation
import CryptoKit
import Security
import Darwin

public enum NetworkCaptureError: Error, LocalizedError {
    case componentMissing, integrity, startup, download
    public var errorDescription: String? {
        switch self {
        case .componentMissing: "请先下载网络采集组件。"
        case .integrity: "网络采集组件校验失败，未运行。"
        case .startup: "网络采集代理未能启动；未修改客户端或系统设置。"
        case .download: "官方组件下载失败，请检查网络后重试。"
        }
    }
}
/// Optional component. All proxy, CA and helper files belong to Model Lens.
/// No system trust, keychain certificate, agent config or system proxy is changed.
public actor NetworkCaptureSession {
    public static let version = "12.2.3"
    public static let archiveHash = "0a09ee3b82569e8985aff8186e4792618b8e5d0c766098db093d09a87d4b013a"
    private let directory: URL
    private var process: Process?
    private var sessionDirectory: URL?
    public init(directory: URL) { self.directory = directory }
    private var helper: URL { directory.appendingPathComponent("NetworkTools/mitmproxy-" + Self.version + "/mitmproxy.app") }
    public func ready() -> Bool { FileManager.default.isExecutableFile(atPath: helper.appendingPathComponent("Contents/MacOS/mitmdump").path) }
    public func install(archive supplied: URL? = nil) async throws {
        if ready() { return }
        let parent = directory.appendingPathComponent("NetworkTools")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent("setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("component.tar.gz")
        if let supplied { try FileManager.default.copyItem(at: supplied, to: archive) }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForResource = 180
            let session = URLSession(configuration: configuration, delegate: CaptureDownloadDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let url = URL(string: "https://downloads.mitmproxy.org/12.2.3/mitmproxy-12.2.3-macos-arm64.tar.gz")!
            let (download, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw NetworkCaptureError.download }
            try FileManager.default.moveItem(at: download, to: archive)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 100 * 1024 * 1024 else { throw NetworkCaptureError.integrity }
        let file = try FileHandle(forReadingFrom: archive); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == Self.archiveHash else { throw NetworkCaptureError.integrity }
        let unpack = Process(); unpack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        unpack.arguments = ["-xzf", archive.path, "-C", temporary.path, "mitmproxy.app"]
        unpack.standardOutput = FileHandle.nullDevice; unpack.standardError = FileHandle.nullDevice
        try unpack.run()
        defer { if unpack.isRunning { unpack.terminate(); unpack.waitUntilExit() } }
        while unpack.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        guard unpack.terminationStatus == 0 else { throw NetworkCaptureError.integrity }
        let app = temporary.appendingPathComponent("mitmproxy.app")
        // This exact upstream archive has a packaging signature issue. After verifying
        // the pinned archive hash, rebuild signatures on our private copy only. Keep
        // entitlements/runtime flags; never alter installed apps or system trust.
        try makePrivateCopyWritable(app)
        let signing = Process(); signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements,flags,runtime", app.path]
        signing.standardOutput = FileHandle.nullDevice; signing.standardError = FileHandle.nullDevice
        try signing.run()
        defer { if signing.isRunning { signing.terminate(); signing.waitUntilExit() } }
        while signing.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard signing.terminationStatus == 0 else { throw NetworkCaptureError.integrity }
        try verify(app)
        let destination = helper.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: destination.path) { throw NetworkCaptureError.integrity }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { try FileManager.default.moveItem(at: app, to: helper) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    public func start(script: URL, outputDirectory: URL) async throws -> [String: String] {
        guard ready() else { throw NetworkCaptureError.componentMissing }
        guard process == nil else { throw NetworkCaptureError.startup }
        try verify(helper)
        var succeeded = false
        defer { if !succeeded { stop() } }
        let temporary = directory.appendingPathComponent("NetworkTools/session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        sessionDirectory = temporary
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = outputDirectory.appendingPathComponent("network-models-" + UUID().uuidString + ".jsonl")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw NetworkCaptureError.startup }
        let port = try availablePort()
        let authority = temporary.appendingPathComponent("root-ca.pem")
        let authorityKey = temporary.appendingPathComponent("root-ca-key.pem")
        let certificate = temporary.appendingPathComponent("localhost-cert.pem")
        let key = temporary.appendingPathComponent("localhost-key.pem")
        let request = temporary.appendingPathComponent("localhost.csr")
        let pem = temporary.appendingPathComponent("localhost.pem")
        let configuration = temporary.appendingPathComponent("localhost.cnf")
        let contents = "[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=127.0.0.1\n[root]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n[server]\nsubjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n"
        try contents.write(to: configuration, atomically: true, encoding: .utf8)
        try await openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", authorityKey.path, "-out", authority.path, "-days", "7", "-config", configuration.path, "-extensions", "root"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorityKey.path)
        try await openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", request.path, "-config", configuration.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try await openssl(["x509", "-req", "-in", request.path, "-CA", authority.path, "-CAkey", authorityKey.path, "-CAcreateserial", "-out", certificate.path, "-days", "7", "-sha256", "-extfile", configuration.path, "-extensions", "server"])
        try (Data(contentsOf: certificate) + Data(contentsOf: authority) + Data(contentsOf: key)).write(to: pem, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pem.path)
        let p = Process(); p.executableURL = helper.appendingPathComponent("Contents/MacOS/mitmdump")
        p.arguments = ["--mode", "reverse:https://chatgpt.com", "--certs", "*=" + pem.path, "--quiet", "--listen-host", "127.0.0.1", "--listen-port", String(port), "--set", "confdir=" + temporary.path,
            "--set", "block_global=true", "--set", "ssl_insecure=false", "--set", "flow_detail=0", "--set", "termlog_verbosity=error",
            "-s", script.path, "--set", "lens_output=" + output.path, "--set", "lens_owner_pid=\(ProcessInfo.processInfo.processIdentifier)"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH", "PYTHONHOME", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "NODE_OPTIONS"] { environment[key] = nil }
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = environment; p.currentDirectoryURL = temporary
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        process = p
        do {
            try p.run()
            let ca = authority
            let deadline = Date().addingTimeInterval(15)
            while p.isRunning, Date() < deadline {
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: ca.path), listening(port: port) {
                    succeeded = true
                    let address = "https://127.0.0.1:\(port)/backend-api/"
                    return ["CODEX_APP_SERVER_CHATGPT_BASE_URL": address,
                        "CODEX_CA_CERTIFICATE": ca.path]
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NetworkCaptureError.startup
        } catch { stop(); throw error }
    }
    private func openssl(_ arguments: [String]) async throws {
        let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); command.arguments = arguments
        command.standardOutput = FileHandle.nullDevice; command.standardError = FileHandle.nullDevice
        try command.run()
        defer {
            if command.isRunning { kill(command.processIdentifier, SIGKILL); command.waitUntilExit() }
        }
        let deadline = Date().addingTimeInterval(20)
        while command.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw NetworkCaptureError.startup }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard command.terminationStatus == 0 else { throw NetworkCaptureError.startup }
    }
    public func stop() {
        if let p = process, p.isRunning {
            p.terminate(); let deadline = Date().addingTimeInterval(1)
            while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
        }
        process = nil
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
        sessionDirectory = nil
    }
    private func makePrivateCopyWritable(_ app: URL) throws {
        if let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let file as URL in enumerator {
                let resource = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if resource.isRegularFile == true, resource.isSymbolicLink != true {
                    let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
                    try FileManager.default.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: file.path)
                }
            }
        }
    }
    private func verify(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw NetworkCaptureError.integrity }
    }
    private func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw NetworkCaptureError.startup }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            guard bind(fd, $0, length) == 0 else { return Int32(-1) }; return getsockname(fd, $0, &length)
        } }
        guard result == 0 else { throw NetworkCaptureError.startup }; return UInt16(bigEndian: address.sin_port)
    }
    private func listening(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
}
private final class CaptureDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "downloads.mitmproxy.org" ? request : nil)
    }
}
