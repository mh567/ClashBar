import XCTest
@testable import ClashBar

/// Reproduces the reported core-settings bugs against a fake controller, so no core is
/// launched and the user's running instance on 9090 is never touched.
///
/// Reported symptoms:
/// - After a fresh read the field shows 未覆写; toggling it should hot-apply and show
///   已覆写, but a 全部恢复 button also appears.
/// - Toggling it back should stop being 已覆写, but it kept showing 已覆写.
final class CoreSettingsImmediateApplyTests: XCTestCase {
    private var home: URL!
    private var directories: WorkingDirectoryManager!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        self.home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.directories = WorkingDirectoryManager(homeDirectory: self.home)
        try self.directories.bootstrapDirectories()
        let suite = "clashbar.tests.\(UUID().uuidString)"
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.home)
    }

    /// Builds a model wired to a fake controller and an isolated config file, so no core
    /// is launched and the user's running instance on 9090 is never touched.
    @MainActor
    private func makeModel(port: Int) throws -> (AppViewModel, URL) {
        let configManager = ConfigDirectoryManager(workingDirectoryManager: self.directories)
        let configService = ConfigService(
            configManager: configManager, configImportService: ConfigImportService())
        let model = AppViewModel(dependencies: AppDependencies(
            processManager: MihomoProcessManager(workingDirectoryManager: self.directories),
            configService: configService,
            systemProxyService: SystemProxyService(),
            tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(),
            workingDirectoryManager: self.directories,
            networkReachabilityMonitor: NetworkReachabilityMonitor(),
            ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: .shared, defaults: self.defaults),
            proxyGroupIconCache: ProxyGroupIconCache(
                iconDirectory: self.directories.iconDirectoryURL, session: .shared),
            clashbarLogStore: AppLogStore(
                logFileURL: self.directories.logsDirectoryURL.appendingPathComponent("app.log")),
            mihomoLogStore: AppLogStore(
                logFileURL: self.directories.logsDirectoryURL.appendingPathComponent("core.log"))),
            defaults: self.defaults)

        let selected = self.directories.configDirectoryURL.appendingPathComponent("probe.yaml")
        try """
        mixed-port: 7890
        mode: rule
        log-level: info
        ipv6: false
        allow-lan: false
        tcp-concurrent: false
        tun: {enable: false}
        proxies: []
        rules:
          - MATCH,DIRECT
        """.write(to: selected, atomically: true, encoding: .utf8)

        configService.setConfigDirectory(self.directories.configDirectoryURL)
        configService.selectConfig(selected)

        model.controller = "127.0.0.1:\(port)"
        model.controllerSecret = nil
        // No process is spawned; this only makes the app treat the controller as live.
        model.statusText = "Running"
        return (model, selected)
    }

    @MainActor
    func testTogglingIPv6OnThenOffTracksItsOwnState() async throws {
        let fake = FakeMihomoController(config: [
            "ipv6": false,
            "allow-lan": false,
            "tcp-concurrent": false,
            "mixed-port": 7890,
            "mode": "rule",
            "log-level": "info",
            "tun": ["enable": false],
        ])
        try fake.start()
        defer { fake.stop() }

        let (model, _) = try self.makeModel(port: fake.port)
        _ = try await model.fetchRuntimeConfigSnapshot()
        await model.reconcileEditableSettingsWithRuntimeConfig()

        XCTAssertEqual(model.settingsIPv6, false, "the fresh read must land in the UI state")
        XCTAssertNil(model.activeConfigOverrides["ipv6"], "nothing is overridden yet")
        XCTAssertEqual(model.configOverrideCount, 0, "no override, so no restore affordance")

        // Turn it on: this is an unconstrained field, so it should hot-apply.
        model.stageCoreSetting(.ipv6, value: .bool(true))
        await model.awaitPendingCoreSettingCommits()

        XCTAssertEqual(fake.currentConfig["ipv6"] as? Bool, true, "the core received the change")
        XCTAssertEqual(model.activeConfigOverrides["ipv6"], .bool(true), "the change is recorded")

        // Turn it back off: the override must not linger once it matches the file again.
        model.stageCoreSetting(.ipv6, value: .bool(false))
        await model.awaitPendingCoreSettingCommits()

        XCTAssertEqual(fake.currentConfig["ipv6"] as? Bool, false, "the core received the revert")
        XCTAssertNil(
            model.activeConfigOverrides["ipv6"],
            "matching the file again must drop the override instead of staying 已覆写")
    }
}
