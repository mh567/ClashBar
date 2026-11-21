import XCTest
@testable import ClashBar

final class ConfigApplicationTests: XCTestCase {
    func testChangesChooseRequiredReload() {
        let loaded = "mixed-port: 7890\nexternal-controller: 127.0.0.1:9090\nsecret: old"
        XCTAssertEqual(ConfigReloadAction.between(loaded, loaded + "\nrules: [MATCH,DIRECT]"), .reload)
        XCTAssertEqual(
            ConfigReloadAction.between(loaded, loaded.replacingOccurrences(of: "7890", with: "7891")),
            .listeners)
        XCTAssertEqual(
            ConfigReloadAction.between(loaded, loaded.replacingOccurrences(of: "mixed-port: 7890\n", with: "")),
            .listeners)
        XCTAssertEqual(
            ConfigReloadAction.between(loaded, loaded.replacingOccurrences(of: "old", with: "new")),
            .restart)
        XCTAssertEqual(ConfigReloadAction.between(nil, loaded), .restart)
    }

    func testListenerMismatchOnlyBlocksFieldsWithoutAnExplicitOverride() throws {
        let yaml = "mixed-port: 7891"
        XCTAssertEqual(try ConfigReloadAction.baselineListenerIssues(
            yaml: yaml, observed: ["mixed-port": .int(7890)], overrides: [:]), ["mixed-port"])
        XCTAssertTrue(try ConfigReloadAction.baselineListenerIssues(
            yaml: yaml, observed: ["mixed-port": .int(0)],
            overrides: ["mixed-port": .int(7890)]).isEmpty)
    }

    func testRemovedListenerReturnsToCoreDefault() throws {
        let fields = try ConfigReloadAction.fields(in: "tun: { enable: false }")
        XCTAssertEqual(fields["mixed-port"], .int(0))
        XCTAssertEqual(fields["tun.enable"], .bool(false))
        XCTAssertTrue(ConfigOverrides.matches(.string("mips"), .string("Mips")))
        XCTAssertFalse(ConfigOverrides.matches(.bool(false), nil))
    }
}
