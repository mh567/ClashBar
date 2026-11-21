import Darwin
import Foundation
import XCTest
@testable import ClashBar

final class ConfigApplicationIntegrationTests: XCTestCase {
    @MainActor
    func testSettingsCannotRemoveTheLastActiveSystemProxyPort() async throws {
        try await self.withRunningCore { model, selected, _, controller, nextPort, _ in
            let original = try await model.fetchRuntimeConfigSnapshot()
            model.isSystemProxyEnabled = true
            model.stageCoreSetting(.mixedPort, value: .string("0"))
            await model.applyCoreSettings()
            model.isSystemProxyEnabled = false
            XCTAssertNotNil(model.coreSettingsError)
            XCTAssertNil(model.settingsSavedMessage)
            XCTAssertEqual(model.pendingCoreSettingsCount, 1)
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)
            let unchanged = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(unchanged.mixedPort, original.mixedPort)

            model.discardCoreSettings()
            try Self.config(controller: controller, mixedPort: 0)
                .write(to: selected, atomically: true, encoding: .utf8)
            await model.reloadConfig()
            await model.patchSingleConfig("mixed-port", value: .int(nextPort))
            model.isSystemProxyEnabled = true
            model.stageCoreSettingsRestore(["mixed-port"])
            await model.applyCoreSettings()
            model.isSystemProxyEnabled = false
            XCTAssertNotNil(model.coreSettingsError)
            XCTAssertNil(model.settingsSavedMessage)
            XCTAssertEqual(model.pendingCoreSettingsCount, 1)
            XCTAssertEqual(model.activeConfigOverrides["mixed-port"], .int(nextPort))
            let preserved = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(preserved.mixedPort, nextPort)
            await model.stopCore()
        }
    }

    @MainActor
    func testCoreSettingsApplyEditsAndRestoresTogether() async throws {
        try await self.withRunningCore { model, selected, _, _, next, occupied in
            let original = try await model.fetchRuntimeConfigSnapshot()
            let status = model.processManager.status
            model.stageCoreSetting(.logLevel, value: .string("debug"))
            model.stageCoreSetting(.mixedPort, value: .string("65536"))
            await model.applyCoreSettings()
            XCTAssertNotNil(model.coreSettingsError)
            XCTAssertEqual(model.pendingCoreSettingsCount, 2)
            let beforeApply = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(beforeApply.overrideFields, original.overrideFields)
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)

            model.stageCoreSetting(.mixedPort, value: .string(String(next)))
            model.stageCoreSetting(.tunStack, value: .string("system"))
            await model.applyCoreSettings()
            XCTAssertNil(model.coreSettingsError)
            XCTAssertEqual(model.pendingCoreSettingsCount, 0)
            XCTAssertEqual(model.activeConfigOverrides, [
                "log-level": .string("debug"), "mixed-port": .int(next), "tun.stack": .string("system"),
            ])
            XCTAssertEqual(model.processManager.status, status)

            model.stageCoreSetting(.logLevel, value: .string("error"))
            model.stageCoreSetting(.mixedPort, value: .string(String(occupied)))
            await model.applyCoreSettings()
            XCTAssertNotNil(model.coreSettingsError)
            XCTAssertEqual(model.pendingCoreSettingsCount, 2)
            let afterFailure = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(afterFailure.logLevel, "debug")
            XCTAssertEqual(afterFailure.mixedPort, next)
            model.discardCoreSettings()

            await model.switchMode(to: .global)
            model.stageCoreSettingsRestore(Set(model.activeConfigOverrides.keys))
            model.stageCoreSetting(.logLevel, value: .string("info"))
            let beforeRestore = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(beforeRestore.mixedPort, next)
            XCTAssertEqual(beforeRestore.logLevel, "debug")
            XCTAssertEqual(beforeRestore.tun?.stack?.lowercased(), "system")
            await model.applyCoreSettings()
            XCTAssertNil(model.coreSettingsError)
            XCTAssertEqual(model.pendingCoreSettingsCount, 0)
            XCTAssertEqual(model.activeConfigOverrides, ["log-level": .string("info")])
            XCTAssertEqual(model.processManager.status, status)

            let restored = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(restored.mixedPort, original.mixedPort)
            XCTAssertEqual(restored.tun?.stack, original.tun?.stack)
            XCTAssertEqual(restored.logLevel, "info")
            XCTAssertEqual(restored.mode, "global")
            XCTAssertEqual(model.runtimeConfigInput?.yaml, try String(contentsOf: selected, encoding: .utf8))

            model.stageCoreSettingsRestore(["log-level"])
            model.stageCoreSetting(.mode, value: .string("direct"))
            XCTAssertEqual(model.currentMode, .global)
            await model.applyCoreSettings()
            XCTAssertNil(model.coreSettingsError)
            XCTAssertEqual(model.currentMode, .direct)
            XCTAssertEqual(model.activeConfigOverrides, ["mode": .string("direct")])

            await model.switchMode(to: .global)
            XCTAssertEqual(model.activeConfigOverrides, ["mode": .string("direct")])
            model.stageCoreSettingsRestore(Set(model.activeConfigOverrides.keys))
            await model.applyCoreSettings()
            XCTAssertNil(model.coreSettingsError)
            XCTAssertEqual(model.currentMode, original.mode.flatMap(CoreMode.init(rawValue:)))
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)
            await model.stopCore()
        }
    }

    @MainActor
    func testSamePathWithNewIdentityDoesNotInheritTunRecovery() async throws {
        try await self.withRunningCore { model, selected, _, _, _, _ in
            let originalID = try XCTUnwrap(model.activeConfigOverrideID)
            model.pendingCoreFeatureRecoveryState = CoreFeatureRecoveryState(
                systemProxyEnabled: false, tunEnabled: true, tunConfigID: originalID)
            XCTAssertTrue(model.shouldRecoverTunForSelectedConfig)

            model.configOverrides.identities[ConfigOverrides.pathKey(for: selected)] = UUID()
            XCTAssertFalse(model.shouldRecoverTunForSelectedConfig)
            await model.stopCore()
        }
    }

    @MainActor
    func testConfigSwitchDoesNotRecoverTunForThePreviousConfig() async throws {
        try await self.withRunningCore { model, selected, nextFile, controller, nextPort, _ in
            try Self.config(controller: controller, mixedPort: nextPort).write(
                to: nextFile, atomically: true, encoding: .utf8)
            model.pendingCoreFeatureRecoveryState = CoreFeatureRecoveryState(
                systemProxyEnabled: false, tunEnabled: true, tunConfigID: try XCTUnwrap(model.activeConfigOverrideID))
            XCTAssertTrue(model.isAwaitingTunRecovery)

            model.configService.selectConfig(nextFile)
            XCTAssertFalse(model.isAwaitingTunRecovery)
            model.configService.selectConfig(selected)
            await model.selectConfigFile(named: nextFile.lastPathComponent)
            XCTAssertEqual(model.selectedConfigName, nextFile.lastPathComponent)
            XCTAssertFalse(model.isTunEnabled)
            XCTAssertNil(model.pendingCoreFeatureRecoveryState)
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)
            let config = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(config.tunEnabled, false)
            await model.stopCore()
        }
    }

    @MainActor
    func testRestartRecoversWhenCommitDirectoryBecomesReadOnly() async throws {
        try XCTSkipIf(geteuid() == 0, "Directory permissions must restrict the test process.")
        try await self.withRunningCore { model, selected, _, _, next, _ in
            let original = try String(contentsOf: selected, encoding: .utf8)
            let directory = selected.deletingLastPathComponent()
            let manager = FileManager.default
            let permissions = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions]
            let candidate = directory.appendingPathComponent(".test-restart.yaml")
            let endpoint = try Self.boundTCPPort()
            Darwin.close(endpoint.socket)
            let incoming = Self.config(controller: endpoint.port, mixedPort: next)
            try incoming.write(to: candidate, atomically: true, encoding: .utf8)
            model.lastCoreFailureAlertKey = "core-restart-failed"
            model.lastCoreFailureAlertAt = Date()

            for formalYAML in [original, original + "\n# edited while the old core was running"] {
                try formalYAML.write(to: selected, atomically: true, encoding: .utf8)
                let outcome = await model.restartCore(candidate: candidate) {
                    XCTAssertEqual(model.runtimeConfigInput?.yaml, incoming)
                    try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                    try model.writeConfigData(Data(incoming.utf8), to: selected)
                    XCTFail("The test must deny the final write.")
                }
                try manager.setAttributes([.posixPermissions: permissions ?? 0o700], ofItemAtPath: directory.path)
                XCTAssertEqual(outcome, .failed)
                XCTAssertTrue(model.processManager.isRunning, model.configApplicationFailure ?? "")
                XCTAssertEqual(model.runtimeConfigInput?.yaml, original)
                XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), formalYAML)
            }
            await model.stopCore()
        }
    }

    @MainActor
    func testFailedUpdateRestoresPreviouslyEffectiveSettingsWhenAnOverrideWasUnavailable() async throws {
        try await self.withRunningCore { model, selected, _, controller, next, occupied in
            let original = try String(contentsOf: selected, encoding: .utf8)
            let name = selected.lastPathComponent
            let subscription = try XCTUnwrap(model.remoteConfigSubscriptions[name])
            await model.patchSingleConfig("log-level", value: .string("debug"))
            model.recordConfigOverrides(["tun.enable": .bool(true)], for: model.activeConfigOverrideID)
            let initial = await model.reloadConfig()
            XCTAssertEqual(initial, .partial)
            let before = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(before.tunEnabled, false)
            XCTAssertEqual(before.logLevel, "debug")
            model.lastCoreFailureAlertKey = "core-restart-failed"
            model.lastCoreFailureAlertAt = Date()

            for rejected in [
                Self.config(controller: controller, mixedPort: occupied),
                Self.config(controller: occupied, mixedPort: next),
            ] {
                do {
                    try await model.installDownloadedRemoteSubscription(
                        Data(rejected.utf8), at: selected, subscription: subscription)
                    XCTFail("The failed update must be reported.")
                } catch {
                    XCTAssertTrue(model.processManager.isRunning)
                    XCTAssertEqual(model.runtimeConfigInput?.yaml, original)
                    XCTAssertTrue(model.configApplicationIssues.contains("tun.enable"))
                    let restored = try await model.fetchRuntimeConfigSnapshot()
                    XCTAssertEqual(restored.overrideFields, before.overrideFields)
                    XCTAssertEqual(model.activeConfigOverrides["tun.enable"], .bool(true))
                }
            }
            model.stageCoreSettingsRestore(["log-level"])
            await model.applyCoreSettings()
            XCTAssertNil(model.activeConfigOverrides["log-level"])
            XCTAssertEqual(model.activeConfigOverrides["tun.enable"], .bool(true))
            XCTAssertTrue(model.configApplicationIssues.contains("tun.enable"))
            let restored = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(restored.logLevel, "warning")
            await model.stopCore()
        }
    }

    @MainActor
    func testAutomaticRefreshDiscardedAfterSelectionChangesRemainsDue() async throws {
        try await self.withRunningCore { model, selected, nextFile, controller, next, _ in
            let original = try String(contentsOf: selected, encoding: .utf8)
            let incoming = Self.config(controller: controller, mixedPort: next)
            try incoming.write(to: nextFile, atomically: true, encoding: .utf8)
            let server = try Self.boundTCPPort()
            defer { Darwin.close(server.socket) }
            let name = selected.lastPathComponent
            let subscription = RemoteConfigSubscription(
                urlString: "http://127.0.0.1:\(server.port)/config", autoUpdateEnabled: true)
            model.remoteConfigSubscriptions[name] = subscription
            let response = Task.detached {
                let header = "HTTP/1.1 200 OK\r\nContent-Length: \(incoming.utf8.count)\r\nConnection: close\r\n\r\n"
                for attempt in 0..<2 {
                    var listener = pollfd(fd: server.socket, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&listener, 1, 10_000) > 0 else { throw POSIXError(.ETIMEDOUT) }
                    let connection = Darwin.accept(server.socket, nil, nil)
                    guard connection >= 0 else { throw POSIXError(.EIO) }
                    defer { Darwin.close(connection) }
                    var request = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&request, 1, 5_000) > 0 else { throw POSIXError(.ETIMEDOUT) }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    guard Darwin.recv(connection, &buffer, buffer.count, 0) > 0 else { throw POSIXError(.EIO) }
                    if attempt == 0 {
                        await model.selectConfigFile(named: nextFile.lastPathComponent)
                    }
                    let handle = FileHandle(fileDescriptor: connection, closeOnDealloc: false)
                    try handle.write(contentsOf: Data((header + incoming).utf8))
                }
            }
            await model.performDueRemoteConfigAutoUpdatesIfNeeded()
            XCTAssertEqual(model.selectedConfigName, nextFile.lastPathComponent)
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), original)
            XCTAssertEqual(model.remoteConfigSubscriptions[name], subscription)
            XCTAssertEqual(model.remoteConfigSubscriptions[name]?.isDue(), true)
            XCTAssertEqual(model.remoteConfigMenuState(for: name).phase, .idle)

            await model.performDueRemoteConfigAutoUpdatesIfNeeded()
            try await response.value
            XCTAssertEqual(model.selectedConfigName, nextFile.lastPathComponent)
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), incoming)
            XCTAssertNotNil(model.remoteConfigSubscriptions[name]?.lastUpdateCheckAt)
            XCTAssertEqual(model.remoteConfigSubscriptions[name]?.isDue(), false)
            await model.stopCore()
        }
    }

    @MainActor
    func testSameSourceUpdateKeepsFormalYAMLUntilRuntimeAcceptsIt() async throws {
        try await self.withRunningCore { model, selected, _, controller, next, occupied in
            let original = try String(contentsOf: selected, encoding: .utf8)
            let subscription = try XCTUnwrap(model.remoteConfigSubscriptions[selected.lastPathComponent])
            let backup = try XCTUnwrap(model.lastLoadedConfigURL(for: selected.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
            await model.patchSingleConfig("log-level", value: .string("debug"))
            model.lastCoreFailureAlertKey = "core-restart-failed"
            model.lastCoreFailureAlertAt = Date()

            for rejected in [
                Self.config(controller: controller, mixedPort: occupied),
                Self.config(controller: occupied, mixedPort: next),
            ] {
                do {
                    try await model.installDownloadedRemoteSubscription(
                        Data(rejected.utf8), at: selected, subscription: subscription)
                    XCTFail("The failed update must be reported to the caller.")
                } catch {
                    XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), original)
                    XCTAssertEqual(model.runtimeConfigInput?.yaml, original)
                    let runtime = try await model.fetchRuntimeConfigSnapshot()
                    XCTAssertEqual(runtime.logLevel, "debug")
                }
            }

            let accepted = Self.config(controller: controller, mixedPort: next)
            try await model.installDownloadedRemoteSubscription(
                Data(accepted.utf8), at: selected, subscription: subscription)
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), accepted)
            XCTAssertEqual(model.runtimeConfigInput?.yaml, accepted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
            let files = try FileManager.default.contentsOfDirectory(atPath: selected.deletingLastPathComponent().path)
            XCTAssertFalse(files.contains { $0.hasPrefix(".clashbar-") })

            try original.write(to: selected, atomically: true, encoding: .utf8)
            XCTAssertFalse(model.isConfigMutationBusy)
            model.stageCoreSettingsRestore(["log-level"])
            await model.applyCoreSettings()
            XCTAssertTrue(model.activeConfigOverrides.isEmpty, model.coreSettingsError ?? "No restore error")
            XCTAssertEqual(model.runtimeConfigInput?.yaml, accepted)
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), original)
            await model.stopCore()
        }
    }

    @MainActor
    func testCommitFailureRestoresRuntimeAfterCandidateHasLoaded() async throws {
        try await self.withRunningCore { model, selected, _, controller, next, _ in
            let original = try String(contentsOf: selected, encoding: .utf8)
            let candidate = selected.deletingLastPathComponent().appendingPathComponent(".test-candidate.yaml")
            let incoming = Self.config(controller: controller, mixedPort: next)
            try incoming.write(to: candidate, atomically: true, encoding: .utf8)
            let externalEdit = original + "\n# external edit"

            let name = selected.lastPathComponent
            let outcome = await model.reloadRefreshedRemoteConfig(named: name, candidate: candidate) {
                XCTAssertEqual(model.runtimeConfigInput?.yaml, incoming)
                XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), original)
                try externalEdit.write(to: selected, atomically: true, encoding: .utf8)
                throw ConfigApplicationError.stale
            }
            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), externalEdit)
            XCTAssertEqual(model.runtimeConfigInput?.yaml, original)
            XCTAssertTrue(try XCTUnwrap(model.configApplicationFailure).contains(
                model.tr("app.config.apply.previous_restored")))
            await model.stopCore()
        }
    }

    @MainActor
    func testInactiveSubscriptionKeepsOnlyLatestDownload() async throws {
        try await self.withRunningCore { model, selected, inactive, controller, _, occupied in
            let original = try String(contentsOf: selected, encoding: .utf8)
            let subscription = RemoteConfigSubscription(urlString: "https://example.com/inactive.yaml")
            let name = inactive.lastPathComponent
            model.remoteConfigSubscriptions[name] = subscription
            let latest = Self.config(controller: controller, mixedPort: occupied)
            let changed = try await model.installDownloadedRemoteSubscription(
                Data(latest.utf8), at: inactive, subscription: subscription)
            XCTAssertTrue(changed)
            XCTAssertTrue(model.pendingConfigFileNames.contains(name))
            XCTAssertEqual(try String(contentsOf: inactive, encoding: .utf8), latest)
            XCTAssertEqual(model.runtimeConfigInput?.yaml, original)

            await model.stopCore()
            await model.selectConfigFile(named: name)
            model.lastCoreFailureAlertKey = "core-start-failed"
            model.lastCoreFailureAlertAt = Date()
            await model.startCore()
            XCTAssertFalse(model.processManager.isRunning)
            XCTAssertNil(model.runtimeConfigInput)
            XCTAssertNotNil(model.configApplicationFailure)
            XCTAssertEqual(try String(contentsOf: inactive, encoding: .utf8), latest)
        }
    }

    @MainActor
    func testLegacyBackupSurvivesUntilFormalYAMLLoads() async throws {
        try await self.withRunningCore { model, selected, _, controller, next, occupied in
            let original = try String(contentsOf: selected, encoding: .utf8)
            let backup = try XCTUnwrap(model.lastLoadedConfigURL(for: selected.path))
            try original.write(to: backup, atomically: true, encoding: .utf8)
            model.removeRedundantLegacyConfigBackups()
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

            await model.stopCore()
            try original.write(to: backup, atomically: true, encoding: .utf8)
            let unbindable = Self.config(controller: controller, mixedPort: occupied)
            try unbindable.write(to: selected, atomically: true, encoding: .utf8)
            model.removeRedundantLegacyConfigBackups()
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
            await model.startCore()
            XCTAssertEqual(model.runtimeConfigInput?.yaml, original)
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), unbindable)
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

            let subscription = try XCTUnwrap(model.remoteConfigSubscriptions[selected.lastPathComponent])
            let accepted = Self.config(controller: controller, mixedPort: next)
            try await model.installDownloadedRemoteSubscription(
                Data(accepted.utf8), at: selected, subscription: subscription)
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
            await model.stopCore()
        }
    }

    @MainActor
    func testLoadsSubscriptionAndRollsBackToPreviousConfiguration() async throws {
        try await self.withRunningCore { model, selected, rejected, controller, next, occupied in
            await model.patchSingleConfig("log-level", value: .string("debug"))
            XCTAssertEqual(model.activeConfigOverrides, ["log-level": ConfigPatchValue.string("debug")])
            let updated = Self.config(controller: controller, mixedPort: next)
            try updated.write(to: selected, atomically: true, encoding: .utf8)
            XCTAssertNotEqual(model.runtimeConfigInput?.yaml, updated)
            await model.reloadRefreshedRemoteConfig(named: selected.lastPathComponent)
            XCTAssertEqual(model.remoteConfigMenuState(for: selected.lastPathComponent).phase, .applied)
            let observed = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(observed.mixedPort, next)
            XCTAssertEqual(observed.logLevel, "debug")
            XCTAssertEqual(observed.tunEnabled, false)
            XCTAssertEqual(model.runtimeConfigInput?.yaml, updated)
            XCTAssertNil(model.configApplicationFailure)
            XCTAssertTrue(model.configApplicationIssues.isEmpty)

            await model.patchSingleConfig("mixed-port", value: .int(next))
            let maskedPort = Self.config(controller: controller, mixedPort: occupied)
            try maskedPort.write(to: selected, atomically: true, encoding: .utf8)
            await model.reloadConfig()
            XCTAssertEqual(model.runtimeConfigInput?.yaml, maskedPort)
            XCTAssertEqual(model.mixedPort, next)
            XCTAssertNil(model.configApplicationFailure)
            try updated.write(to: selected, atomically: true, encoding: .utf8)
            await model.reloadConfig()
            model.stageCoreSettingsRestore(["mixed-port"])
            await model.applyCoreSettings()

            let unbindable = Self.config(controller: controller, mixedPort: occupied)
            try unbindable.write(to: selected, atomically: true, encoding: .utf8)
            await model.reloadRefreshedRemoteConfig(named: selected.lastPathComponent)
            XCTAssertEqual(model.remoteConfigMenuState(for: selected.lastPathComponent).phase, .applyFailed)
            let rolledBack = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(rolledBack.mixedPort, next)
            XCTAssertEqual(rolledBack.logLevel, "debug")
            XCTAssertEqual(model.runtimeConfigInput?.yaml, updated)
            XCTAssertNotNil(model.configApplicationFailure)
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), unbindable)
            try updated.write(to: selected, atomically: true, encoding: .utf8)

            do {
                let subscription = try XCTUnwrap(model.remoteConfigSubscriptions[selected.lastPathComponent])
                try await model.installDownloadedRemoteSubscription(
                    Data("tun: [invalid".utf8), at: selected, subscription: subscription)
                XCTFail("The malformed candidate must be rejected by Mihomo.")
            } catch {
                XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), updated)
            }

            let requiresPrivilege = updated.replacingOccurrences(
                of: "enable: false", with: "enable: true, auto-route: false, auto-detect-interface: false")
            try requiresPrivilege.write(to: selected, atomically: true, encoding: .utf8)
            await model.reloadConfig()
            let withoutPermission = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(withoutPermission.tunEnabled, false)
            XCTAssertEqual(model.runtimeConfigInput?.yaml, updated)
            XCTAssertNotNil(model.configApplicationFailure)
            try updated.write(to: selected, atomically: true, encoding: .utf8)

            model.stageCoreSettingsRestore(["log-level"])

            await model.applyCoreSettings()
            let restored = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(restored.logLevel, "warning")
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)

            await model.selectTunStack("system")
            let configuredStack = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(configuredStack.tunEnabled, false)
            XCTAssertEqual(configuredStack.tun?.stack?.lowercased(), "system")
            XCTAssertEqual(model.activeConfigOverrides, ["tun.stack": .string("system")])
            model.stageCoreSettingsRestore(["tun.stack"])
            await model.applyCoreSettings()
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)

            let phaseName = selected.lastPathComponent
            model.recordConfigOverrides(["tun.enable": .bool(true)], for: model.activeConfigOverrideID)
            await model.reloadRefreshedRemoteConfig(named: phaseName)
            XCTAssertEqual(model.remoteConfigMenuState(for: phaseName).phase, .partiallyApplied)
            XCTAssertEqual(model.activeConfigOverrides["tun.enable"], .bool(true))
            model.stageCoreSettingsRestore(["tun.enable"])
            await model.applyCoreSettings()
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)

            model.lastCoreFailureAlertKey = "core-restart-failed"
            model.lastCoreFailureAlertAt = Date()
            await model.selectConfigFile(named: rejected.lastPathComponent)
            XCTAssertEqual(model.configService.selectedConfig?.lastPathComponent, selected.lastPathComponent)
            XCTAssertEqual(model.runtimeConfigInput?.yaml, updated)
            XCTAssertTrue(model.processManager.isRunning, model.configApplicationFailure ?? "")
            XCTAssertNotNil(model.configApplicationFailure)
            await model.stopCore()
        }
    }

    @MainActor
    func testSameNameReplacementCommitsOnlyAfterSuccessfulRuntimeValidation() async throws {
        try await self.withRunningCore { model, selected, _, controller, next, occupied in
            let updated = try String(contentsOf: selected, encoding: .utf8)
            let sourceName = selected.lastPathComponent
            let originalSource = RemoteConfigSubscription(urlString: "https://example.com/original.yaml")
            let replacementSource = RemoteConfigSubscription(urlString: "https://example.com/replacement.yaml")
            await model.patchSingleConfig("log-level", value: .string("debug"))
            let oldIdentity = model.activeConfigOverrideID
            let occupiedController = Self.config(controller: occupied, mixedPort: next)
            model.lastCoreFailureAlertKey = "core-restart-failed"
            model.lastCoreFailureAlertAt = Date()
            do {
                try await model.installDownloadedRemoteSubscription(
                    Data(occupiedController.utf8), at: selected, subscription: replacementSource)
                XCTFail("An occupied controller must reject the replacement.")
            } catch {
                XCTAssertEqual(model.remoteConfigSubscriptions[sourceName], originalSource)
                XCTAssertEqual(model.activeConfigOverrideID, oldIdentity)
                XCTAssertEqual(model.activeConfigOverrides["log-level"], .string("debug"))
                XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), updated)
                XCTAssertEqual(model.runtimeConfigInput?.yaml, updated)
                let originalRuntime = try await model.fetchRuntimeConfigSnapshot()
                XCTAssertEqual(originalRuntime.logLevel, "debug")
            }

            let recoveryFile = try XCTUnwrap(model.lastLoadedConfigURL(for: selected.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryFile.path))
            await model.stopCore()
            try await model.installDownloadedRemoteSubscription(
                Data(occupiedController.utf8), at: selected, subscription: replacementSource)
            XCTAssertEqual(model.remoteConfigSubscriptions[sourceName], originalSource)
            XCTAssertEqual(model.activeConfigOverrideID, oldIdentity)
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), updated)
            let pending = try XCTUnwrap(model.pendingRemoteConfigReplacements[sourceName])
            let persisted = model.decodeFromDefaults(
                [String: PendingRemoteConfigReplacement].self, key: "remote-config-replacements")
            XCTAssertEqual(persisted?[sourceName], pending)
            XCTAssertTrue(FileManager.default.fileExists(atPath: pending.file(beside: selected).path))
            await model.startCore()
            XCTAssertTrue(model.processManager.isRunning, model.configApplicationFailure ?? "")
            XCTAssertEqual(model.runtimeConfigInput?.yaml, updated)
            XCTAssertEqual(model.activeConfigOverrides["log-level"], .string("debug"))
            XCTAssertNil(model.pendingRemoteConfigReplacements[sourceName])

            let replacement = Self.config(controller: controller, mixedPort: next)
            try await model.installDownloadedRemoteSubscription(
                Data(replacement.utf8), at: selected, subscription: replacementSource)
            XCTAssertEqual(model.remoteConfigSubscriptions[sourceName], replacementSource)
            XCTAssertNotEqual(model.activeConfigOverrideID, oldIdentity)
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)
            XCTAssertEqual(model.mixedPort, next)
            XCTAssertEqual(model.logLevel, "warning")
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), replacement)
            XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryFile.path))
            XCTAssertEqual(model.remoteConfigMenuState(for: sourceName).phase, .applied)
            await model.stopCore()
        }
    }

    @MainActor
    private func withRunningCore(
        _ run: (AppViewModel, URL, URL, Int, Int, Int) async throws -> Void
    ) async throws {
        guard let binary = ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] else {
            throw XCTSkip("Set CLASHBAR_TEST_MIHOMO to exercise a local core with isolated settings.")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "clashbar.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directories = WorkingDirectoryManager(homeDirectory: home)
        try directories.bootstrapDirectories()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.copyItem(atPath: binary, toPath: directories.managedMihomoBinaryURL.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directories.managedMihomoBinaryURL.path)

        let controller = try Self.boundTCPPort()
        let first = try Self.boundTCPPort()
        let next = try Self.boundTCPPort()
        let occupied = try Self.boundTCPPort()
        Darwin.close(controller.socket)
        Darwin.close(first.socket)
        Darwin.close(next.socket)
        defer { Darwin.close(occupied.socket) }

        let configManager = ConfigDirectoryManager(workingDirectoryManager: directories)
        let configService = ConfigService(configManager: configManager, configImportService: ConfigImportService())
        let process = MihomoProcessManager(workingDirectoryManager: directories)
        let model = AppViewModel(dependencies: AppDependencies(
            processManager: process,
            configService: configService,
            systemProxyService: SystemProxyService(),
            tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(),
            workingDirectoryManager: directories,
            networkReachabilityMonitor: NetworkReachabilityMonitor(),
            ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: .shared, defaults: defaults),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: directories.iconDirectoryURL, session: .shared),
            clashbarLogStore: AppLogStore(logFileURL: directories.logsDirectoryURL.appendingPathComponent("app.log")),
            mihomoLogStore: AppLogStore(logFileURL: directories.logsDirectoryURL.appendingPathComponent("core.log"))),
            defaults: defaults)
        defer { process.stopImmediately() }

        let selected = directories.configDirectoryURL.appendingPathComponent("a.yaml")
        let rejected = directories.configDirectoryURL.appendingPathComponent("b.yaml")
        try Self.config(controller: controller.port, mixedPort: first.port)
            .write(to: selected, atomically: true, encoding: .utf8)
        try Self.config(controller: occupied.port, mixedPort: first.port)
            .write(to: rejected, atomically: true, encoding: .utf8)
        configService.setConfigDirectory(directories.configDirectoryURL)
        configService.selectConfig(selected)
        let originalSource = RemoteConfigSubscription(urlString: "https://example.com/original.yaml")
        model.remoteConfigSubscriptions[selected.lastPathComponent] = originalSource
        await model.startCore()
        XCTAssertTrue(model.configApplicationLoaded, model.configApplicationFailure ?? "")
        XCTAssertEqual(model.mixedPort, first.port)
        XCTAssertTrue(model.activeConfigOverrides.isEmpty)

        try await run(model, selected, rejected, controller.port, next.port, occupied.port)
    }

    private static func config(controller: Int, mixedPort: Int) -> String {
        """
        external-controller: 127.0.0.1:\(controller)
        mixed-port: \(mixedPort)
        log-level: warning
        tun: {enable: false}
        proxies: []
        rules:
          - MATCH,DIRECT
        """
    }

    private static func boundTCPPort() throws -> (socket: Int32, port: Int) {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(socket, socketAddress, length) == 0 else { return Int32(-1) }
                guard Darwin.listen(socket, 1) == 0 else { return Int32(-1) }
                return getsockname(socket, socketAddress, &length)
            }
        }
        guard result == 0 else {
            Darwin.close(socket)
            throw POSIXError(.EADDRINUSE)
        }
        return (socket, Int(UInt16(bigEndian: address.sin_port)))
    }
}
