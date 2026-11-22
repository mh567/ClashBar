import XCTest
@testable import ClashBar

/// Guards the TUN state across core restarts.
///
/// Regression: restarting the core turned the TUN switch off and it never came
/// back, because the core reports `tun.enable: false` while it boots and the
/// settings sync trusted that value over the pending recovery.
@MainActor
final class TunRecoveryTests: XCTestCase {
    private func makeModel() -> AppViewModel {
        let suite = "clashbar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return AppViewModel(dependencies: .live, defaults: defaults)
    }

    private func snapshot(tunEnabled: Bool) -> EditableSettingsSnapshot {
        EditableSettingsSnapshot(
            mode: .rule,
            allowLan: false,
            ipv6: false,
            tcpConcurrent: false,
            tunEnabled: tunEnabled,
            logLevel: ConfigLogLevel.info.rawValue,
            port: "0",
            socksPort: "0",
            mixedPort: "7890")
    }

    private func config(tunEnabled: Bool) throws -> ConfigSnapshot {
        let json = #"{"tun":{"enable":\#(tunEnabled)},"mixed-port":7890,"mode":"rule","log-level":"info"}"#
        return try JSONDecoder().decode(ConfigSnapshot.self, from: Data(json.utf8))
    }

    /// The two Linux-only ports were dropped from the snapshot. Persisted data written
    /// by an older build still carries them, so decoding must ignore the extra keys
    /// instead of failing and losing the user's saved settings.
    func testSnapshotDecodesDataWrittenBeforeTheLinuxPortsWereRemoved() throws {
        let legacy = """
            {"mode":"rule","allowLan":false,"ipv6":true,"tcpConcurrent":true,"tunEnabled":true,
             "logLevel":"info","port":"7891","socksPort":"7892","mixedPort":"7890",
             "redirPort":"7893","tproxyPort":"7894"}
            """
        let snapshot = try JSONDecoder().decode(
            EditableSettingsSnapshot.self, from: Data(legacy.utf8))

        XCTAssertEqual(snapshot.mixedPort, "7890")
        XCTAssertEqual(snapshot.port, "7891")
        XCTAssertEqual(snapshot.socksPort, "7892")
        XCTAssertTrue(snapshot.ipv6)
        XCTAssertTrue(snapshot.tunEnabled)
    }

    func testWithTunEnabledKeepsEveryOtherField() {
        let original = self.snapshot(tunEnabled: false)
        let updated = original.withTunEnabled(true)

        XCTAssertTrue(updated.tunEnabled)
        XCTAssertEqual(updated.mode, original.mode)
        XCTAssertEqual(updated.allowLan, original.allowLan)
        XCTAssertEqual(updated.ipv6, original.ipv6)
        XCTAssertEqual(updated.tcpConcurrent, original.tcpConcurrent)
        XCTAssertEqual(updated.logLevel, original.logLevel)
        XCTAssertEqual(updated.port, original.port)
        XCTAssertEqual(updated.socksPort, original.socksPort)
        XCTAssertEqual(updated.mixedPort, original.mixedPort)
    }

    func testPendingTunRecoverySurvivesBootSnapshotWithTunOff() throws {
        let model = self.makeModel()
        model.isTunEnabled = true
        model.lastSyncedEditableSettings = self.snapshot(tunEnabled: true)
        model.pendingCoreFeatureRecoveryState = CoreFeatureRecoveryState(
            systemProxyEnabled: false,
            tunEnabled: true)

        // The core comes up with its YAML default before the override is applied.
        model.syncEditableSettings(from: try self.config(tunEnabled: false))

        XCTAssertTrue(model.isTunEnabled, "a boot-time snapshot must not switch TUN off")
        XCTAssertEqual(model.lastSyncedEditableSettings?.tunEnabled, true)
    }

    func testTunFollowsTheCoreOnceNoRecoveryIsPending() throws {
        let model = self.makeModel()
        model.isTunEnabled = false
        model.lastSyncedEditableSettings = self.snapshot(tunEnabled: false)
        model.pendingCoreFeatureRecoveryState = nil

        model.syncEditableSettings(from: try self.config(tunEnabled: true))

        XCTAssertTrue(model.isTunEnabled, "without a pending recovery the core value wins")
    }

    func testFirstSnapshotKeepsPendingTunRecovery() throws {
        let model = self.makeModel()
        model.isTunEnabled = true
        model.pendingCoreFeatureRecoveryState = CoreFeatureRecoveryState(
            systemProxyEnabled: false, tunEnabled: true)

        model.syncEditableSettings(from: try self.config(tunEnabled: false))

        XCTAssertTrue(model.isTunEnabled)
        XCTAssertEqual(model.lastSyncedEditableSettings?.tunEnabled, true)
    }
}
