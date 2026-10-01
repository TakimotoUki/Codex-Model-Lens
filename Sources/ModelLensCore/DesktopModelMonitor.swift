import Foundation
import Darwin
import Security

public struct DesktopMonitorStatus: Sendable, Equatable {
    public var connected = false
    public var snapshots = 0
    public var evidence = 0
    public var message = "等待 Codex 桌面客户端"
    public init() {}
}

/// All mutable state is confined to queue. The socket is receive driven, without a
/// polling timer. Only metadata projections are passed to the application.
public final class DesktopModelMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ModelLens.desktop-model-events", qos: .utility, autoreleaseFrequency: .workItem)
    private let receive: @Sendable ([ThreadRecord], DesktopMonitorStatus) -> Void
    private var home: URL?
    private var wanted: Set<String> = []
    private var followed: Set<String> = []
    private var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var pending = Data()
    private var input = Data()
    private var clientID: String?
    private var projection = DesktopEvidenceProjection()
    private var retry: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var retrySeconds = 2.0
    private var status = DesktopMonitorStatus()
    private var publishedStatus: DesktopMonitorStatus?

    public init(receive: @escaping @Sendable ([ThreadRecord], DesktopMonitorStatus) -> Void) { self.receive = receive }
    public func update(home: URL, threads: Set<String>, enabled: Bool) {
        queue.async { [self] in
            let changed = self.home != home
            self.home = enabled ? home : nil
            wanted = Set(threads.filter { UUID(uuidString: $0) != nil }.sorted().prefix(40))
            if !enabled || changed { disconnect(reconnect: false) }
            if enabled {
                if descriptor < 0, retry == nil { connect() }
                else if clientID != nil { synchronize() }
            }
        }
    }
    public func stop() { queue.async { [self] in home = nil; disconnect(reconnect: false) } }

    private func connect() {
        retry = nil
        guard let home else { return }
        let path = home.appendingPathComponent("ipc/ipc.sock").resolvingSymlinksInPath().path
        var entry = stat(), parent = stat()
        guard lstat(path, &entry) == 0, (entry.st_mode & S_IFMT) == S_IFSOCK, entry.st_uid == getuid(),
              lstat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &parent) == 0,
              (parent.st_mode & S_IFMT) == S_IFDIR, parent.st_uid == getuid(), parent.st_mode & 0o022 == 0 else {
            status.message = "未找到安全的本机 Codex 通信接口"; scheduleRetry(); return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { scheduleRetry(); return }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { close(fd); status.message = "通信路径过长"; scheduleRetry(); return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var uid = uid_t(0), gid = gid_t(0)
        guard result == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid(), verifiedPeer(fd) else {
            close(fd); status.message = "Codex 桌面接口尚未就绪"; scheduleRetry(); return
        }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { close(fd); scheduleRetry(); return }
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in guard let self, self.descriptor == fd else { return }; self.read() }
        source.setCancelHandler { close(fd) }
        reader = source; source.resume()
        send(["type": "request", "requestId": UUID().uuidString, "sourceClientId": "initializing-client",
              "method": "initialize", "version": 0, "params": ["clientType": "model-lens"], "timeoutMs": 5000])
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.clientID == nil else { return }
            self.status.message = "桌面接口初始化超时"; self.disconnect(reconnect: true)
        }
        timeout = deadline; queue.asyncAfter(deadline: .now() + 6, execute: deadline)
    }
    private func verifiedPeer(_ fd: Int32) -> Bool {
        var pid = pid_t(0), length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return false }
        var code: SecCode?, requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and (identifier \"com.openai.codex\" or identifier \"com.openai.chat\")"
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    private func read() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<32 {
            let n = Darwin.read(descriptor, &bytes, bytes.count)
            if n == 0 { disconnect(reconnect: true); return }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                disconnect(reconnect: true); return
            }
            input.append(contentsOf: bytes.prefix(n))
            while input.count >= 4 {
                let count = input.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
                guard count > 0, count <= 16 * 1024 * 1024 else {
                    status.message = "桌面接口记录超出安全大小限制"; disconnect(reconnect: true); return
                }
                guard input.count >= count + 4 else { break }
                let data = Data(input.dropFirst(4).prefix(count))
                input.removeFirst(count + 4)
                if input.isEmpty { input = Data() }
                autoreleasepool { handle(data) }
                if descriptor < 0 { return }
            }
        }
    }
    private func handle(_ data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if o["type"] as? String == "client-discovery-request", let request = o["requestId"] as? String {
            // This is an observer. It never owns a task or handles execution/approval requests.
            send(["type": "client-discovery-response", "requestId": request, "response": ["canHandle": false]])
        } else if o["type"] as? String == "response", o["method"] as? String == "initialize",
                  o["resultType"] as? String == "success", let result = o["result"] as? [String: Any],
                  let id = result["clientId"] as? String {
            clientID = id; timeout?.cancel(); timeout = nil; retrySeconds = 2
            status.connected = true; status.message = "已连接 · 实时监听模型路由"; publish([]); synchronize()
        } else if o["type"] as? String == "broadcast", clientID != nil {
            let records = projection.consume(o, allowedThreads: followed)
            status.snapshots = projection.snapshots; status.evidence = projection.routingRecords
            if !records.isEmpty { publish(records) }
            else if o["method"] as? String == "thread-stream-state-changed" { publish([]) }
            if let id = projection.needsSnapshot, followed.contains(id) {
                following(id, false); following(id, true)
            }
        }
    }
    private func synchronize() {
        projection.retainThreads(wanted)
        for id in followed.subtracting(wanted) { following(id, false) }
        for id in wanted.subtracting(followed) { following(id, true) }
        followed = wanted
    }
    private func following(_ id: String, _ value: Bool) {
        guard let clientID else { return }
        send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
              "sourceClientId": clientID, "params": ["conversationId": id, "hostId": "local", "following": value]])
    }
    private func send(_ object: [String: Any]) {
        guard descriptor >= 0, let bytes = try? JSONSerialization.data(withJSONObject: object), bytes.count < 65536 else { return }
        var length = UInt32(bytes.count).littleEndian
        pending.append(Data(bytes: &length, count: 4)); pending.append(bytes)
        guard pending.count <= 256 * 1024 else { disconnect(reconnect: true); return }
        flush()
    }
    private func flush() {
        while descriptor >= 0, !pending.isEmpty {
            let fd = descriptor
            let n = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { pending.removeFirst(n); continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in guard let self, self.descriptor == fd else { return }; self.flush() }
                    writer = source; source.resume()
                }
                return
            }
            disconnect(reconnect: true); return
        }
        writer?.cancel(); writer = nil
    }
    private func disconnect(reconnect: Bool) {
        retry?.cancel(); retry = nil; timeout?.cancel(); timeout = nil
        writer?.cancel(); writer = nil; reader?.cancel(); reader = nil
        descriptor = -1; clientID = nil; followed.removeAll(); pending.removeAll(); input.removeAll(); projection.reset()
        status.connected = false; status.message = home == nil ? "实时监听已关闭" : "等待重新连接 Codex 桌面接口"
        publish([])
        if reconnect { scheduleRetry() }
    }
    private func scheduleRetry() {
        guard home != nil, retry == nil else { return }
        publish([])
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retry = work; queue.asyncAfter(deadline: .now() + retrySeconds, execute: work)
        retrySeconds = min(60, retrySeconds * 2)
    }
    private func publish(_ records: [ThreadRecord]) {
        guard !records.isEmpty || status != publishedStatus else { return }
        publishedStatus = status; receive(records, status)
    }
}
