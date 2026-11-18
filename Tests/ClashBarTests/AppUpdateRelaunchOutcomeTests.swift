import XCTest
@testable import ClashBar

final class AppUpdateRelaunchOutcomeTests: XCTestCase {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clashbar-relaunch-\(UUID().uuidString).json", isDirectory: false)
    }

    private func write(_ json: String, to url: URL) throws {
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    func testReadsOutcomeWrittenByRelaunchHelper() throws {
        let url = self.makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try self.write(
            #"{"result":"rolledBack","installedVersion":"1.2.3","previousVersion":"1.2.2","date":1700000000}"#,
            to: url)

        let outcome = AppUpdateInstaller.readRelaunchOutcome(at: url)
        XCTAssertEqual(outcome?.result, .rolledBack)
        XCTAssertEqual(outcome?.installedVersion, "1.2.3")
        XCTAssertEqual(outcome?.previousVersion, "1.2.2")
        XCTAssertEqual(outcome?.date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testConsumeRemovesOutcomeFile() throws {
        let url = self.makeURL()
        try self.write(
            #"{"result":"succeeded","installedVersion":"1.2.3","previousVersion":"1.2.2","date":1700000000}"#,
            to: url)

        XCTAssertEqual(AppUpdateInstaller.consumeRelaunchOutcome(at: url)?.result, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(AppUpdateInstaller.consumeRelaunchOutcome(at: url))
    }

    func testIgnoresMissingOrMalformedOutcome() throws {
        let missing = self.makeURL()
        XCTAssertNil(AppUpdateInstaller.readRelaunchOutcome(at: missing))

        let malformed = self.makeURL()
        defer { try? FileManager.default.removeItem(at: malformed) }
        try self.write("not json", to: malformed)
        XCTAssertNil(AppUpdateInstaller.readRelaunchOutcome(at: malformed))
    }

    func testOutcomeURLUsesStateDirectory() {
        XCTAssertEqual(
            AppUpdateInstaller.relaunchOutcomeURL().lastPathComponent,
            "app-update-relaunch.json")
    }

    /// Runs the real relaunch helper against a bundle that cannot be opened and
    /// checks that it records the failure and restores the previous bundle.
    func testRelaunchScriptRecordsFailureAndRollsBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clashbar-relaunch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = root.appendingPathComponent("ClashBar.app", isDirectory: true)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        let previous = stage.appendingPathComponent("ClashBar.app", isDirectory: true)
        let status = root.appendingPathComponent("state/status.json", isDirectory: false)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try "new".write(to: installed.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try "old".write(to: previous.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", AppUpdateInstaller.relaunchScript, "clashbar-relaunch",
            installed.path, stage.path, previous.path,
            "1.2.3", "1.2.2", status.path,
            "999999",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let outcome = AppUpdateInstaller.readRelaunchOutcome(at: status)
        XCTAssertEqual(outcome?.result, .openFailed)
        XCTAssertEqual(outcome?.installedVersion, "1.2.3")
        XCTAssertEqual(outcome?.previousVersion, "1.2.2")
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("marker.txt"), encoding: .utf8),
            "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path + ".failed-update"))
    }
}
