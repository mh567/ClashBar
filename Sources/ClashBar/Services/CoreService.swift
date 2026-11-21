import Darwin
import Foundation

enum CoreLifecycleStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32)
    case failed(reason: String)
}

protocol MihomoControlling: AnyObject, Sendable {
    var status: CoreLifecycleStatus { get }
    var isRunning: Bool { get }
    var detectedBinaryPath: String? { get }
    func validateConfigAsync(configPath: String) async throws
    @discardableResult
    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus
    func stop()
    func stopAsync() async
    @discardableResult
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus

    func validateConfig(configPath: String) async throws
    @discardableResult
    func start(configPath: String, controller: String) async throws -> CoreLifecycleStatus
    func stopImmediately()
    @discardableResult
    func restart(configPath: String, controller: String) async throws -> CoreLifecycleStatus
}

extension MihomoControlling {
    func validateConfig(configPath: String) async throws {
        try await self.validateConfigAsync(configPath: configPath)
    }

    @discardableResult
    func start(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        try await self.startAsync(configPath: configPath, controller: controller)
    }

    func stopImmediately() {
        self.stop()
    }

    func stop() async {
        await self.stopAsync()
    }

    @discardableResult
    func restart(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        try await self.restartAsync(configPath: configPath, controller: controller)
    }
}

enum MihomoBinaryResolutionError: LocalizedError {
    case binaryNotFound(expectedDirectory: String)

    var errorDescription: String? {
        switch self {
        case let .binaryNotFound(expectedDirectory):
            "mihomo binary not found. Expected an executable named 'mihomo' in \(expectedDirectory)."
        }
    }
}

enum MihomoConfigValidationError: LocalizedError {
    case launchFailed(String)
    case timedOut(seconds: Int, details: String)
    case failed(exitCode: Int32, details: String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return message
        case let .timedOut(seconds, details):
            let normalizedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedDetails.isEmpty {
                return "mihomo -t timed out after \(seconds) seconds."
            }
            return "mihomo -t timed out after \(seconds) seconds.\n\(normalizedDetails)"
        case let .failed(exitCode, details):
            let normalizedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedDetails.isEmpty {
                return "mihomo -t exited with code \(exitCode)."
            }
            return normalizedDetails
        }
    }
}

private final class LogFloodGate: @unchecked Sendable {
    private let maxLinesPerWindow = 200
    private let windowNanoseconds: UInt64 = 1_000_000_000
    private var windowStart: UInt64 = 0
    private var emitted = 0
    private var dropped = 0
    private var lastLine: String?

    func accept(_ lines: [String], now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> [String] {
        var accepted: [String] = []
        for line in lines {
            if now &- self.windowStart >= self.windowNanoseconds {
                if self.dropped > 0 {
                    accepted.append("[mihomo log] dropped \(self.dropped) flooding lines")
                }
                self.windowStart = now
                self.emitted = 0
                self.dropped = 0
                self.lastLine = nil
            }
            guard line != self.lastLine, self.emitted < self.maxLinesPerWindow else {
                self.dropped += 1
                continue
            }
            self.lastLine = line
            self.emitted += 1
            accepted.append(line)
        }
        return accepted
    }
}

private final class LineAccumulator: @unchecked Sendable {
    private var carry = Data()

    func append(_ data: Data) -> [String] {
        self.carry.append(data)
        var lines: [String] = []
        while let newlineIndex = self.carry.firstIndex(of: 0x0A) {
            let lineData = self.carry.subdata(in: self.carry.startIndex..<newlineIndex)
            self.carry.removeSubrange(self.carry.startIndex...newlineIndex)
            if let line = Self.normalize(lineData) {
                lines.append(line)
            }
        }
        return lines
    }

    func flushRemaining() -> String? {
        guard !self.carry.isEmpty else { return nil }
        let tail = self.carry
        self.carry = Data()
        return Self.normalize(tail)
    }

    private static func normalize(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class ProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ data: Data) {
        self.lock.withLock {
            self.data = data
        }
    }

    func load() -> Data {
        self.lock.withLock {
            self.data
        }
    }
}

final class MihomoProcessManager: MihomoControlling, @unchecked Sendable {
    private var storedStatus: CoreLifecycleStatus = .stopped
    var status: CoreLifecycleStatus {
        self.lock.withLock { self.storedStatus }
    }
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var intentionalStop = false
    private let lock = NSLock()
    private let fileManager: FileManager
    private let workingDirectoryManager: WorkingDirectoryManager
    private let lifecycleQueue: DispatchQueue
    private let validationQueue: DispatchQueue
    private let configValidationTimeout: TimeInterval
    private let resolutionLock = NSLock()
    private var probedCoreVersions: [String: ProbedCoreVersion] = [:]
    private var loggedManagedCoreDecision = false

