import XCTest
@testable import ClashBar

final class MihomoCoreVersionTests: XCTestCase {
    func testExtractsMetaVersionFromCommandOutput() {
        let output = "Mihomo Meta v1.19.34 darwin arm64 with go1.22.12 Wed Nov 11 06:56:23 UTC 2026\n"
        XCTAssertEqual(MihomoCoreVersion.extract(from: output)?.displayString, "1.19.34")
    }

    func testExtractsVersionWithoutVPrefixWhenNeeded() {
        XCTAssertEqual(MihomoCoreVersion.extract(from: "mihomo 1.19.34")?.displayString, "1.19.34")
        XCTAssertNil(MihomoCoreVersion.extract(from: "no version here"))
    }

    func testReadsVersionFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihomo-version-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try "v1.19.36\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(MihomoCoreVersion.readVersionFile(at: url)?.displayString, "1.19.36")
    }

    func testProbesExecutableVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihomo-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binary = directory.appendingPathComponent("mihomo")
        try "#!/bin/sh\necho 'Mihomo Meta v9.9.9 darwin arm64'\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        XCTAssertEqual(MihomoCoreVersion.probe(at: binary.path)?.displayString, "9.9.9")
        XCTAssertNil(MihomoCoreVersion.probe(at: directory.appendingPathComponent("missing").path))
    }

    /// A managed core the user upgraded locally must win over an older payload
    /// shipped inside a newer app build.
    func testKeepsNewerManagedCore() {
        XCTAssertFalse(MihomoCoreVersion.shouldPreferBundled(
            managed: AppSemanticVersion("v1.19.36"),
            bundled: AppSemanticVersion("v1.19.34")))
        XCTAssertFalse(MihomoCoreVersion.shouldPreferBundled(
            managed: AppSemanticVersion("v1.19.34"),
            bundled: AppSemanticVersion("v1.19.34")))
    }

    func testInstallsNewerBundledPayload() {
        XCTAssertTrue(MihomoCoreVersion.shouldPreferBundled(
            managed: AppSemanticVersion("v1.19.34"),
            bundled: AppSemanticVersion("v1.19.36")))
        XCTAssertTrue(MihomoCoreVersion.shouldPreferBundled(managed: nil, bundled: AppSemanticVersion("v1.19.34")))
        XCTAssertFalse(MihomoCoreVersion.shouldPreferBundled(
            managed: AppSemanticVersion("v1.19.34"),
            bundled: nil))
    }

    func testUnknownManagedVersionIsReplaced() {
        XCTAssertTrue(MihomoCoreVersion.shouldPreferBundled(
            managed: nil,
            bundled: AppSemanticVersion("v1.19.34")))
    }
}
