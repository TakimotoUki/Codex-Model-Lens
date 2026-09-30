import Foundation
import ModelLensCore

@main
struct LensCLI {
    static func main() async {
        let args = CommandLine.arguments
        func argument(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if args.contains("--help") {
            print("model-lens [--home PATH] [--desktop-logs PATH] [--evidence PATH] [--output FILE] [--history FILE] [--requests-csv FILE] [--client-offline] [--summary]")
            return
        }
        let home = (argument("--home") ?? ProcessInfo.processInfo.environment["CODEX_HOME"]).map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        if let name = argument("--provider"), let provider = UsageProvider(rawValue: name), provider != .codex {
            do {
                let value = try await ProviderClient().fetch(provider)
                guard let output = argument("--output") else { throw ProviderReadError.invalidResponse }
                try PrivateMetadata.save(value, to: URL(fileURLWithPath: output))
                print("Provider metadata saved: \(provider.title); quota windows: \(value.meters.count); token data: \(value.tokens != nil)")
            } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
            return
        }
        if args.contains("--account") {
            do {
                guard let directory = argument("--data-directory"), let destination = argument("--output") else {
                    throw OfficialClientError.serviceUnavailable
                }
                let value = try await OfficialCodexClient().account(codexHome: home, dataDirectory: URL(fileURLWithPath: directory))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let url = URL(fileURLWithPath: destination)
                try encoder.encode(value).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                print("Account metadata saved. Plan: \(value.plan ?? "unknown"); quota buckets: \(value.buckets.count); account tokens available: \(value.lifetimeTokens != nil)")
            } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
            return
        }
        let config = ScannerConfiguration(codexHome: home,
                                          desktopLogs: argument("--desktop-logs").map { URL(fileURLWithPath: $0) },
                                          importedEvidence: argument("--evidence").map { URL(fileURLWithPath: $0) })
        let result = await CodexScanner(configuration: config).scan(clientIsRunning: !args.contains("--client-offline"))
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            if let path = argument("--output") { try encoder.encode(result).write(to: URL(fileURLWithPath: path), options: .atomic) }
            if let path = argument("--requests-csv") { try HistoryStore.exportRequestsCSV(result.requests).write(toFile: path, atomically: true, encoding: .utf8) }
            if let path = argument("--history") {
                let url = URL(fileURLWithPath: path)
                let existing = try HistoryStore.load(from: url)
                try HistoryStore.save(HistoryStore.merge(result, into: existing), to: url)
            }
            if args.contains("--summary") {
                print("Tasks: \(result.threads.count); turns: \(result.threads.reduce(0) { $0 + $1.turns.count }); running: \(result.threads.filter(\.isRunning).count); unconfirmed: \(result.threads.filter(\.isUnconfirmed).count)")
                print("Server evidence: \(result.threads.flatMap(\.turns).flatMap(\.serverEvidence).count); differences: \(result.threads.filter(\.hasModelDifference).count); diagnostics: \(result.diagnostics.count)")
                let requests = RequestSummary(result.requests)
                print("Transport records: \(requests.rows); identified requests: \(requests.identifiedRequests); buffering: \(requests.bufferingRows); capacity messages: \(requests.capacityRows); overloaded codes: \(requests.overloadedRows); errors: \(requests.errorRows)")
                print("Read \(result.filesRead) files / \(result.bytesRead) bytes in \(String(format: "%.2f", result.duration)) s")
            } else if argument("--output") == nil { print(String(decoding: try encoder.encode(result), as: UTF8.self)) }
            if !result.diagnostics.isEmpty {
                for diagnostic in result.diagnostics.prefix(20) { FileHandle.standardError.write(Data("\(diagnostic.source): \(diagnostic.message)\n".utf8)) }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
}