    var onLog: ((String) -> Void)?
    var onTermination: ((Int32) -> Void)?

    var detectedBinaryPath: String? {
        try? self.resolveMihomoBinary()
    }

    /// Off-main-thread variant of `detectedBinaryPath`.
    ///
    /// Resolution can copy bundled assets and run `gunzip`, which on first launch
    /// takes long enough to be visible if performed on the main actor.
    func detectedBinaryPathAsync() async -> String? {
        await withCheckedContinuation { continuation in
            self.validationQueue.async {
                continuation.resume(returning: try? self.resolveMihomoBinary())
            }
        }
    }

    var isRunning: Bool {
        self.lock.withLock {
            self.process?.isRunning == true
        }
    }

    init(
        workingDirectoryManager: WorkingDirectoryManager = WorkingDirectoryManager(),
        fileManager: FileManager = .default,
        configValidationTimeout: TimeInterval = 10,
        lifecycleQueue: DispatchQueue? = nil,
        validationQueue: DispatchQueue? = nil)
    {
        self.workingDirectoryManager = workingDirectoryManager
        self.fileManager = fileManager
        self.configValidationTimeout = configValidationTimeout
        self.lifecycleQueue = lifecycleQueue
            ?? DispatchQueue(label: "com.clashbar.mihomo-process.operations", qos: .userInitiated)
        self.validationQueue = validationQueue
            ?? DispatchQueue(label: "com.clashbar.mihomo-process.validation", qos: .userInitiated)
    }

    deinit {
        stop()
    }

    func validateConfig(configPath: String) throws {
        let binary = try resolveMihomoBinary()

        let workingDirectoryURL = Self.resolveWorkingDirectoryURL(configPath: configPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.currentDirectoryURL = workingDirectoryURL
        proc.arguments = ["-d", workingDirectoryURL.path, "-f", configPath, "-t"]

        let outputPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = outputPipe
        let outputBox = ProcessOutputBox()
        let outputDrainGroup = DispatchGroup()
        outputDrainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            outputBox.store(outputData)
            outputDrainGroup.leave()
        }

        do {
            try proc.run()
        } catch {
            throw MihomoConfigValidationError.launchFailed("Failed to run mihomo -t: \(error.localizedDescription)")
        }

        let didExit = self.waitForProcessExit(proc, timeout: self.configValidationTimeout)
        if !didExit {
            self.onLog?("[mihomo config test] timeout after \(self.normalizedValidationTimeoutSeconds())s")
            proc.terminate()
            if !self.waitForProcessExit(proc, timeout: 1.0) {
                _ = Darwin.kill(proc.processIdentifier, SIGKILL)
                _ = self.waitForProcessExit(proc, timeout: 0.5)
            }
        }

        _ = outputDrainGroup.wait(timeout: .now() + 1.0)
        let outputData = outputBox.load()
        let outputText = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard didExit else {
            throw MihomoConfigValidationError.timedOut(
                seconds: self.normalizedValidationTimeoutSeconds(),
                details: outputText)
        }

        guard proc.terminationStatus == 0 else {
            throw MihomoConfigValidationError.failed(exitCode: proc.terminationStatus, details: outputText)
        }

        if !outputText.isEmpty {
            self.onLog?("[mihomo config test] \(outputText)")
        }
    }

    func validateConfigAsync(configPath: String) async throws {
        try await self.runBlockingOperation(on: self.validationQueue) {
            try self.validateConfig(configPath: configPath)
        }
    }

    @discardableResult
    func start(configPath: String, controller: String) throws -> CoreLifecycleStatus {
        if let runningPid = lock.withLock({ process?.isRunning == true ? process?.processIdentifier : nil }) {
            return .running(pid: runningPid)
        }

        try Self.checkControllerPortAvailability(controller)

        self.lock.withLock {
            self.intentionalStop = false
            self.storedStatus = .starting
        }

        let binary = try resolveMihomoBinary()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)

        let workingDirectoryURL = Self.resolveWorkingDirectoryURL(configPath: configPath)
        proc.currentDirectoryURL = workingDirectoryURL

