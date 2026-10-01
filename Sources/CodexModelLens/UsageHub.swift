import SwiftUI
import Observation
import ModelLensCore

struct UsagePreferences: Codable {
    var enabled: Set<UsageProvider> = [.codex]
    var accounts: [UsageAccount] = []
    var selected: [UsageProvider: String] = [:]
}
@MainActor @Observable
final class UsageHub {
    var preferences = UsagePreferences()
    var provider: UsageProvider = .codex
    var snapshots: [String: UsageSnapshot] = [:]
    var history: [UsageSnapshot] = []
    var errors: [String: String] = [:]
    var loading: Set<String> = []
    var configurationError: String?
    var serviceStatuses: [UsageProvider: ServiceStatus] = [:]
    private var statusTasks: [UsageProvider: Task<Void, Never>] = [:]
    private let statusClient = ServiceStatusClient()
    private var tasks: [String: Task<Void, Never>] = [:]
    private let client = ProviderClient()
    private let official = OfficialCodexClient()
    private let directory: URL
    private var maySave = true
    var currentID: String { preferences.selected[provider] ?? "local-" + provider.rawValue }
    var current: UsageSnapshot? { snapshots[currentID] }
    var enabledProviders: [UsageProvider] { UsageProvider.allCases.filter { preferences.enabled.contains($0) } }
    init(directory: URL) {
        self.directory = directory
        let file = directory.appendingPathComponent("usage-preferences.json")
        if let data = try? Data(contentsOf: file) {
            do {
                preferences = try JSONDecoder().decode(UsagePreferences.self, from: data)
                preferences.accounts = preferences.accounts.filter { UUID(uuidString: $0.id) != nil && [.codex, .deepseek, .opencodego].contains($0.provider) }
                preferences.selected = preferences.selected.filter { provider, id in preferences.accounts.contains { $0.provider == provider && $0.id == id } }
            }
            catch { maySave = false; configurationError = "用量设置无法读取，已保留原文件。" }
        }
        if let bytes = try? Data(contentsOf: directory.appendingPathComponent("usage-history.json")), let decoded = try? JSONDecoder().decode([UsageSnapshot].self, from: bytes) {
            history = Array(decoded.suffix(1800))
        }
        provider = enabledProviders.first ?? .codex
        // Local-agent login can change while this app is closed. No cached local-account
        // snapshot is shown until its credentials have been revalidated in this process.
    }
    func enable(_ value: UsageProvider, _ enabled: Bool) {
        if enabled { preferences.enabled.insert(value) } else {
            preferences.enabled.remove(value)
            statusTasks[value]?.cancel(); serviceStatuses[value] = nil
            for key in tasks.keys { if key == "local-" + value.rawValue || preferences.accounts.contains(where: { $0.id == key && $0.provider == value }) { tasks[key]?.cancel() } }
        }
        if !preferences.enabled.contains(provider) { provider = enabledProviders.first ?? .codex }
        save()
    }
    func save() {
        guard maySave else { return }
        do { try PrivateMetadata.save(preferences, to: directory.appendingPathComponent("usage-preferences.json")); configurationError = nil }
        catch { configurationError = "用量设置无法保存。" }
    }
    func add(_ account: UsageAccount, credential: Data) throws {
        guard maySave, account.id != "local", !account.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CredentialError.invalid }
        if account.provider == .codex { guard CodexCredentials.isValid(credential) else { throw CredentialError.invalid } }
        try CredentialStore.save(credential, id: account.id)
        var next = preferences
        next.accounts.append(account); next.enabled.insert(account.provider); next.selected[account.provider] = account.id
        do { try PrivateMetadata.save(next, to: directory.appendingPathComponent("usage-preferences.json")) }
        catch { try? CredentialStore.remove(account.id); throw error }
        preferences = next; provider = account.provider
    }
    func remove(_ account: UsageAccount) throws {
        guard maySave else { throw CredentialError.invalid }
        try CredentialStore.remove(account.id)
        tasks[account.id]?.cancel(); snapshots[account.id] = nil; errors[account.id] = nil
        preferences.accounts.removeAll { $0.id == account.id }; preferences.selected[account.provider] = nil
        history.removeAll { $0.accountID == account.id }; save(); saveHistory()
    }
    func select(_ id: String?, for value: UsageProvider) {
        preferences.selected[value] = id; save()
    }
    func refresh(codexHome: URL, force: Bool = false) {
        refresh(provider, id: currentID, codexHome: codexHome, force: force)
    }
    func refreshAll(codexHome: URL) {
        for value in enabledProviders {
            refresh(value, id: preferences.selected[value] ?? "local-" + value.rawValue, codexHome: codexHome, force: true)
        }
    }
    private func refresh(_ value: UsageProvider, id: String, codexHome: URL, force: Bool) {
        guard preferences.enabled.contains(value), !CommandLine.arguments.contains("--demo") else { return }
        refreshStatus(value, force: force)
        guard !loading.contains(id) else { return }
        if value == .codex && id.hasPrefix("local-") {
            do {
                let identity = CodexCredentials.fingerprint(try CodexCredentials.read(home: codexHome))
                if snapshots[id]?.accountID != identity { snapshots[id] = nil }
            } catch { snapshots[id] = nil; errors[id] = error.localizedDescription; return }
        }
        if !force, let snapshot = snapshots[id], Date().timeIntervalSince(snapshot.fetchedAt) < 300 { return }
        loading.insert(id); errors[id] = nil
        tasks[id] = Task {
            defer { loading.remove(id); tasks[id] = nil }
            do {
                let account = preferences.accounts.first { $0.id == id && $0.provider == value }
                let credentials = try account.flatMap { try CredentialStore.read($0.id) }
                if account != nil && credentials == nil { throw ProviderReadError.missingLogin }
                var snapshot: UsageSnapshot
                if value == .codex {
                    let bytes = try credentials ?? CodexCredentials.read(home: codexHome)
                    let fingerprint = CodexCredentials.fingerprint(bytes)
                    // Discard an earlier local cache before asking a changed login for quotas.
                    if account == nil, snapshots[id]?.accountID != fingerprint { snapshots[id] = nil }
                    let result = try await official.account(codexHome: codexHome, dataDirectory: directory, credentials: bytes)
                    if account == nil {
                        let currentIdentity = CodexCredentials.fingerprint(try CodexCredentials.read(home: codexHome))
                        guard currentIdentity == fingerprint else { throw CredentialError.invalid }
                    }
                    snapshot = UsageSnapshot(provider: .codex, accountID: account == nil ? fingerprint : id, source: "官方 Codex app-server")
                    snapshot.plan = result.plan; snapshot.tokens = result.lifetimeTokens; snapshot.todayTokens = result.todayTokens
                    snapshot.availableResetCards = result.availableResetCards; snapshot.resetCardExpiresAt = result.resetCardExpiresAt
                    snapshot.note = result.tokenNote ?? result.quotaNote
                    for bucket in result.buckets {
                        for window in bucket.windows {
                            snapshot.meters.append(UsageMeter(id: bucket.id + "-" + window.id, title: (result.buckets.count > 1 ? (bucket.name ?? bucket.id) + " · " : "") + window.label,
                                remainingPercent: window.remainingPercent, resetsAt: window.resetsAt))
                        }
                        if bucket.id == "codex", let credits = bucket.creditsBalance.flatMap(Double.init), credits.isFinite, credits >= 0 { snapshot.balance = credits; snapshot.currency = "购买额度" }
                    }
                } else {
                    snapshot = try await client.fetch(value, credential: credentials.map { String(decoding: $0, as: UTF8.self) }, accountID: id)
                }
                try Task.checkCancellation()
                guard preferences.enabled.contains(value) else { return }
                snapshots[id] = snapshot
                let day = Calendar.current.startOfDay(for: snapshot.fetchedAt)
                history.removeAll { $0.provider == value && $0.accountID == snapshot.accountID && $0.fetchedAt >= day }
                history.append(snapshot)
                history = Array(history.filter { $0.fetchedAt > Date().addingTimeInterval(-90 * 86400) }.suffix(1800))
                saveHistory()
            } catch is CancellationError { }
            catch {
                if value == .codex && accountIsLocal(id) { snapshots[id] = nil }
                errors[id] = error.localizedDescription
            }
        }
    }
    private func accountIsLocal(_ id: String) -> Bool { id.hasPrefix("local-") }
    private func saveHistory() {
        guard maySave else { return }
        do { try PrivateMetadata.save(history, to: directory.appendingPathComponent("usage-history.json")) }
        catch { configurationError = "用量历史保存失败。" }
    }
    private func refreshStatus(_ value: UsageProvider, force: Bool) {
        guard statusTasks[value] == nil else { return }
        if !force, let status = serviceStatuses[value], Date().timeIntervalSince(status.fetchedAt) < 300 { return }
        statusTasks[value] = Task {
            defer { statusTasks[value] = nil }
            let status = await statusClient.fetch(value)
            guard !Task.isCancelled, preferences.enabled.contains(value) else { return }
            serviceStatuses[value] = status
        }
    }
    func shutdown() {
        for task in tasks.values { task.cancel() }
        for task in statusTasks.values { task.cancel() }
    }
}
