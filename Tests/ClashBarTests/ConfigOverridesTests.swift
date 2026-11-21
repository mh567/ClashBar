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

    func testOverrideFieldCoversEverySettableKey() throws {
        let snapshot = try JSONDecoder().decode(ConfigSnapshot.self, from: Data("{}".utf8))
        let keys = Set(ConfigOverrideField.allCases.map(\.rawValue))
        let written = Set(snapshot.overrideFields.keys).subtracting(["bind-address"])
        XCTAssertEqual(written.subtracting(keys), [])
        XCTAssertEqual(keys.count, ConfigOverrideField.allCases.count)
    }

    func testOverrideFieldRendersValuesWithoutLocalizationBundle() {
        XCTAssertEqual(ConfigOverrideField.mixedPort.valueText(.int(0), language: .en), "0")
        XCTAssertEqual(ConfigOverrideField.tunStack.valueText(.string("mips"), language: .en), "mips")
        XCTAssertNil(ConfigOverrideField.logLevel.valueText(.string("  "), language: .en))
        XCTAssertNil(ConfigOverrideField.logLevel.valueText(nil, language: .en))
        XCTAssertNil(ConfigOverrideField.tunEnable.valueText(.object([:]), language: .en))
    }

    func testModeIsNeverPersistedAsAnOverride() {
        XCTAssertFalse(ConfigOverrideField.isPersistableKey("mode"))
        XCTAssertTrue(ConfigOverrideField.allCases.allSatisfy { ConfigOverrideField.isPersistableKey($0.rawValue) })
        XCTAssertTrue(ConfigOverrideField.isPersistableKey("mixed-port"))
    }

    func testModeIsDroppedButOtherFieldsSurviveRecordFiltering() {
        XCTAssertEqual(
            ConfigOverrides.persistableFields(from: ["mode": .string("global")]),
            [:])
        XCTAssertEqual(
            ConfigOverrides.persistableFields(from: [
                "mode": .string("global"),
                "mixed-port": .int(7891),
                "tun.enable": .bool(false),
            ]),
            ["mixed-port": .int(7891), "tun.enable": .bool(false)])
    }

    func testEveryFieldHasAtMostOneGroupAndGroupsPartitionTheRest() {
        let grouped = ConfigOverrideGroup.allCases.flatMap { group in
            ConfigOverrideField.allCases.filter { $0.group == group }
        }
        XCTAssertEqual(grouped.count, Set(grouped).count, "a field must not sit in two groups")

        let ungrouped = ConfigOverrideField.allCases.filter { $0.group == nil }
        XCTAssertEqual(Set(grouped).union(ungrouped), Set(ConfigOverrideField.allCases))
        XCTAssertEqual(ungrouped, [.logLevel], "log level is shown on its own, above the groups")
    }


    func testRouteExcludeSurvivesYAMLAnchorMerge() throws {
        let yaml = """
        defaults: &tun-defaults
          enable: false
          route-exclude-address:
            - 10.0.0.0/8
            - 192.168.0.0/16
        tun:
          <<: *tun-defaults
          stack: mixed
        """
        let parsed = try ConfigReloadAction.parse(yaml)
        XCTAssertEqual(parsed.tunRouteExcludeAddress, ["10.0.0.0/8", "192.168.0.0/16"])
    }

    func testTunRouteExcludeAddressIsReadFromYAML() throws {
        let yaml = """
        tun:
          enable: true
          route-exclude-address:
            - 10.0.0.0/8
            - 192.168.0.0/16
        """
        XCTAssertEqual(
            try ConfigReloadAction.parse(yaml).tunRouteExcludeAddress,
            ["10.0.0.0/8", "192.168.0.0/16"])
        XCTAssertNil(try ConfigReloadAction.parse("tun: {enable: true}").tunRouteExcludeAddress)
        XCTAssertThrowsError(try ConfigReloadAction.parse("not: [valid"))
    }

    func testConfigSnapshotDecodesTunRouteExcludeAddress() throws {
        let json = #"{"tun":{"enable":true,"stack":"mixed","route-exclude-address":["10.0.0.0/8"]}}"#
        let snapshot = try JSONDecoder().decode(ConfigSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.tun?.routeExcludeAddress, ["10.0.0.0/8"])

        let withoutField = try JSONDecoder().decode(
            ConfigSnapshot.self, from: Data(#"{"tun":{"enable":false}}"#.utf8))
        XCTAssertNil(withoutField.tun?.routeExcludeAddress)
    }

    func testParseProvidesFieldsAndRouteExcludeInOnePass() throws {
        let yaml = """
        mixed-port: 7891
        tun:
          enable: true
          stack: gvisor
          route-exclude-address:
            - 10.0.0.0/8
        """
        let parsed = try ConfigReloadAction.parse(yaml)
        XCTAssertEqual(parsed.fields["mixed-port"], .int(7891))
        XCTAssertEqual(parsed.fields["tun.enable"], .bool(true))
        XCTAssertEqual(parsed.fields["tun.stack"], .string("gvisor"))
        XCTAssertEqual(parsed.tunRouteExcludeAddress, ["10.0.0.0/8"])
    }

    @MainActor
    private func makeIsolatedModel() -> AppViewModel {
        let suite = "clashbar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return AppViewModel(dependencies: .live, defaults: defaults)
    }

    @MainActor
    func testLegacyModeOverrideIsPrunedOnLoad() {
        let model = self.makeIsolatedModel()
        let id = UUID()
        model.configOverrides.identities["/config/a.yaml"] = id
        model.configOverrides.values[id] = ["mode": .string("global"), "mixed-port": .int(7891)]

        model.pruneNonPersistableConfigOverrides()

        XCTAssertNil(model.configOverrides.values[id]?["mode"])
        XCTAssertEqual(model.configOverrides.values[id]?["mixed-port"], .int(7891))
    }

    @MainActor
    func testPruneDropsRecordThatOnlyHeldMode() {
        let model = self.makeIsolatedModel()
        let id = UUID()
        model.configOverrides.identities["/config/a.yaml"] = id
        model.configOverrides.values[id] = ["mode": .string("direct")]

        model.pruneNonPersistableConfigOverrides()

        XCTAssertNil(model.configOverrides.values[id])
    }

    @MainActor
    func testCoreSettingsDraftSurvivesPanelCloseAndDiscardKeepsLiveValues() {
        let model = self.makeIsolatedModel()
        model.setPanelVisibility(true)
        model.stageCoreSetting(.allowLan, value: .bool(true))
        model.stageCoreSetting(.mixedPort, value: .string("7891"))
        model.setPanelVisibility(false)

        XCTAssertEqual(model.pendingCoreSettingsCount, 2)
        XCTAssertEqual(model.coreSettingValue(.allowLan), .bool(true))
        XCTAssertFalse(model.settingsAllowLan)
        XCTAssertEqual(model.settingsMixedPort, "7890")
        XCTAssertTrue(model.configOverrides.values.isEmpty)

        model.stageCoreSetting(.allowLan, value: .bool(false))
        XCTAssertEqual(model.pendingCoreSettingsCount, 1)
        model.discardCoreSettings()
        XCTAssertEqual(model.pendingCoreSettingsCount, 0)
        XCTAssertEqual(model.coreSettingValue(.mixedPort), .string("7890"))
    }

    @MainActor
    func testRestoreAllIsANoOpWithoutLoadedConfig() async {
        let model = self.makeIsolatedModel()
        let id = UUID()
        model.configOverrides.identities["/config/a.yaml"] = id
        model.configOverrides.values[id] = ["mixed-port": .int(7891)]

        model.stageCoreSettingsRestore(["mixed-port"])
        XCTAssertEqual(model.pendingCoreSettingsCount, 0)
        await model.applyCoreSettings()

        XCTAssertEqual(model.configOverrides.values[id], ["mixed-port": .int(7891)])
    }

    func testOverrideFieldKeysExistInBothLocalizations() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let keys = ConfigOverrideField.allCases.flatMap {
            [$0.titleKey, "ui.state.on", "ui.state.off"]
        } + ConfigOverrideGroup.allCases.map(\.titleKey) + [
            "ui.settings.overrides.hint",
            "ui.settings.overrides.status.overridden_short",
            "ui.settings.overrides.status.unconfirmed_short",
            "ui.settings.overrides.status.following_short",
            "ui.settings.overrides.status.chip_named",
            "ui.settings.overrides.item.restore_help_with_declared",
            "ui.settings.overrides.restore_all",
            "ui.settings.core.apply",
            "ui.settings.core.discard",
            "ui.settings.core.pending",
            "ui.settings.core.applying",
            "ui.settings.core.applied",
            "ui.settings.core.reload_hint",
            "ui.settings.core.restore_all_help",
            "ui.settings.core.restore_pending",
            "ui.settings.core.edit_pending",
            "ui.settings.core.undo_restore",
            "ui.settings.core.select_stack",
            "ui.settings.core.invalid_port",
            "ui.settings.exceptions.retry",
            "ui.settings.overrides.item.restore_help",
            "ui.settings.section.app",
            "ui.settings.section.core",
            "ui.settings.core_remote_hint",
            "ui.settings.core_mode.hint",
            "ui.settings.route_exclude.title",
            "ui.settings.route_exclude.source.yaml",
            "ui.settings.route_exclude.source.core",
            "ui.settings.route_exclude.empty",
            "ui.settings.route_exclude.hint",
            "ui.settings.system_proxy_exceptions.inactive",
            "ui.settings.system_proxy_exceptions_hint",
            "ui.settings.system_proxy_exceptions_empty",
            "ui.section.system_proxy_exceptions",
            "ui.mode.rule",
            "ui.mode.global",
            "ui.mode.direct",
            "ui.common.unknown",
            "ui.action.cancel",
        ]

        for language in ["zh-Hans", "en"] {
            let path = repoRoot.appendingPathComponent(
                "Sources/ClashBar/Resources/Localization/\(language).lproj/Localizable.strings")
            let contents = try String(contentsOf: path, encoding: .utf8)
            for key in keys {
                XCTAssertTrue(contents.contains("\"\(key)\" ="), "\(language) is missing \(key)")
            }
        }
    }
}
