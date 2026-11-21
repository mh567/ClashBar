import Darwin
import Foundation
import XCTest
@testable import ClashBar

final class ConfigApplicationIntegrationTests: XCTestCase {
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
            await model.restoreConfigField("mixed-port")

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
                try await model.validateDownloadedConfig(Data("tun: [invalid".utf8), for: selected)
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

            await model.restoreConfigField("log-level")
            let restored = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(restored.logLevel, "warning")
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)

            await model.selectTunStack("system")
            let configuredStack = try await model.fetchRuntimeConfigSnapshot()
            XCTAssertEqual(configuredStack.tunEnabled, false)
            XCTAssertEqual(configuredStack.tun?.stack?.lowercased(), "system")
            XCTAssertEqual(model.activeConfigOverrides, ["tun.stack": .string("system")])
            await model.restoreConfigField("tun.stack")
            XCTAssertTrue(model.activeConfigOverrides.isEmpty)

            let phaseName = selected.lastPathComponent
            model.recordConfigOverrides(["tun.enable": .bool(true)], for: model.activeConfigOverrideID)
            await model.reloadRefreshedRemoteConfig(named: phaseName)
            XCTAssertEqual(model.remoteConfigMenuState(for: phaseName).phase, .partiallyApplied)
            XCTAssertEqual(model.activeConfigOverrides["tun.enable"], .bool(true))
            await model.restoreConfigField("tun.enable")
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
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFile.path))
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
