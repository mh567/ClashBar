import AppKit
import Foundation

@MainActor
extension AppViewModel {
    func configureManagedProcessCallbacks() {
        if let managedProcess = self.processManager as? MihomoProcessManager {
            managedProcess.onLog = { [weak self] line in
                Task { @MainActor in
                    guard self?.isRemoteTarget != true else { return }
                    self?.appendMihomoLog(level: "info", message: line)
                }
            }
            managedProcess.onTermination = { [weak self] code in
                Task { @MainActor in
                    if self?.processManager.isRunning == false {
                        self?.clearLoadedConfigState()
                    }
                    guard self?.isRemoteTarget != true else { return }
                    let message = self?.tr("log.process.terminated", code) ?? ""
                    self?.statusText = "Failed"
                    self?.apiStatus = .failed
                    self?.resetTrafficPresentation()
                    self?.appendLog(level: NetworkLogSeverity.error.rawValue, message: message)
                    self?.cancelPolling()
                    self?.networkDriver?.coreCrashed()
                    if self?.coreActionState == .idle, let self, !message.isEmpty {
                        self.presentBackgroundBanner(StatusItemBanner(
                            symbolName: "exclamationmark.triangle.fill",
                            title: self.tr("ui.banner.core.terminated.title"),
                            primaryDetail: message,
                            secondaryDetail: nil))
                    }
                }
            }
        }
    }

    func resolveMihomoBinaryPathInBackground() async {
        guard let managedProcess = self.processManager as? MihomoProcessManager else {
            self.mihomoBinaryPath = self.processManager.detectedBinaryPath ?? "-"
            return
        }

        let resolved = await managedProcess.detectedBinaryPathAsync()
        self.mihomoBinaryPath = resolved ?? "-"
    }

    func bootstrapDirectoriesAndLogs() {
        do {
            try self.workingDirectoryManager.bootstrapDirectories()
            ensureLogFileExists()
            seedBundledConfigIfNeeded()
        } catch {
            appendLog(level: "error", message: tr("log.working_dir_init_failed", error.localizedDescription))
        }
    }

    func start() {
        guard !self.didStart else { return }
        self.didStart = true
        self.bootstrapDirectoriesAndLogs()
        self.registerWorkspaceWakeObserver()
        self.performDeferredInitialization()
    }

    private func registerWorkspaceWakeObserver() {
        guard self.workspaceWakeObserver == nil else { return }
        self.workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemDidWake()
            }
        }
    }

    private func performDeferredInitialization() {
        self.configOverrides = self.decodeFromDefaults(ConfigOverrides.self, key: "config-overrides")
            ?? ConfigOverrides()
        if self.configOverrides.migrateLegacyModeOverrides() {
            self.persistConfigOverrides()
        }
        if self.configOverrides.pruneRemovedFieldOverrides() {
            self.persistConfigOverrides()
        }
        self.remoteConfigSubscriptions = loadPersistedRemoteConfigSubscriptions()
        self.pendingRemoteConfigReplacements =
            self.decodeFromDefaults([String: PendingRemoteConfigReplacement].self, key: "remote-config-replacements") ?? [:]
        self.pendingConfigFileNames.formUnion(self.pendingRemoteConfigReplacements.keys)
        restoreSavedConfigDirectory()
        restoreLastSuccessfulConfigIfAvailable()
        self.removeRedundantLegacyConfigBackups()
        pruneRemoteConfigSubscriptionsIfNeeded()
        restartRemoteConfigBackgroundTasksIfNeeded()
        self.ssidStrategyRules = loadPersistedSSIDStrategyRules()
        self.pruneSSIDStrategyRulesIfNeeded()
        self.remoteMachineStore.resetActiveTarget()
        if let configPath = self.configService.selectedConfig?.path {
            _ = self.applyExternalControllerFromSelectedConfigFile(configPath: configPath)
        } else {
            self.refreshControllerUIURL()
        }
        if let persisted = loadPersistedEditableSettingsSnapshot() {
            applyEditableSettingsSnapshotToUI(persisted)
        }
        let persistedSystemProxyExceptions = loadPersistedSystemProxyExceptions() ?? Self.defaultSystemProxyExceptions
        self.replaceSystemProxyExceptionsDraft(with: persistedSystemProxyExceptions)
        self.lastSavedSystemProxyExceptions = self.normalizedSystemProxyExceptionValues(persistedSystemProxyExceptions)

        self.startupRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveMihomoBinaryPathInBackground()
            await self.refreshFromAPI(includeSlowCalls: true)
            self.seedCoreFeatureRecoveryFromPersistedQuitState()
            if self.hasSystemProxyOpenIntent {
                await self.refreshSystemProxyHelperStatus()
                await self.refreshSystemProxyStatus()
                await self.ensureSystemProxyConsistencyOnFirstLaunchIfNeeded()
            } else {
                self.resetSystemProxyObservedState()
                self.didCheckSystemProxyConsistencyOnLaunch = true
            }
        }

        self.startConfigDirectoryMonitoringIfNeeded()
        self.updateNetworkReachabilityMonitoringState()
        if self.autoStartCore {
            if !self.shouldDeferAutoStartForMissingManagedCore() {
                self.autoStartTask = Task { [weak self] in
                    guard let self else { return }
                    for _ in 0..<10 where self.networkReachabilityMonitor.currentStatus == .unknown {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard Self.shouldAttemptAutoStart(
                        reachability: self.networkReachabilityMonitor.currentStatus)
                    else { return }
                    await self.attemptAutoStartIfNeeded()
                }
            }
        }

        self.refreshSSIDStrategyState(requestAuthorizationIfNeeded: self.ssidStrategyEnabled)
        self.refreshMenuBarDisplaySnapshotIfNeeded()
    }
}

