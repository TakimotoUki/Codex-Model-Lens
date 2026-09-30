import Foundation

public struct StorageMigrationReport: Sendable {
    public var changedFiles: [String] = []
    public var issues: [String] = []
    public init() {}
}

public enum LegacyStorageMigration {
    // Check each file independently: an existing destination directory may be only
    // partially populated by an earlier launch. Originals and damaged files survive.
    public static func migrate(from legacy: URL, to destination: URL) -> StorageMigrationReport {
        var report = StorageMigrationReport()
        guard legacy.standardizedFileURL != destination.standardizedFileURL else { return report }
        let receiptURL = destination.appendingPathComponent("legacy-migration.json")
        if let bytes = try? Data(contentsOf: receiptURL), bytes.count <= 4096,
           let receipt = try? JSONDecoder().decode(MigrationReceipt.self, from: bytes),
           receipt.version == 1, receipt.legacyPath == legacy.standardizedFileURL.path { return report }
        var foundLegacyFiles = false
        for name in ["model-history.json", "model-probes.json", "settings.json", "pomodoro.json"] {
            let source = legacy.appendingPathComponent(name), target = destination.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            foundLegacyFiles = true
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? .max) <= 64 * 1024 * 1024 else { throw CredentialError.invalid }
                if FileManager.default.fileExists(atPath: target.path) {
                    let existing = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard existing.isRegularFile == true, existing.isSymbolicLink != true,
                          (existing.fileSize ?? .max) <= 64 * 1024 * 1024 else { throw CredentialError.invalid }
                }
                if name == "model-history.json" {
                    let old = try HistoryStore.load(from: source)
                    let current = try HistoryStore.load(from: target)
                    var baseline = old
                    baseline.removedThreadIDs = Set((old.removedThreadIDs ?? []) + (current.removedThreadIDs ?? [])).sorted()
                    var combined = HistoryStore.merge(ScanResult(scannedAt: max(old.savedAt, current.savedAt), threads: current.threads,
                        requests: current.requestRecords, logCoverage: current.logCoverage), into: baseline)
                    // Merging storage is not a new detection. Preserve the original
                    // timestamps so repeated launches do not rewrite the same archive.
                    let originals = Dictionary(grouping: old.threads + current.threads, by: \.id)
                    for index in combined.threads.indices {
                        if let copies = originals[combined.threads[index].id] {
                            combined.threads[index].firstDetectedAt = copies.map(\.firstDetectedAt).min() ?? combined.threads[index].firstDetectedAt
                            combined.threads[index].lastDetectedAt = copies.map(\.lastDetectedAt).max() ?? combined.threads[index].lastDetectedAt
                        }
                    }
                    combined.threads.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
                    combined.requests = combined.requestRecords.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
                    if try different(combined, at: target) {
                        try HistoryStore.save(combined, to: target); report.changedFiles.append(name)
                    }
                } else if name == "model-probes.json" {
                    let decoder = JSONDecoder()
                    let old = try decoder.decode([ModelProbeReport].self, from: Data(contentsOf: source))
                    let current: [ModelProbeReport] = FileManager.default.fileExists(atPath: target.path) ? try decoder.decode([ModelProbeReport].self, from: Data(contentsOf: target)) : []
                    var byID: [String: ModelProbeReport] = [:]
                    for value in old + current { byID[value.id] = value }
                    let merged: [ModelProbeReport] = byID.values.sorted { $0.testedAt == $1.testedAt ? $0.id < $1.id : $0.testedAt > $1.testedAt }
                    if try different(merged, at: target) { try PrivateMetadata.save(merged, to: target); report.changedFiles.append(name) }
                } else if !FileManager.default.fileExists(atPath: target.path) {
                    let bytes = try Data(contentsOf: source)
                    guard bytes.count <= 1024 * 1024, try JSONSerialization.jsonObject(with: bytes) is [String: Any] else { throw CredentialError.invalid }
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try bytes.write(to: target, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                    report.changedFiles.append(name)
                }
            } catch { report.issues.append("\(name) 未能迁移；现有文件与原文件均已保留。") }
        }
        let imports = legacy.appendingPathComponent("ImportedEvidence")
        for source in (try? FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? [] where source.pathExtension == "jsonl" {
            foundLegacyFiles = true
            let target = destination.appendingPathComponent("ImportedEvidence").appendingPathComponent(source.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= 32 * 1024 * 1024 else { throw CredentialError.invalid }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: source, to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                report.changedFiles.append("ImportedEvidence/" + source.lastPathComponent)
            } catch { report.issues.append("一份导入证据未能迁移；原文件已保留。") }
        }
        if foundLegacyFiles && report.issues.isEmpty {
            do { try PrivateMetadata.save(MigrationReceipt(legacyPath: legacy.standardizedFileURL.path), to: receiptURL) }
            catch { report.issues.append("迁移已完成，但无法保存完成标记。") }
        }
        return report
    }
    private static func different<T: Codable>(_ value: T, at target: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: target.path) else { return true }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let prior = try JSONDecoder().decode(T.self, from: Data(contentsOf: target))
        return try encoder.encode(prior) != encoder.encode(value)
    }
}

private struct MigrationReceipt: Codable {
    var version = 1
    var legacyPath: String
}