        let args = ["-d", workingDirectoryURL.path, "-f", configPath, "-ext-ctl", controller]
        proc.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading

        self.wireLogPipe(stdout.fileHandleForReading)
        self.wireLogPipe(stderr.fileHandleForReading)

        proc.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            let code = terminatedProcess.terminationStatus
            self.handleProcessTermination(terminatedProcess, code: code)
        }

        do {
            try proc.run()
            self.lock.withLock {
                self.process = proc
                self.storedStatus = .running(pid: proc.processIdentifier)
            }
            let startMessage =
                "[mihomo started] pid=\(proc.processIdentifier) " +
                "controller=\(controller) " +
                "binary=\(binary) " +
                "workdir=\(workingDirectoryURL.path)"
            self.onLog?(startMessage)
            return self.status
        } catch {
            let reason = "Failed to launch mihomo: \(error.localizedDescription)"
            self.lock.withLock {
                self.storedStatus = .failed(reason: reason)
                self.intentionalStop = false
                self.releasePipeHandlesLocked()
            }
            self.onLog?("[mihomo error] \(reason)")
            throw error
        }
    }

    @discardableResult
    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        try await self.runBlockingOperation(on: self.lifecycleQueue) {
            try self.start(configPath: configPath, controller: controller)
        }
    }

    func stop() {
        let running: Process? = self.lock.withLock {
            self.intentionalStop = true
            return self.process
        }

        guard let running else {
            self.lock.withLock {
                self.storedStatus = .stopped
                self.intentionalStop = false
                self.releasePipeHandlesLocked()
            }
            return
        }

        guard running.isRunning else {
            self.handleProcessTermination(running, code: running.terminationStatus)
            return
        }

        self.onLog?("[mihomo stop] terminate signal sent pid=\(running.processIdentifier)")
        running.terminate()

        if self.waitForProcessExit(running, timeout: 2.0) {
            self.handleProcessTermination(running, code: running.terminationStatus)
            return
        }

        self.onLog?("[mihomo stop] force kill pid=\(running.processIdentifier)")
        _ = Darwin.kill(running.processIdentifier, SIGKILL)
        _ = self.waitForProcessExit(running, timeout: 1.0)
        self.handleProcessTermination(running, code: running.terminationStatus)
    }

    func stopImmediately() {
        let running: Process? = self.lock.withLock {
            self.intentionalStop = true
            return self.process
        }

        guard let running, running.isRunning else {
            self.lock.withLock {
                self.storedStatus = .stopped
                self.intentionalStop = false
                self.releasePipeHandlesLocked()
            }
            return
        }

        self.onLog?("[mihomo stop] terminate signal sent pid=\(running.processIdentifier)")
        running.terminate()

        // Bounded shutdown: give mihomo a short grace period to exit, then force
        // kill so the child is never orphaned when the app goes away. This runs
        // on the main thread during quit, hence the much tighter budget than
        // the regular stop() path (2s + 1s).
        if self.waitForProcessExit(running, timeout: 0.4) {
            self.handleProcessTermination(running, code: running.terminationStatus)
            return
        }

        self.onLog?("[mihomo stop] force kill pid=\(running.processIdentifier)")
        _ = Darwin.kill(running.processIdentifier, SIGKILL)
        _ = self.waitForProcessExit(running, timeout: 0.2)
        self.handleProcessTermination(running, code: running.terminationStatus)
    }

    func stopAsync() async {
        await self.runBlockingOperation(on: self.lifecycleQueue) {
            self.stop()
        }
    }

    @discardableResult
    func restart(configPath: String, controller: String) throws -> CoreLifecycleStatus {
        self.stop()
        return try self.start(configPath: configPath, controller: controller)
    }

    @discardableResult
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        try await self.runBlockingOperation(on: self.lifecycleQueue) {
            try self.restart(configPath: configPath, controller: controller)
        }
    }

    private func handleProcessTermination(_ terminatedProcess: Process, code: Int32) {
        let outcome = self.lock.withLock { () -> (handled: Bool, intentional: Bool) in
            guard let current = process, current === terminatedProcess else {
                return (false, false)
            }

            let intentional = self.intentionalStop
            self.intentionalStop = false
            self.process = nil
            self.storedStatus = .stopped
            self.releasePipeHandlesLocked()
            return (true, intentional)
        }

        guard outcome.handled else { return }

        if outcome.intentional {
            self.onLog?("[mihomo stopped] exit=\(code)")
        } else {
            self.onLog?("[mihomo terminated] exit=\(code)")
            self.onTermination?(code)
        }
    }

    private func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50000)
        }
        return !process.isRunning
    }

    private func runBlockingOperation<Value: Sendable>(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable () throws -> Value) async throws -> Value
    {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try continuation.resume(returning: operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runBlockingOperation(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable () -> Void) async
    {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }

    private func normalizedValidationTimeoutSeconds() -> Int {
        max(1, Int(self.configValidationTimeout.rounded(.awayFromZero)))
    }

    private struct BundledCoreCandidate {
        let path: String
        let isCompressed: Bool
        let version: AppSemanticVersion?
    }

    private struct ProbedCoreVersion {
        let size: UInt64
        let modifiedAt: Date?
        let version: AppSemanticVersion?
    }

    private func resolveMihomoBinary() throws -> String {
        try self.resolutionLock.withLock {
            try self.resolveMihomoBinaryLocked()
        }
    }

    /// Newest core wins: a locally upgraded managed core is never downgraded by
    /// an app update that still ships an older payload, and a bundled payload
    /// newer than the managed copy replaces it.
    private func resolveMihomoBinaryLocked() throws -> String {
        try self.workingDirectoryManager.bootstrapDirectories(fileManager: self.fileManager)

        let managedBinaryPath = self.workingDirectoryManager.managedMihomoBinaryURL.path
        let managedExists = self.fileManager.fileExists(atPath: managedBinaryPath)
        if managedExists {
            try self.ensureExecutableIfNeeded(at: managedBinaryPath)
            try self.validateBinarySecurity(at: managedBinaryPath)
        }

        guard let bundled = try self.bundledCoreCandidate() else {
            guard managedExists, self.fileManager.isExecutableFile(atPath: managedBinaryPath) else {
                throw MihomoBinaryResolutionError.binaryNotFound(
                    expectedDirectory: self.workingDirectoryManager.coreDirectoryURL.path)
            }
            return managedBinaryPath
        }

        guard managedExists else {
            return try self.installBundledCore(bundled, managedPath: managedBinaryPath)
        }

        // Never swap the binary a live mihomo process is running from.
        guard !self.isRunning else { return managedBinaryPath }

        let managedVersion = self.probedVersion(at: managedBinaryPath)
        // An unreadable bundled version cannot prove it is newer, so it never
        // replaces the managed core.
        let preferBundled = bundled.version.map {
            MihomoCoreVersion.shouldPreferBundled(managed: managedVersion, bundled: $0)
        } ?? false
        if preferBundled {
            do {
                return try self.installBundledCore(bundled, managedPath: managedBinaryPath)
            } catch {
                self.onLog?(
                    "[mihomo binary] failed to install bundled core, keeping managed core: "
                        + error.localizedDescription)
                return managedBinaryPath
            }
        }

        guard !self.loggedManagedCoreDecision else { return managedBinaryPath }
        self.loggedManagedCoreDecision = true
        let managedText = managedVersion.map { "v\($0.displayString)" } ?? "unknown"
        let bundledText = bundled.version.map { "v\($0.displayString)" } ?? "unknown"
        self.onLog?(
            "[mihomo binary] kept managed core \(managedText) (bundled payload is \(bundledText))")
        return managedBinaryPath
    }

    private func bundledCoreCandidate() throws -> BundledCoreCandidate? {
        if let bundledBinaryPath = self.firstBundledExecutableBinaryPath() {
            try self.validateBinarySecurity(at: bundledBinaryPath)
            return BundledCoreCandidate(
                path: bundledBinaryPath,
                isCompressed: false,
                version: self.probedVersion(at: bundledBinaryPath))
        }

        if let bundledCompressedBinaryPath = self.firstBundledCompressedBinaryPath() {
            try self.validateBinarySecurity(at: bundledCompressedBinaryPath)
            return BundledCoreCandidate(
                path: bundledCompressedBinaryPath,
                isCompressed: true,
                version: self.bundledCompressedCoreVersion(bundledCompressedBinaryPath))
        }

        return nil
    }

    private func bundledCompressedCoreVersion(_ compressedPath: String) -> AppSemanticVersion? {
        if let versionURL = self.bundledVersionFileURL(near: compressedPath),
           let version = MihomoCoreVersion.readVersionFile(at: versionURL)
        {
            return version
        }
        return self.probedVersion(fromCompressedBinaryAt: compressedPath)
    }

    private func bundledVersionFileURL(near path: String) -> URL? {
        let sibling = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent(MihomoCoreVersion.bundledVersionFileName, isDirectory: false)
        if self.fileManager.fileExists(atPath: sibling.path) {
            return sibling
        }

        let relativeLayouts = [
            "bin/\(MihomoCoreVersion.bundledVersionFileName)",
            "Resources/bin/\(MihomoCoreVersion.bundledVersionFileName)",
            MihomoCoreVersion.bundledVersionFileName,
        ]
        for root in AppResourceBundleLocator.candidateResourceRoots() {
            for relative in relativeLayouts {
                let candidate = root.appendingPathComponent(relative, isDirectory: false)
                if self.fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func probedVersion(at path: String) -> AppSemanticVersion? {
        let attributes = try? self.fileManager.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let modifiedAt = attributes?[.modificationDate] as? Date
        if let size, let cached = self.probedCoreVersions[path],
           cached.size == size, cached.modifiedAt == modifiedAt
        {
            return cached.version
        }

        let version = MihomoCoreVersion.probe(at: path)
        if let size {
            self.probedCoreVersions[path] = ProbedCoreVersion(
                size: size, modifiedAt: modifiedAt, version: version)
        }
        return version
    }

    private func probedVersion(fromCompressedBinaryAt compressedPath: String) -> AppSemanticVersion? {
        let attributes = try? self.fileManager.attributesOfItem(atPath: compressedPath)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let modifiedAt = attributes?[.modificationDate] as? Date
        if let size, let cached = self.probedCoreVersions[compressedPath],
           cached.size == size, cached.modifiedAt == modifiedAt
        {
            return cached.version
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clashbar-core-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? self.fileManager.removeItem(at: directory) }
        guard (try? self.fileManager.createDirectory(
            at: directory, withIntermediateDirectories: false)) != nil
        else { return nil }

        let decompressedPath = directory.appendingPathComponent("mihomo", isDirectory: false).path
        guard (try? self.gunzip(compressedPath, to: decompressedPath)) != nil else { return nil }

        let version = MihomoCoreVersion.probe(at: decompressedPath)
        if let size {
            self.probedCoreVersions[compressedPath] = ProbedCoreVersion(
                size: size, modifiedAt: modifiedAt, version: version)
        }
        return version
    }

    private func installBundledCore(_ candidate: BundledCoreCandidate, managedPath: String) throws -> String {
        let stagingPath = managedPath + ".staging-\(UUID().uuidString)"
        defer { try? self.fileManager.removeItem(atPath: stagingPath) }

        if candidate.isCompressed {
            try self.gunzip(candidate.path, to: stagingPath)
        } else {
            if self.fileManager.fileExists(atPath: stagingPath) {
                try self.fileManager.removeItem(atPath: stagingPath)
            }
            try self.fileManager.copyItem(atPath: candidate.path, toPath: stagingPath)
        }

        try self.ensureExecutableIfNeeded(at: stagingPath)
        try self.validateBinarySecurity(at: stagingPath)

        guard Darwin.rename(stagingPath, managedPath) == 0 else {
            throw NSError(
                domain: "ClashBar.Core",
                code: 500,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "failed to replace mihomo binary at \(managedPath) (errno \(errno))",
                ])
        }

        self.probedCoreVersions.removeValue(forKey: managedPath)
        let versionText = self.probedVersion(at: managedPath)?.displayString
            ?? candidate.version?.displayString
            ?? "unknown"
        self.onLog?("[mihomo binary] installed bundled core v\(versionText) to \(managedPath)")
        return managedPath
    }

    private func gunzip(_ compressedPath: String, to outputPath: String) throws {
        self.fileManager.createFile(atPath: outputPath, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", compressedPath]
        process.standardOutput = outputHandle
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
            try outputHandle.close()

            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
                throw NSError(
                    domain: "ClashBar.Core",
                    code: 500,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "failed to decompress bundled mihomo binary from \(compressedPath): \(errorText)",
                    ])
            }
        } catch {
            try? outputHandle.close()
            if let error = error as NSError?, error.domain == "ClashBar.Core" {
                throw error
            }
            throw NSError(
                domain: "ClashBar.Core",
                code: 500,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "failed to migrate compressed mihomo binary from \(compressedPath): \(error.localizedDescription)",
                ])
        }
    }


    private func firstBundledExecutableBinaryPath() -> String? {
        for candidate in self.bundledBinaryCandidates() where self.fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func firstBundledCompressedBinaryPath() -> String? {
        for candidate in self.bundledCompressedBinaryCandidates() where self.fileManager.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func bundledBinaryCandidates() -> [String] {
        Self.bundledBinaryCandidates(binaryName: "mihomo")
    }

    private func bundledCompressedBinaryCandidates() -> [String] {
        Self.bundledBinaryCandidates(binaryName: "mihomo.gz")
    }

    private static func bundledBinaryCandidates(binaryName: String) -> [String] {
        let resourceRoots = AppResourceBundleLocator.candidateResourceRoots()
        let relativeLayouts = ["bin/\(binaryName)", "Resources/bin/\(binaryName)", binaryName]

        var deduplicated: [String] = []
        var seen = Set<String>()
        for root in resourceRoots {
            for relative in relativeLayouts {
                let normalized = root.appendingPathComponent(relative).standardizedFileURL.path
                if seen.insert(normalized).inserted {
                    deduplicated.append(normalized)
                }
            }
        }
        return deduplicated
    }

    private func ensureExecutableIfNeeded(at path: String) throws {
        guard self.fileManager.fileExists(atPath: path) else {
            throw NSError(
                domain: "ClashBar.Core",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "mihomo binary not found at \(path)"])
        }

        guard !self.fileManager.isExecutableFile(atPath: path) else { return }
        try self.fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func validateBinarySecurity(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])

        if values.isSymbolicLink == true {
            throw NSError(
                domain: "ClashBar.Core",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "mihomo binary path must not be a symbolic link: \(path)"])
        }
        if values.isRegularFile != true {
            throw NSError(
                domain: "ClashBar.Core",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "mihomo binary must be a regular file: \(path)"])
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let uid = Int(getuid())
        if let owner = attrs[.ownerAccountID] as? NSNumber {
            let ownerID = owner.intValue
            if ownerID != 0, ownerID != uid {
                throw NSError(
                    domain: "ClashBar.Core",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "mihomo binary owner must be current user or root: \(path)"])
            }
        }

        if let perm = attrs[.posixPermissions] as? NSNumber {
            let mode = perm.intValue
            if (mode & 0o022) != 0 {
                throw NSError(
                    domain: "ClashBar.Core",
                    code: 403,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "mihomo binary permissions are too permissive " +
                            "(writable by group/others): \(path)",
                    ])
            }
        }
    }

    static func checkControllerPortAvailability(_ controller: String) throws {
        guard let address = URLComponents(string: "http://" + controller), let port = address.port else { return }
        let host = address.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo()
        hints.ai_flags = AI_PASSIVE
        hints.ai_socktype = SOCK_STREAM
        var interfaces: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host?.isEmpty == true ? nil : host, String(port), &hints, &interfaces) == 0,
              let first = interfaces
        else { return }
        defer { freeaddrinfo(first) }
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let pointer = next {
            let address = pointer.pointee
            next = address.ai_next
            let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            if fd >= 0 {
                var reuse: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                let result = Darwin.bind(fd, address.ai_addr, address.ai_addrlen)
                let reason = errno
                Darwin.close(fd)
                if result != 0, reason == EADDRINUSE { throw POSIXError(.EADDRINUSE) }
            }
        }
    }

    private static func resolveWorkingDirectoryURL(configPath: String) -> URL {
        let configDirectoryURL = URL(fileURLWithPath: configPath)
            .standardizedFileURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        if configDirectoryURL.lastPathComponent == "config" {
            return configDirectoryURL.deletingLastPathComponent()
        }
        return configDirectoryURL
    }

    private func wireLogPipe(_ handle: FileHandle) {
        let accumulator = LineAccumulator()
        let gate = LogFloodGate()
        handle.readabilityHandler = { [weak self] readable in
            let data = readable.availableData
            if data.isEmpty {
                if let tail = accumulator.flushRemaining() {
                    self?.onLog?(tail)
                }
                return
            }
            for line in gate.accept(accumulator.append(data)) {
                self?.onLog?(line)
            }
        }
    }

    private func releasePipeHandlesLocked() {
        self.stdoutHandle?.readabilityHandler = nil
        self.stderrHandle?.readabilityHandler = nil
        self.stdoutHandle?.closeFile()
        self.stderrHandle?.closeFile()
        self.stdoutHandle = nil
        self.stderrHandle = nil
    }
}
