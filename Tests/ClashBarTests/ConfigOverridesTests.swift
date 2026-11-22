import AppKit
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

    func testModeIsPersistableOnExplicitSaveButNotOnRuntimeSwitch() {
        XCTAssertTrue(ConfigOverrideField.isPersistableOnRuntimeChange("mixed-port"))
        XCTAssertFalse(ConfigOverrideField.isPersistableOnRuntimeChange("mode"))
    }

    func testEveryFieldSitsInAtMostOneSection() {
        let sections = ConfigOverrideGroup.allCases.flatMap { group in
            ConfigOverrideField.allCases.filter { $0.group == group }
        }
        XCTAssertEqual(sections.count, Set(sections).count, "a field must not appear in two sections")

        // `mode` is switched from the top bar, so it stays in the model without a row.
        let ungrouped = ConfigOverrideField.allCases.filter { $0.group == nil }
        XCTAssertEqual(ungrouped, [.mode], "only mode has no core-settings row")
        XCTAssertEqual(Set(sections).union(ungrouped), Set(ConfigOverrideField.allCases))
    }

    /// Mirrors the config file: general switches, the standalone `tun:` block, ports.
    func testSectionsFollowTheConfigFileOrder() {
        XCTAssertEqual(ConfigOverrideGroup.allCases, [.general, .tun, .ports])
        XCTAssertEqual(
            ConfigOverrideField.allCases.filter { $0.group == .general },
            [.allowLan, .ipv6, .tcpConcurrent, .logLevel])
        XCTAssertEqual(ConfigOverrideField.allCases.filter { $0.group == .tun }, [.tunEnable, .tunStack])
        XCTAssertEqual(
            ConfigOverrideField.allCases.filter { $0.group == .ports },
            [.port, .socksPort, .mixedPort])
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

    func testRuntimeChangeFiltersTransientKeysWhileExplicitSaveKeepsThem() {
        let values: [String: ConfigPatchValue] = ["mode": .string("global"), "mixed-port": .int(7891)]

        let runtime = ConfigOverrides.filteredForOrigin(values, origin: .runtimeAction)
        XCTAssertEqual(runtime, ["mixed-port": .int(7891)])

        let explicit = ConfigOverrides.filteredForOrigin(values, origin: .explicitSave)
        XCTAssertEqual(explicit, values)
    }

    func testMigrationPrunesLegacyModesAndPreservesModesSavedAfterMigration() throws {
        struct LegacyOverrides: Encodable {
            let identities: [String: UUID]
            let fileIDs: [String: String]
            let values: [UUID: [String: ConfigPatchValue]]
        }

        let first = UUID()
        let second = UUID()
        let legacy = LegacyOverrides(
            identities: ["/a.yaml": first, "/b.yaml": second],
            fileIDs: ["/a.yaml": "file-a"],
            values: [first: ["mode": .string("global"), "mixed-port": .int(7891)], second: ["mode": .string("direct")]])
        var migrated = try JSONDecoder().decode(ConfigOverrides.self, from: JSONEncoder().encode(legacy))
        XCTAssertTrue(migrated.migrateLegacyModeOverrides())
        XCTAssertEqual(migrated.identities, legacy.identities)
        XCTAssertEqual(migrated.fileIDs, legacy.fileIDs)
        XCTAssertEqual(migrated.values, [first: ["mixed-port": .int(7891)]])

        migrated.values[first]?["mode"] = .string("direct")
        var reopened = try JSONDecoder().decode(ConfigOverrides.self, from: JSONEncoder().encode(migrated))
        XCTAssertFalse(reopened.migrateLegacyModeOverrides())
        XCTAssertEqual(reopened.values[first]?["mode"], .string("direct"))
    }

    /// `redir-port` and `tproxy-port` lost their rows, so a stored override for them
    /// could never be seen or undone; it must not keep counting towards the badge.
    func testMigrationPrunesOverridesForRemovedPorts() throws {
        let id = UUID()
        var store = ConfigOverrides()
        store.identities["/a.yaml"] = id
        store.values[id] = [
            "redir-port": .int(7893),
            "tproxy-port": .int(7894),
            "mixed-port": .int(7890),
        ]
        var reopened = try JSONDecoder().decode(ConfigOverrides.self, from: JSONEncoder().encode(store))

        XCTAssertTrue(reopened.pruneRemovedFieldOverrides())
        XCTAssertEqual(reopened.values[id], ["mixed-port": .int(7890)])

        // Idempotent: a second run must not report another change.
        XCTAssertFalse(reopened.pruneRemovedFieldOverrides())

        // An entry that only held removed keys is dropped entirely.
        var portOnly = ConfigOverrides()
        portOnly.identities["/b.yaml"] = id
        portOnly.values[id] = ["redir-port": .int(7893)]
        var reopenedPortOnly = try JSONDecoder().decode(
            ConfigOverrides.self, from: JSONEncoder().encode(portOnly))
        XCTAssertTrue(reopenedPortOnly.pruneRemovedFieldOverrides())
        XCTAssertNil(reopenedPortOnly.values[id])
    }

    @MainActor
    func testProxyExceptionSaveWaitsForMutationAndCapturesOnlySubmittedText() async throws {
        let model = self.makeIsolatedModel()
        model.settingsSyncingKey = "busy"
        model.replaceSystemProxyExceptionsDraft(with: ["queued.example"])
        model.saveSystemProxyExceptions()
        let save = try XCTUnwrap(model.systemProxyExceptionsSaveTask)
        XCTAssertEqual(model.pendingSystemProxyExceptionsSave, ["queued.example"])

        model.replaceSystemProxyExceptionsDraft(with: ["still-editing.example"])
        await Task.yield()
        XCTAssertEqual(model.pendingSystemProxyExceptionsSave, ["queued.example"])
        // Keep this queue test independent of the macOS proxy Helper.
        model.lastSavedSystemProxyExceptions = ["queued.example"]
        model.settingsSyncingKey = nil
        await save.value

        XCTAssertNil(model.pendingSystemProxyExceptionsSave)
        XCTAssertNil(model.systemProxyExceptionsSaveTask)
        XCTAssertEqual(model.currentSystemProxyExceptionValues(), ["still-editing.example"])
    }

    @MainActor
    func testCoreSettingsDraftSurvivesPanelCloseAndDiscardKeepsLiveValues() {
        let model = self.makeIsolatedModel()
        model.setPanelVisibility(true)
        model.stageCoreSetting(.mixedPort, value: .string("7891"))
        model.setPanelVisibility(false)

        XCTAssertEqual(model.pendingCoreSettingsCount, 1)
        XCTAssertEqual(model.settingsMixedPort, "7890")

        model.stageCoreSetting(.mixedPort, value: .string(" 07890 "))
        XCTAssertEqual(model.pendingCoreSettingsCount, 0)
        XCTAssertEqual(model.coreSettingValue(.mixedPort), .string("7890"))

        model.stageCoreSetting(.mode, value: .string("global"))
        XCTAssertEqual(model.pendingCoreSettingsCount, 0, "an unconstrained field must not wait for Apply")
        XCTAssertEqual(model.coreSettingValue(.mode), .string("global"))
        model.discardCoreSettings()
        XCTAssertEqual(model.pendingCoreSettingsCount, 0)
    }

    @MainActor
    func testOnlyConstrainedGroupsWaitForExplicitApply() {
        XCTAssertEqual(ConfigSubmitGroup.ports.applyMode, .unifiedCommit)
        XCTAssertEqual(ConfigSubmitGroup.tun.applyMode, .unifiedCommit)
        for group in ConfigSubmitGroup.ordered where group != .ports && group != .tun {
            XCTAssertEqual(group.applyMode, .immediate, "\(group) must hot-apply on change")
        }
    }

    @MainActor
    func testFailedImmediateCommitSurfacesOnCorePageAndKeepsTheDraft() async throws {
        let model = self.makeIsolatedModel()
        model.stageCoreSetting(.logLevel, value: .string("debug"))
        XCTAssertTrue(model.isCommittingCoreSettingImmediately, "the queue must publish while it runs")

        // No running core, so the patch cannot land: the failure must reach the
        // field the core page renders and must not leak into the App section.
        await model.awaitPendingCoreSettingCommits()

        XCTAssertFalse(model.isCommittingCoreSettingImmediately)
        let error = try XCTUnwrap(model.coreSettingsError)
        XCTAssertFalse(error.isEmpty)
        XCTAssertNil(model.settingsErrorMessage)
        XCTAssertEqual(model.coreSettingsEdits[.logLevel], .string("debug"), "the draft must stay retryable")
    }

    @MainActor
    func testUndoingTheLastRestoreCommitsStrandedUnconstrainedDrafts() async {
        let model = self.makeIsolatedModel()
        model.coreSettingsRestores = ["log-level"]
        model.coreSettingsEdits[.ipv6] = .bool(true)
        model.coreSettingsEdits[.mixedPort] = .string("7891")

        model.undoCoreSettingRestore(.logLevel)

        XCTAssertTrue(model.coreSettingsRestores.isEmpty)
        XCTAssertTrue(model.isCommittingCoreSettingImmediately, "the stranded draft must be requeued")
        XCTAssertEqual(model.coreSettingsImmediateEdits[.ipv6], .bool(true))
        XCTAssertNil(model.coreSettingsImmediateEdits[.mixedPort], "constrained drafts still wait for Apply")
        await model.awaitPendingCoreSettingCommits()
        XCTAssertFalse(model.isCommittingCoreSettingImmediately)
    }

    @MainActor
    func testPendingCountMatchesWhatApplySubmitsInBothModes() {
        let model = self.makeIsolatedModel()
        model.coreSettingsEdits[.ipv6] = .bool(true)
        XCTAssertEqual(model.pendingCoreSettingsCount, 0, "an unconstrained draft never waits for Apply alone")

        model.coreSettingsEdits[.mixedPort] = .string("7891")
        XCTAssertEqual(model.pendingCoreSettingsCount, 1)

        model.coreSettingsRestores = ["log-level"]
        XCTAssertEqual(model.pendingCoreSettingsCount, 3, "a staged restore makes Apply send every draft")
    }

    func testSubmitGroupsBindConstrainedFieldsAndIsolateTheRest() {
        XCTAssertEqual(ConfigSubmitGroup.ordered, [
            .field(.allowLan), .field(.ipv6), .field(.tcpConcurrent),
            .ports, .tun, .field(.logLevel), .field(.mode),
        ])
        XCTAssertEqual(ConfigSubmitGroup.ports.fields, [.port, .socksPort, .mixedPort])
        XCTAssertEqual(ConfigSubmitGroup.tun.fields, [.tunEnable, .tunStack])
        XCTAssertEqual(ConfigSubmitGroup.field(.logLevel).fields, [.logLevel])

        let groups = ConfigSubmitGroup.ordered.flatMap(\.fields)
        XCTAssertEqual(Set(groups), Set(ConfigOverrideField.allCases), "every field must belong to a submit group")
        XCTAssertEqual(groups.count, Set(groups).count, "a field must not sit in two submit groups")
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

    @MainActor
    func testFailureBannerDoesNotClaimOthersAppliedWhenNoneDid() {
        let model = self.makeIsolatedModel()
        let failures: [ConfigSubmitGroup: String] = [.ports: "port reason", .tun: "tun reason"]

        let noneApplied = model.coreSettingsFailure(failures, appliedGroups: 0)
        guard case let .grouped(key, details) = noneApplied else {
            return XCTFail("Two failing groups must use a grouped banner, got \(noneApplied)")
        }
        XCTAssertEqual(key, "ui.settings.core.all_failed")
        XCTAssertTrue(details.contains("port reason"), details)
        XCTAssertTrue(details.contains("tun reason"), details)

        let someApplied = model.coreSettingsFailure(failures, appliedGroups: 1)
        guard case let .grouped(partialKey, _) = someApplied else {
            return XCTFail("Two failing groups must use a grouped banner, got \(someApplied)")
        }
        XCTAssertEqual(partialKey, "ui.settings.core.partial_failed")

        XCTAssertEqual(model.coreSettingsFailure([.tun: "tun reason"], appliedGroups: 0), .reason("tun reason"))
        XCTAssertEqual(model.coreSettingsFailure([.ports: "port reason"], appliedGroups: 2), .reason("port reason"))
    }

    /// Two settings with different meanings must not share a glyph; `allowLan` and the
    /// HTTP port used to both render `network`. Distinctness alone would still pass with
    /// an invalid symbol name, so each one is also resolved against the system set.
    func testEveryFieldHasADistinctAndValidSymbol() {
        let symbols = ConfigOverrideField.allCases.map(\.symbol)
        XCTAssertEqual(symbols.count, Set(symbols).count, "each field needs a distinct symbol")

        for symbol in symbols {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "\(symbol) is not a valid SF Symbol")
        }
    }

    func testOverrideFieldKeysExistInBothLocalizations() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let keys = ConfigOverrideField.allCases.flatMap {
            [$0.titleKey, "ui.state.on", "ui.state.off"]
        } + ConfigOverrideGroup.allCases.map(\.titleKey) + [
            "ui.settings.overrides.status.overridden_short",
            "ui.settings.overrides.status.unconfirmed_short",
            "ui.settings.overrides.status.following_short",
            "ui.settings.overrides.status.chip_named",
            "ui.settings.overrides.status.chip_named_with_declared",
            "ui.settings.overrides.item.restore_help_with_declared",
            "ui.settings.overrides.restore_all",
            "ui.settings.core.apply_count",
            "ui.settings.core.discard",
            "ui.settings.core.applied",
            "ui.settings.core.restore_all_help",
            "ui.settings.core.restore_pending",
            "ui.settings.core.edit_pending",
            "ui.settings.core.undo_restore",
            "ui.settings.core.select_stack",
            "ui.settings.core.invalid_port",
            "ui.settings.core.partial_failed",
            "ui.settings.core.all_failed",
            "ui.settings.core.system_proxy_requires_port",
            "app.settings.error.busy",
            "ui.settings.exceptions.retry",
            "ui.settings.overrides.item.restore_help",
            "ui.settings.section.app",
            "ui.settings.section.core",
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
