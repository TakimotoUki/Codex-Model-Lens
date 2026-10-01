import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import ModelLensCore

enum TaskFilter: String, CaseIterable, Identifiable {
    case running, all, differences, buffering, saved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .running: "正在运行"
        case .all: "全部任务"
        case .differences: "模型变化"
        case .buffering: "安全缓冲"
        case .saved: "检测历史"
        }
    }
    var icon: String {
        switch self {
        case .running: "waveform.path"
        case .all: "square.stack.3d.up"
        case .differences: "arrow.triangle.branch"
        case .buffering: "hourglass"
        case .saved: "clock.arrow.circlepath"
        }
    }
}

struct LensSettings: Codable, Sendable {
    var codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    var desktopLogs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex").path
    var scanDesktopLogs = true
    var refreshSeconds = 10.0
    var showInternal = false
    var liveModelEvents = true

    private enum CodingKeys: String, CodingKey { case codexHome, desktopLogs, scanDesktopLogs, refreshSeconds, showInternal, liveModelEvents }
    init() {}
    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        codexHome = try values.decodeIfPresent(String.self, forKey: .codexHome) ?? codexHome
        desktopLogs = try values.decodeIfPresent(String.self, forKey: .desktopLogs) ?? desktopLogs
        scanDesktopLogs = try values.decodeIfPresent(Bool.self, forKey: .scanDesktopLogs) ?? scanDesktopLogs
        refreshSeconds = try values.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? refreshSeconds
        showInternal = try values.decodeIfPresent(Bool.self, forKey: .showInternal) ?? showInternal
        liveModelEvents = try values.decodeIfPresent(Bool.self, forKey: .liveModelEvents) ?? liveModelEvents
    }
}

@MainActor @Observable
final class LensStore {
    var settings = LensSettings()
    var filter: TaskFilter = .running
    var selection: String? { didSet { updateDesktopMonitor() } }
    var search = ""
    var archive = HistoryArchive()
    var latestScan = ScanResult()
    var isScanning = false
    var monitoring = true { didSet { updateDesktopMonitor() } }
    var storageError: String?
    var notice: String?
    var showingSettings = false
    var showingDiagnostics = false
    var showingRequests = false
    var showingProbe = false
    var probeModel = "gpt-6-astra"
    var probeReports: [ModelProbeReport] = []
    var probeError: String?
    var isProbing = false
    var mainWindowVisible = false
    let usage: UsageHub
    let pomodoro: PomodoroController
    let networkCapture: NetworkCaptureController
    private let officialClient = OfficialCodexClient()
    private var probeTask: Task<Void, Never>?
    private var canSaveProbes = true
    private var lastSavedSignature = ""
    var requestSearch = ""
    let dataDirectory: URL
    private let legacyDirectory: URL?
    private var migrationWarning: String?
    private var scanner: CodexScanner
    private var monitorTask: Task<Void, Never>?
    private var canSaveHistory = true
    private var scanGeneration = 0
    var desktopStatus = DesktopMonitorStatus()
    var captureError: String?
    private var desktopMonitor: DesktopModelMonitor?
    private var liveEvidenceDirty = false
    private var liveSaveTask: Task<Void, Never>?

