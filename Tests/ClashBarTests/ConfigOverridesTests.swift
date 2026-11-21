import XCTest
@testable import ClashBar

final class ConfigOverridesTests: XCTestCase {
    func testIdentityAndSparseValuesSurviveRenameAndRoundTrip() throws {
        var store = ConfigOverrides()
        let id = store.id(for: "a.yaml")
        store.values[id] = ["mixed-port": .int(0), "tun.enable": .bool(false)]
        store.move(from: "a.yaml", to: "renamed.yaml")
        let restored = try JSONDecoder().decode(ConfigOverrides.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(restored.identities["renamed.yaml"], id)
        XCTAssertEqual(restored.values[id], ["mixed-port": .int(0), "tun.enable": .bool(false)])
        XCTAssertNil(restored.identities["b.yaml"])
        store.remove("renamed.yaml")
        XCTAssertNotEqual(store.id(for: "renamed.yaml"), id)
        XCTAssertTrue(store.values.isEmpty)
    }

    func testFileRenameMovesIdentityAndExternalDeletionForgetsIt() {
        var store = ConfigOverrides()
        let id = store.id(for: "/config/a.yaml")
        _ = store.reconcileFiles(["/config/a.yaml": "device:100"], in: "/config")
        XCTAssertEqual(store.reconcileFiles(["/config/renamed.yaml": "device:100"], in: "/config"), [
            "/config/a.yaml": "/config/renamed.yaml",
        ])
        XCTAssertEqual(store.identities["/config/renamed.yaml"], id)
        _ = store.reconcileFiles([:], in: "/config")
        XCTAssertNotEqual(store.id(for: "/config/renamed.yaml"), id)
    }

    func testStackOnlyPatchUsesObservedEnableWithoutPersistingIt() {
        let fields: [String: ConfigPatchValue] = ["tun.stack": .string("mips"), "log-level": .string("debug")]
        XCTAssertEqual(ConfigOverrides.request(for: fields, tunEnabled: false), [
            "tun": .object(["stack": .string("mips"), "enable": .bool(false)]),
            "log-level": .string("debug"),
        ])
        XCTAssertNil(fields["tun.enable"])
        XCTAssertTrue(ConfigOverrides.request(for: [:], tunEnabled: nil).isEmpty)
    }
}