extension AppViewModel {
    static func resolveBundledMihomoCoreFlag() -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ClashBarBundlesMihomoCore") else {
            return true
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return NSString(string: string).boolValue
        }
        return true
    }

    func hasInstalledManagedMihomoCore() -> Bool {
        FileManager.default.fileExists(atPath: workingDirectoryManager.managedMihomoBinaryURL.path)
    }

    func shouldDeferAutoStartForMissingManagedCore() -> Bool {
        !bundlesMihomoCore && !self.hasInstalledManagedMihomoCore()
    }

    nonisolated static func shouldAttemptAutoStart(
        reachability: NetworkReachabilityStatus) -> Bool
    {
        reachability != .offline
    }

    nonisolated static func isDeterministicCoreStartFailure(_ error: Error) -> Bool {
        if let coreError = error as? CoreStartError {
            return coreError.isDeterministic
        }
        return error is MihomoBinaryResolutionError
    }

    func coreErrorMessage(_ error: Error) -> String {
        if let binaryResolutionError = error as? MihomoBinaryResolutionError {
            switch binaryResolutionError {
            case let .binaryNotFound(expectedDirectory):
                return tr("app.core.error.binary_not_found", expectedDirectory)
            }
        }
        if let coreStartError = error as? CoreStartError {
            return self.coreStartErrorMessage(coreStartError)
        }

        return error.localizedDescription
    }

    func coreStartErrorMessage(_ error: CoreStartError) -> String {
        switch error {
        case let .portConflict(controller, port, owner):
            if let owner {
                return tr(
                    "app.core.error.port_conflict",
                    controller,
                    port,
                    Int(owner.pid),
                    owner.executablePath ?? tr("app.core.error.unknown_process"))
            }
            return tr("app.core.error.port_conflict_unowned", controller, port)
        case let .staleCoreTerminationFailed(pid, reason, helperOutdated):
            let message = tr("app.core.error.stale_core_termination", Int(pid), reason)
            guard helperOutdated else { return message }
            return message + " " + tr("app.core.error.helper_outdated_hint")
        case let .binaryMissing(expectedDirectory):
            return tr("app.core.error.binary_not_found", expectedDirectory)
        case let .configInvalid(reason):
            return tr("app.core.error.config_invalid", reason)
        case let .permissionDenied(reason):
            return tr("app.core.error.permission_denied", reason)
        case let .launchFailed(reason):
            return tr("app.core.error.launch_failed", reason)
        }
    }
}