    var historyURL: URL { dataDirectory.appendingPathComponent("model-history.json") }
    var importedDirectory: URL { dataDirectory.appendingPathComponent("ImportedEvidence") }
    var networkDirectory: URL { dataDirectory.appendingPathComponent("NetworkEvidence") }
    var settingsURL: URL { dataDirectory.appendingPathComponent("settings.json") }
    var liveIDs: Set<String> { Set(latestScan.threads.map(\.id)) }
    var visibleThreads: [ThreadRecord] {
        archive.threads.filter { thread in
            if !settings.showInternal && thread.isInternal { return false }
            switch filter {
            case .running: if !(thread.isRunning || thread.isUnconfirmed) { return false }
            case .all: if !liveIDs.contains(thread.id) { return false }
            case .differences: if !thread.hasModelDifference { return false }
            case .buffering: if !bufferingThreadIDs.contains(thread.id) { return false }
            case .saved: break
            }
            let modelHistory = thread.turns.flatMap { turn in
                [turn.recordedModel ?? ""] + turn.evidence.flatMap { [$0.model, $0.fromModel ?? "", $0.fasterModel ?? ""] }
            }
            let retryModels = archive.requestRecords.filter { $0.threadID == thread.id }.compactMap(\.fasterModel)
            return search.isEmpty || ([thread.title, thread.id, thread.cwd, thread.displayModel] + modelHistory + retryModels)
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.updatedAt > $1.updatedAt
        }
    }
    var selectedThread: ThreadRecord? { archive.threads.first { $0.id == selection } }
    var runningCount: Int { archive.threads.filter { $0.isRunning && (settings.showInternal || !$0.isInternal) }.count }
    var differenceCount: Int { archive.threads.filter { $0.hasModelDifference && (settings.showInternal || !$0.isInternal) }.count }
    var evidenceCount: Int { archive.threads.flatMap(\.turns).flatMap(\.serverEvidence).count }
    var bufferingThreadIDs: Set<String> {
        Set(archive.requestRecords.filter(\.isBuffering).compactMap(\.threadID))
            .union(archive.threads.filter { $0.turns.contains { !$0.safetyEvidence.isEmpty } }.map(\.id))
    }
    func requests(threadID: String, turnID: String? = nil) -> [RequestRecord] {
        archive.requestRecords.filter { $0.threadID == threadID && (turnID == nil || $0.turnID == turnID) }
    }
    func showRequestDiagnostics(threadID: String? = nil) {
        requestSearch = threadID ?? ""; showingRequests = true
    }

