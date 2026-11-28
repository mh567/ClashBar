import CryptoKit
import Foundation
import ProxyHelperShared

/// On-disk record of the mihomo process this app launched. It is the only way a
/// later launch can tell its own orphaned core from a foreign process, because
/// `Process` handles and PIDs live only in memory.
struct CoreRuntimeState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let bootIdentifier: String
    let pid: Int32
    let processStartTime: UInt64
    let binaryPath: String
    let configPath: String
    let configFingerprint: String
    let controller: String

    static func fingerprint(ofContentsAt path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum CoreRuntimeStateResolution: Equatable, Sendable {
    case none
    case adopt
    case replace
    case ignore
}

enum CoreRuntimeStateEvaluator {
    static func resolve(
        recorded: CoreRuntimeState?,
        bootIdentifier: String,
        process: CoreProcessSnapshot?,
        expectedController: String,
        configFingerprint: String)
        -> CoreRuntimeStateResolution
    {
        guard let recorded else { return .none }
        guard recorded.schemaVersion == CoreRuntimeState.currentSchemaVersion else { return .ignore }
        guard recorded.bootIdentifier == bootIdentifier else { return .ignore }
        guard let process else { return .ignore }
        guard process.startTime == recorded.processStartTime else { return .ignore }
        guard CoreProcessIdentity.normalizedPath(process.executablePath)
            == CoreProcessIdentity.normalizedPath(recorded.binaryPath)
        else {
            return .ignore
        }

        guard recorded.configFingerprint == configFingerprint,
              recorded.controller == expectedController
        else { return .replace }
        return .adopt
    }
}

struct CoreRuntimeStateStore {
    let fileURL: URL
    private let fileManager: FileManager

    init(
        workingDirectoryManager: WorkingDirectoryManager,
        fileManager: FileManager = .default)
    {
        self.fileURL = workingDirectoryManager.stateDirectoryURL
            .appendingPathComponent("core-runtime-state.json", isDirectory: false)
        self.fileManager = fileManager
    }

    func load() -> CoreRuntimeState? {
        guard let data = try? Data(contentsOf: self.fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CoreRuntimeState.self, from: data)
    }

    func save(_ state: CoreRuntimeState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try self.fileManager.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: self.fileURL, options: .atomic)
    }

    func clear() {
        try? self.fileManager.removeItem(at: self.fileURL)
    }
}
