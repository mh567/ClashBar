import XCTest
@testable import ClashBar

private final class SuspendingProcessManager: MihomoControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: CoreLifecycleStatus = .stopped

    var status: CoreLifecycleStatus {
        self.lock.withLock { self.storedStatus }
    }

    var isRunning: Bool {
        self.lock.withLock {
            if case .running = self.storedStatus { return true }
            return false
        }
    }

    var detectedBinaryPath: String? {
        "/tmp/mihomo"
    }

    func validateConfigAsync(configPath: String) async throws {}

    @discardableResult
    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        self.lock.withLock { self.storedStatus = .starting }
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            self.lock.withLock { self.storedStatus = .stopped }
            throw error
        }
        self.lock.withLock { self.storedStatus = .running(pid: 1) }
        return self.status
    }

    func stop() {
        self.lock.withLock { self.storedStatus = .stopped }
    }

    func stopAsync() async {
        self.lock.withLock { self.storedStatus = .stopped }
    }

    @discardableResult
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        try await self.startAsync(configPath: configPath, controller: controller)
    }
}

final class CoreCancellationTests: XCTestCase {
    private var home: URL!
    private var directories: WorkingDirectoryManager!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        self.home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.directories = WorkingDirectoryManager(homeDirectory: self.home)
        try self.directories.bootstrapDirectories()
        let suite = "clashbar.cancellation.\(UUID().uuidString)"
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.home)
    }

    func testCancellationLikeErrorsAreDetected() {
        XCTAssertTrue(AppViewModel.isCancellationLike(CancellationError()))
        XCTAssertTrue(AppViewModel.isCancellationLike(ConfigApplicationError.cancelled))
        XCTAssertTrue(AppViewModel.isCancellationLike(URLError(.cancelled)))
        XCTAssertFalse(AppViewModel.isCancellationLike(CocoaError(.fileNoSuchFile)))
        XCTAssertFalse(AppViewModel.isCancellationLike(ConfigApplicationError.stale))
    }

    func testStartupAutoStartDefersOnlyWhenOffline() {
        XCTAssertFalse(AppViewModel.shouldAttemptAutoStart(reachability: .offline))
        XCTAssertTrue(AppViewModel.shouldAttemptAutoStart(reachability: .online))
        XCTAssertTrue(AppViewModel.shouldAttemptAutoStart(reachability: .unknown))
    }

    func testTaskCancellationIsDetected() async {
        let task = Task { () -> Bool in
            while !Task.isCancelled {
                await Task.yield()
            }
            return AppViewModel.isCancellationLike(CocoaError(.fileNoSuchFile))
        }
        task.cancel()

        let detected = await task.value
        XCTAssertTrue(detected)
    }

    @MainActor
    func testStartCoreCancellationDoesNotRecordFailure() async throws {
        let processManager = SuspendingProcessManager()
        let model = try self.makeModel(processManager: processManager)

        let task = Task { await model.startCore(trigger: .manual) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await task.value

        XCTAssertNil(model.configApplicationFailure)
        XCTAssertEqual(model.coreActionState, .idle)
        XCTAssertNil(model.statusItemBanner)
        XCTAssertTrue(model.lastCoreStartWasCancelled)
    }

    @MainActor
    private func makeModel(processManager: any MihomoControlling) throws -> AppViewModel {
        let configManager = ConfigDirectoryManager(workingDirectoryManager: self.directories)
        let configService = ConfigService(
            configManager: configManager, configImportService: ConfigImportService())
        let model = AppViewModel(dependencies: AppDependencies(
            processManager: processManager,
            configService: configService,
            systemProxyService: SystemProxyService(),
            tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(),
            workingDirectoryManager: self.directories,
            networkReachabilityMonitor: FakeNetworkReachabilityMonitor(),
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
        model.controller = "127.0.0.1:9099"
        model.controllerSecret = nil
        return model
    }
}
