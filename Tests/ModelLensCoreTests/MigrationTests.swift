import Foundation
import Testing
@testable import ModelLensCore

@Suite("Recover partially migrated evidence")
struct MigrationTests {
    func directories() throws -> (URL, URL, URL) {
        let root = try fixtureDirectory()
        let old = root.appendingPathComponent("old"), current = root.appendingPathComponent("current")
        for directory in [old, current] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return (root, old, current)
    }
    func probe() -> ModelProbeReport {
        var response = ProbeResponse(responseID: "resp_test"); response.models = ["gpt-6-astra"]
        response.hasOutput = true; response.status = "completed"
        return ModelProbeReport(requestedModel: "gpt-6-astra", testedAt: Date(timeIntervalSince1970: 1000), duration: 1,
            exitCode: 0, timedOut: false, frames: 2, errorEvents: 0, responses: [response])
    }
    @Test func existingDirectoryStillRecoversProbeAndMissingSettings() throws {
        let (root, old, current) = try directories(); defer { try? FileManager.default.removeItem(at: root) }
        try HistoryStore.save(HistoryArchive(), to: current.appendingPathComponent("model-history.json"))
        try PrivateMetadata.save([probe()], to: old.appendingPathComponent("model-probes.json"))
        try Data(#"{"scanDesktopLogs":true}"#.utf8).write(to: old.appendingPathComponent("settings.json"))
        let result = LegacyStorageMigration.migrate(from: old, to: current)
        #expect(result.issues.isEmpty && result.changedFiles.count == 2)
        let recovered = try JSONDecoder().decode([ModelProbeReport].self, from: Data(contentsOf: current.appendingPathComponent("model-probes.json")))
        #expect(recovered.first?.isConfirmed == true)
        #expect(LegacyStorageMigration.migrate(from: old, to: current).changedFiles.isEmpty)
    }
    @Test func historiesMergeWithoutResurrectingRemovedTaskOrReplacingNewerSettings() throws {
        let (root, old, current) = try directories(); defer { try? FileManager.default.removeItem(at: root) }
        var before = HistoryArchive(); before.threads = [ThreadRecord(id: "old-only"), ThreadRecord(id: "removed")]
        var after = HistoryArchive(); after.threads = [ThreadRecord(id: "current-only")]; after.removedThreadIDs = ["removed"]
        try HistoryStore.save(before, to: old.appendingPathComponent("model-history.json"))
        try HistoryStore.save(after, to: current.appendingPathComponent("model-history.json"))
        try Data(#"{"marker":"old"}"#.utf8).write(to: old.appendingPathComponent("settings.json"))
        let settings = Data(#"{"marker":"current"}"#.utf8); try settings.write(to: current.appendingPathComponent("settings.json"))
        #expect(LegacyStorageMigration.migrate(from: old, to: current).issues.isEmpty)
        let result = try HistoryStore.load(from: current.appendingPathComponent("model-history.json"))
        #expect(Set(result.threads.map(\.id)) == ["old-only", "current-only"])
        #expect(result.removedThreadIDs == ["removed"])
        #expect(try Data(contentsOf: current.appendingPathComponent("settings.json")) == settings)
        #expect(LegacyStorageMigration.migrate(from: old, to: current).changedFiles.isEmpty)
    }
    @Test func damagedDestinationIsPreservedWhileOtherFilesRecover() throws {
        let (root, old, current) = try directories(); defer { try? FileManager.default.removeItem(at: root) }
        try PrivateMetadata.save([probe()], to: old.appendingPathComponent("model-probes.json"))
        let damaged = Data("damaged".utf8);try damaged.write(to: current.appendingPathComponent("model-probes.json"))
        try Data(#"{"phase":"idle"}"#.utf8).write(to: old.appendingPathComponent("pomodoro.json"))
        let result = LegacyStorageMigration.migrate(from: old, to: current)
        #expect(result.issues.count == 1 && result.changedFiles == ["pomodoro.json"])
        #expect(try Data(contentsOf: current.appendingPathComponent("model-probes.json")) == damaged)
    }

    @Test func newRequestedModelDoesNotErasePreviouslySavedServerEvidence() throws {
        let (root, old, current) = try directories(); defer { try? FileManager.default.removeItem(at: root) }
        let time = Date(timeIntervalSince1970: 1000)
        var originalTurn = TurnRecord(id: "turn", startedAt: time)
        originalTurn.evidence = [ModelEvidence(kind: .responseHeader, model: "gpt-5.6-luna", timestamp: time, source: "wire", locator: "1", responseID: "resp_test")]
        var original = ThreadRecord(id: "task"); original.turns = [originalTurn]
        var newer = original; newer.turns[0].evidence = []; newer.turns[0].requestedModel = "gpt-6-astra"
        var before = HistoryArchive(); before.threads = [original]
        var after = HistoryArchive(); after.threads = [newer]
        try HistoryStore.save(before, to: old.appendingPathComponent("model-history.json"))
        try HistoryStore.save(after, to: current.appendingPathComponent("model-history.json"))
        #expect(LegacyStorageMigration.migrate(from: old, to: current).issues.isEmpty)
        let result = try HistoryStore.load(from: current.appendingPathComponent("model-history.json"))
        #expect(result.threads.first?.latestTurn?.reportedModel == "gpt-5.6-luna")
        #expect(result.threads.first?.latestTurn?.hasModelDifference == true)
        #expect(LegacyStorageMigration.migrate(from: old, to: current).changedFiles.isEmpty)
    }

    @Test func completedMigrationDoesNotReadProtectedLegacyFilesAgain() throws {
        let (root, old, current) = try directories(); defer { try? FileManager.default.removeItem(at: root) }
        try PrivateMetadata.save([probe()], to: old.appendingPathComponent("model-probes.json"))
        #expect(LegacyStorageMigration.migrate(from: old, to: current).issues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("legacy-migration.json").path))
        try Data("unreadable legacy format".utf8).write(to: old.appendingPathComponent("model-probes.json"))
        let second = LegacyStorageMigration.migrate(from: old, to: current)
        #expect(second.issues.isEmpty && second.changedFiles.isEmpty)
        let recovered = try JSONDecoder().decode([ModelProbeReport].self, from: Data(contentsOf: current.appendingPathComponent("model-probes.json")))
        #expect(recovered.first?.isConfirmed == true)
    }
}