    init(dataDirectory: URL, legacyDirectory: URL? = nil) {
        self.dataDirectory = dataDirectory
        self.legacyDirectory = legacyDirectory
        networkCapture = NetworkCaptureController(directory: dataDirectory)
        pomodoro = PomodoroController(directory: dataDirectory)
        usage = UsageHub(directory: dataDirectory)
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("model-probes.json")) {
            do { probeReports = try JSONDecoder().decode([ModelProbeReport].self, from: data) }
            catch { canSaveProbes = false; probeError = "核验历史无法读取，已保留原文件。" }
        }
        let initialSettings = LensSettings()
        scanner = CodexScanner(configuration: ScannerConfiguration(
            codexHome: URL(fileURLWithPath: initialSettings.codexHome),
            desktopLogs: initialSettings.scanDesktopLogs ? URL(fileURLWithPath: initialSettings.desktopLogs) : nil,
            importedEvidence: dataDirectory.appendingPathComponent("ImportedEvidence"),
            networkEvidence: dataDirectory.appendingPathComponent("NetworkEvidence")))
        settings = initialSettings
    }

    private func loadInitialState() async {
        isScanning = true
        defer { isScanning = false }
        let directory = dataDirectory
        let legacy = legacyDirectory
        let restored = await Task.detached(priority: .utility) {
            let migration = legacy.map { LegacyStorageMigration.migrate(from: $0, to: directory) } ?? StorageMigrationReport()
            let probes = (try? Data(contentsOf: directory.appendingPathComponent("model-probes.json")))
                .flatMap { try? JSONDecoder().decode([ModelProbeReport].self, from: $0) }
            var settings = LensSettings()
            if let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
               let decoded = try? JSONDecoder().decode(LensSettings.self, from: data) { settings = decoded }
            do {
                return InitialState(settings: settings, history: try HistoryStore.load(from: directory.appendingPathComponent("model-history.json")), error: nil, migration: migration, probes: probes)
            } catch {
                return InitialState(settings: settings, history: HistoryArchive(), error: error.localizedDescription, migration: migration, probes: probes)
            }
        }.value
        settings = restored.settings
        if let probes = restored.probes { probeReports = probes }
        migrationWarning = restored.migration.issues.isEmpty ? nil : restored.migration.issues.joined(separator: "\n")
        storageError = migrationWarning
        writeMigrationAudit(restored.migration)
        archive = restored.history
        for i in archive.threads.indices {
            for j in archive.threads[i].turns.indices where archive.threads[i].turns[j].status == .running {
                archive.threads[i].turns[j].status = .unconfirmed
            }
        }
        if let error = restored.error {
            // Corrupt and newer archives are never silently overwritten.
            canSaveHistory = false; storageError = "历史文件无法读取，已保留原文件。\(error)"
        }
        scanner = CodexScanner(configuration: ScannerConfiguration(
            codexHome: URL(fileURLWithPath: settings.codexHome),
            desktopLogs: settings.scanDesktopLogs ? URL(fileURLWithPath: settings.desktopLogs) : nil,
            importedEvidence: importedDirectory, networkEvidence: networkDirectory))
    }

    private func writeMigrationAudit(_ report: StorageMigrationReport) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--migration-audit"), args.indices.contains(index + 1) else { return }
        let audit: [String: Any] = ["changedFiles": report.changedFiles, "issues": report.issues,
            "probeReports": probeReports.count, "confirmedProbeReports": probeReports.filter(\.isConfirmed).count,
            "confirmedModels": probeReports.filter(\.isConfirmed).flatMap(\.deliveredModels)]
        if let bytes = try? JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
        }
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            if CommandLine.arguments.contains("--demo") { self.installDemo(); return }
            await self.loadInitialState()
            self.desktopMonitor = DesktopModelMonitor { [weak self] records, status in
                Task { @MainActor [weak self] in self?.receiveDesktopEvidence(records, status: status) }
            }
            while !Task.isCancelled {
                if self.monitoring { await self.refresh() }
                let clientOpen = NSWorkspace.shared.runningApplications.contains { ["com.openai.codex", "com.openai.chat"].contains($0.bundleIdentifier ?? "") }
                let seconds = clientOpen ? max(self.mainWindowVisible ? 2 : 15, min(60, self.settings.refreshSeconds)) : 60
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            }
        }
    }

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let generation = scanGeneration
        let clientRunning = NSWorkspace.shared.runningApplications.contains {
            ["com.openai.codex", "com.openai.chat"].contains($0.bundleIdentifier ?? "")
        }
        let result = await scanner.scan(clientIsRunning: clientRunning)
        guard generation == scanGeneration else { return }
        latestScan = result
        archive = HistoryStore.merge(result, into: archive)
        updateDesktopMonitor()
        if !visibleThreads.contains(where: { $0.id == selection }) { selection = visibleThreads.first?.id }
        let signature = result.threads.map { [$0.id, $0.title, $0.selectedModel ?? "", String($0.updatedAt.timeIntervalSince1970), $0.statusLabel, String($0.turns.count), $0.displayModel].joined(separator: "|") }.joined(separator: "\n") + "#\(archive.requestRecords.count)#\(evidenceCount)"
        if canSaveHistory && (liveEvidenceDirty || signature != lastSavedSignature || result.bytesRead > 0) {
            liveEvidenceDirty = false
            let snapshot = archive, destination = historyURL
            do {
                try await Task.detached(priority: .utility) { try HistoryStore.save(snapshot, to: destination) }.value
                storageError = migrationWarning; lastSavedSignature = signature
            } catch { storageError = "无法保存检测历史：\(error.localizedDescription)" }
        }
    }

    func saveSettings() {
        settings.refreshSeconds = max(2, min(60, settings.refreshSeconds))
        do {
            try PrivateMetadata.save(settings, to: settingsURL)
            scanGeneration += 1
            scanner = CodexScanner(configuration: ScannerConfiguration(
                codexHome: URL(fileURLWithPath: settings.codexHome),
                desktopLogs: settings.scanDesktopLogs ? URL(fileURLWithPath: settings.desktopLogs) : nil,
                importedEvidence: importedDirectory, networkEvidence: networkDirectory))
            updateDesktopMonitor()
        } catch { storageError = "设置保存失败：\(error.localizedDescription)" }
    }

    func chooseDirectory(forLogs: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.showsHiddenFiles = true; panel.allowsMultipleSelection = false
        panel.message = forLogs ? "选择 Codex 桌面日志目录" : "选择 Codex 数据目录（通常是 ~/.codex）"
        if panel.runModal() == .OK, let url = panel.url {
            if forLogs { settings.desktopLogs = url.path } else { settings.codexHome = url.path }
        }
    }

    func export(csv: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = csv ? "Codex-model-history.csv" : "Codex-model-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if csv { try HistoryStore.exportCSV(archive.threads).write(to: url, atomically: true, encoding: .utf8) }
            else { try HistoryStore.save(archive, to: url) }
            notice = "已导出 \(archive.threads.count) 个任务的检测历史。"
        } catch { storageError = "导出失败：\(error.localizedDescription)" }
    }

    func importEvidence() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .init(filenameExtension: "jsonl") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "导入包含明确任务 ID、轮次 ID 的路由、响应模型或安全缓冲事件。导入文件属于外部证据，不作独立认证。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                // Use a temporary source directory inside the app's own storage and retain only
                // whitelisted metadata. No prompt, response body, authorization header, or raw log is copied.
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 32 * 1024 * 1024 else { throw ImportError.tooLarge }
                let imported = try await EvidenceImporter.importFile(data, sourceName: url.lastPathComponent, to: importedDirectory)
                notice = "已导入 \(imported) 条模型记录。外部文件的来源需要自行确认。"
                await refresh()
            } catch { storageError = "导入失败：\(error.localizedDescription)" }
        }
    }

    func exportRequests(_ records: [RequestRecord], csv: Bool) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = csv ? "Codex-request-evidence.csv" : "Codex-request-evidence.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if csv { try HistoryStore.exportRequestsCSV(records).write(to: url, atomically: true, encoding: .utf8) }
            else {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(records).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            notice = "已导出 \(records.count) 条请求证据。"
        } catch { storageError = "请求证据导出失败：\(error.localizedDescription)" }
    }

    func startProbe() {
        guard !isProbing, canSaveProbes else { return }
        isProbing = true; probeError = nil
        let model = probeModel.trimmingCharacters(in: .whitespaces)
        let home = URL(fileURLWithPath: settings.codexHome), directory = dataDirectory
        probeTask = Task {
            defer { isProbing = false; probeTask = nil }
            do {
                let report = try await officialClient.probe(model: model, codexHome: home, dataDirectory: directory)
                probeReports.insert(report, at: 0)
                try saveMetadata(probeReports, name: "model-probes.json")
            } catch is CancellationError { probeError = "已取消，临时登录文件已清理。" }
            catch { probeError = error.localizedDescription }
        }
    }
    func cancelProbe() { probeTask?.cancel() }
    func shutdown() { networkCapture.shutdown(); usage.shutdown(); probeTask?.cancel(); monitorTask?.cancel(); desktopMonitor?.stop(); liveSaveTask?.cancel() }
    private func updateDesktopMonitor() {
        let active = archive.threads.filter { $0.isRunning || $0.isUnconfirmed }.prefix(24).map(\.id)
        let recent = latestScan.threads.prefix(12).map(\.id)
        let ids = Set(active + recent + (selection.map { [$0] } ?? [])).subtracting(archive.removedThreadIDs ?? [])
        desktopMonitor?.update(home: URL(fileURLWithPath: settings.codexHome), threads: ids,
            enabled: monitoring && settings.liveModelEvents)
    }
    private func receiveDesktopEvidence(_ records: [ThreadRecord], status: DesktopMonitorStatus) {
        desktopStatus = status
        guard !records.isEmpty else { return }
        archive = HistoryStore.addingEvidence(records, to: archive)
        liveEvidenceDirty = true
        guard liveSaveTask == nil else { return }
        liveSaveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.liveSaveTask = nil }
            do {
                try await Task.sleep(for: .seconds(1))
                while self.isScanning { try await Task.sleep(for: .milliseconds(250)) }
                await self.refresh()
            } catch { return }
        }
    }
    func launchModelCapture(detailed: Bool = false) {
        captureError = nil
        Task {
            do { try await ModelCaptureLauncher.launch(detailed: detailed); notice = "已以模型采集模式打开客户端；带明确任务和轮次关联的服务端模型字段将自动保存。" }
            catch { captureError = error.localizedDescription }
        }
    }
    func copyProbe(_ report: ModelProbeReport) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) { copy(String(decoding: data, as: UTF8.self)) }
    }
    private func saveMetadata<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let file = dataDirectory.appendingPathComponent(name)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func revealHistory() { NSWorkspace.shared.selectFile(historyURL.path, inFileViewerRootedAtPath: dataDirectory.path) }
    func removeLocalTask(_ id: String) {
        guard canSaveHistory, !isScanning else { return }
        do {
            let next = HistoryStore.removingThreads([id], from: archive)
            try HistoryStore.save(next, to: historyURL)
            archive = next
            if selection == id { selection = visibleThreads.first?.id }
            notice = "已移除本地检测记录，后续扫描会跳过此任务。Codex 原始会话仍保留。"
        } catch { storageError = "移除失败：\(error.localizedDescription)" }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

private struct InitialState: Sendable {
    var settings: LensSettings
    var history: HistoryArchive
    var error: String?
    var migration: StorageMigrationReport
    var probes: [ModelProbeReport]?
}

enum ImportError: Error, LocalizedError {
    case tooLarge
    var errorDescription: String? { "文件超过 32 MB，请先提取结构化模型事件。" }
}
