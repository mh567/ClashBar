import XCTest
@testable import ClashBar

/// Update install failures used to surface as one opaque "install failed" with nothing in
/// the log, which made a blocked download indistinguishable from a rejected signature.
/// These cases lock the step and the underlying reason onto the error.
final class AppUpdateInstallerFailureTests: XCTestCase {
    func testDescribeKeepsTheStageAndTheReason() {
        let failure = AppUpdateInstaller.Failure.staged(.verifyBundle, underlying: "sha256 mismatch")
        XCTAssertEqual(AppUpdateInstaller.describe(failure), "sha256 mismatch")

        XCTAssertEqual(
            AppUpdateInstaller.describe(AppUpdateInstaller.Failure.staged(.replaceBundle, underlying: "busy")),
            "busy")
    }

    func testDescribeNamesTheCommandThatFailed() {
        XCTAssertEqual(
            AppUpdateInstaller.describe(AppUpdateInstaller.Failure.command("codesign")),
            "command failed: codesign")
        XCTAssertEqual(
            AppUpdateInstaller.describe(AppUpdateInstaller.Failure.command("hdiutil")),
            "command failed: hdiutil")
    }

    func testEveryStageHasADistinctName() {
        let stages: [AppUpdateInstaller.Stage] = [
            .download, .verifyChecksum, .verifyBundle, .stageImage, .replaceBundle, .scheduleRelaunch,
        ]
        XCTAssertEqual(stages.count, Set(stages.map(\.rawValue)).count)
        for stage in stages {
            XCTAssertFalse(stage.rawValue.isEmpty)
        }
    }
}
