import XCTest
@testable import ClashBar

final class CoreRuntimeStateTests: XCTestCase {
    private let bootIdentifier = "boot-1"
    private let binaryPath = "/tmp/clashbar/core/mihomo"
    private let configPath = "/tmp/clashbar/config/test.yaml"

    func testResolveWithoutRecordReturnsNone() {
        XCTAssertEqual(
            CoreRuntimeStateEvaluator.resolve(
                recorded: nil,
                bootIdentifier: self.bootIdentifier,
                process: self.snapshot(),
                expectedController: "127.0.0.1:9090",
                configFingerprint: "hash"),
            .none)
    }

    func testResolveFromPreviousBootIsIgnored() {
        var record = self.record()
        record = self.copying(record, bootIdentifier: "boot-0")
        XCTAssertEqual(self.resolve(record, process: self.snapshot()), .ignore)
    }

    func testResolveWithReusedPIDIsIgnored() {
        let record = self.record()
        XCTAssertEqual(self.resolve(record, process: self.snapshot(startTime: 999)), .ignore)
    }

    func testResolveWithDifferentExecutableIsIgnored() {
        let record = self.record()
        XCTAssertEqual(
            self.resolve(record, process: self.snapshot(executablePath: "/usr/local/bin/other")),
            .ignore)
    }

    func testResolveAdoptsMatchingCore() {
        XCTAssertEqual(self.resolve(self.record(), process: self.snapshot()), .adopt)
    }

    func testResolveReplacesWhenConfigChanged() {
        XCTAssertEqual(
            self.resolve(self.record(), process: self.snapshot(), configFingerprint: "changed"),
            .replace)
    }

    func testResolveReplacesWhenControllerChanged() {
        XCTAssertEqual(
            self.resolve(self.record(), process: self.snapshot(), controller: "127.0.0.1:9091"),
            .replace)
    }

    func testStoreRoundTripAndClear() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directories = WorkingDirectoryManager(homeDirectory: home)
        try directories.bootstrapDirectories()

        let store = CoreRuntimeStateStore(workingDirectoryManager: directories)
        XCTAssertNil(store.load())

        let record = self.record()
        try store.save(record)
        XCTAssertEqual(store.load(), record)

        store.clear()
        XCTAssertNil(store.load())
    }

    func testFingerprintChangesWithConfigContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.yaml")

        try "mixed-port: 7890\n".write(to: file, atomically: true, encoding: .utf8)
        let first = try CoreRuntimeState.fingerprint(ofContentsAt: file.path)

        try "mixed-port: 7891\n".write(to: file, atomically: true, encoding: .utf8)
        let second = try CoreRuntimeState.fingerprint(ofContentsAt: file.path)

        XCTAssertNotEqual(first, second)
    }

    private func resolve(
        _ record: CoreRuntimeState,
        process: CoreProcessSnapshot?,
        configFingerprint: String = "hash",
        controller: String = "127.0.0.1:9090")
        -> CoreRuntimeStateResolution
    {
        CoreRuntimeStateEvaluator.resolve(
            recorded: record,
            bootIdentifier: self.bootIdentifier,
            process: process,
            expectedController: controller,
            configFingerprint: configFingerprint)
    }

    private func record() -> CoreRuntimeState {
        CoreRuntimeState(
            schemaVersion: CoreRuntimeState.currentSchemaVersion,
            bootIdentifier: self.bootIdentifier,
            pid: 4242,
            processStartTime: 123,
            binaryPath: self.binaryPath,
            configPath: self.configPath,
            configFingerprint: "hash",
            controller: "127.0.0.1:9090")
    }

    private func copying(_ record: CoreRuntimeState, bootIdentifier: String) -> CoreRuntimeState {
        CoreRuntimeState(
            schemaVersion: record.schemaVersion,
            bootIdentifier: bootIdentifier,
            pid: record.pid,
            processStartTime: record.processStartTime,
            binaryPath: record.binaryPath,
            configPath: record.configPath,
            configFingerprint: record.configFingerprint,
            controller: record.controller)
    }

    private func snapshot(
        startTime: UInt64 = 123,
        executablePath: String? = "/tmp/clashbar/core/mihomo")
        -> CoreProcessSnapshot
    {
        CoreProcessSnapshot(
            pid: 4242,
            startTime: startTime,
            executablePath: executablePath ?? self.binaryPath,
            uid: 501)
    }
}
