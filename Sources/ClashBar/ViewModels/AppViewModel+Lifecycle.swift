import AppKit
import Foundation

@MainActor
extension AppViewModel {
    private struct CoreBootstrapOptions {
        let providerTrigger: ProviderRefreshTrigger
        let refreshProxyGroupsAfterBootstrap: Bool
        let refreshSystemProxyBeforeOverlay: Bool
        let refreshSystemProxyAfterBootstrap: Bool
        let autoTestGroupLatencies: Bool
    }

    private enum CoreTransitionKind {
        case stop
        case restart
    }

    func startCore(trigger: StartTrigger = .manual) async {
        guard !self.isRemoteTarget else { return }
        self.lastCoreStartWasCancelled = false
        guard !self.isConfigMutationBusy else {
            if trigger.isUserInitiated {
                self.deferredCoreIntent = .running
            }
            return
        }
        self.coreActionState = .starting
        self.configReadEpoch = UUID()
        if trigger.isUserInitiated {
            self.networkDriver?.userRequestedStart()
        }
        defer {
            self.configReadEpoch = UUID()
            self.coreActionState = .idle
            self.flushDeferredCoreIntentIfNeeded()
        }
        do {
            guard let configPath = await self.resolveSelectedConfigPath() else {
                throw CocoaError(.fileNoSuchFile)
            }
            _ = try await self.launchSelectedConfig(
                path: configPath, restarting: false,
                options: CoreBootstrapOptions(
                    providerTrigger: .start,
                    refreshProxyGroupsAfterBootstrap: false,
                    refreshSystemProxyBeforeOverlay: true,
                    refreshSystemProxyAfterBootstrap: false,
                    autoTestGroupLatencies: true))
            if trigger.reportsNetworkCoreStart, self.isRuntimeRunning {
                self.networkDriver?.coreDidStart()
            }
        } catch {
            if Self.isCancellationLike(error) {
                self.lastCoreStartWasCancelled = true
                self.logCoreCancellation("log.start.cancelled")
                if trigger.reportsNetworkCoreStart, self.isRuntimeRunning {
                    self.networkDriver?.coreDidStart()
                }
                return
            }
            self.configApplicationFailure = self.configApplicationErrorMessage(error)
            let message = tr("log.start.failed", self.configApplicationFailure ?? "")
            self.reportCoreStartFailure(message: message, trigger: trigger, markFailedOnManual: true)
        }
    }

    private func reportCoreStartFailure(message: String, trigger: StartTrigger, markFailedOnManual: Bool) {
        self.appendLog(level: NetworkLogSeverity.error.rawValue, message: message)
        if trigger.failurePresentation != .none {
            self.presentCoreFailureAlert(
                title: self.tr("app.core.alert.start_failed.title"),
                message: message,
                dedupeKey: "core-start-failed",
                presentation: trigger.failurePresentation)
        }
        if trigger == .auto || trigger == .networkRecovery {
            self.startupErrorMessage = message
            self.statusText = "Stopped"
            self.apiStatus = .unknown
        } else if markFailedOnManual {
            self.statusText = "Failed"
            self.apiStatus = .failed
        }
    }

    func stopCore(trigger: StopTrigger = .manual) async {
        guard !self.isRemoteTarget else { return }
        guard !self.isConfigMutationBusy else {
            if trigger.isUserInitiated {
                self.deferredCoreIntent = .stopped
            }
            return
        }
        let recoverySnapshotBeforeStop = self.currentCoreFeatureRecoverySnapshot()
        self.coreActionState = .stopping
        self.configReadEpoch = UUID()
        if trigger.isUserInitiated {
            self.networkDriver?.userRequestedStop()
        }
        defer {
            self.configReadEpoch = UUID()
            self.coreActionState = .idle
            self.flushDeferredCoreIntentIfNeeded()
        }
        await self.prepareCoreFeatureRecoveryBeforeCoreTransition(
            fallbackRecovery: recoverySnapshotBeforeStop,
            transitionKind: .stop,
            disableRuntimeTunBeforeStop: false)
        cancelProviderRefresh(reason: "stop requested")
        await self.processManager.stop()
        self.clearLoadedConfigState()
        cancelPolling()
        statusText = "Stopped"
        apiStatus = .unknown
        clearProxyPresentation()
        resetTrafficPresentation()
        if trigger.reportsNetworkCoreStop {
            self.networkDriver?.coreDidStop()
        }
    }

    @discardableResult
    func restartCore(
        trigger: ProviderRefreshTrigger = .restart, candidate: URL? = nil, commit: (() throws -> Void)? = nil,
        isUserInitiated: Bool = false
    ) async -> ConfigApplicationOutcome {
        guard !self.isRemoteTarget, !self.isConfigMutationBusy else { return .skipped }
        if isUserInitiated {
            self.networkDriver?.userRequestedStart()
        }
        self.networkDriver?.ownTransitionBegan()
        self.coreActionState = .restarting
        self.configReadEpoch = UUID()
        defer {
            self.configReadEpoch = UUID()
            self.coreActionState = .idle
            self.flushDeferredCoreIntentIfNeeded()
        }
        self.cancelProviderRefresh(reason: "restart requested")
        do {
            guard let configPath = await self.resolveSelectedConfigPath() else {
                throw CocoaError(.fileNoSuchFile)
            }
            let outcome = try await self.launchSelectedConfig(
                path: configPath, restarting: true, candidate: candidate, commit: commit,
                options: CoreBootstrapOptions(
                    providerTrigger: trigger,
                    refreshProxyGroupsAfterBootstrap: true,
                    refreshSystemProxyBeforeOverlay: false,
                    refreshSystemProxyAfterBootstrap: true,
                    autoTestGroupLatencies: false))
            if self.isRuntimeRunning {
                self.networkDriver?.coreDidStart()
            }
            return outcome
        } catch {
            if Self.isCancellationLike(error) {
                self.logCoreCancellation("log.restart.cancelled")
                if self.isRuntimeRunning {
                    self.networkDriver?.coreDidStart()
                }
                return .failed
            }
            self.configApplicationFailure = self.configApplicationErrorMessage(error)
            let message = self.tr("log.restart.failed", self.configApplicationFailure ?? "")
            self.reportCoreRestartFailure(message: message, isUserInitiated: isUserInitiated)
            return .failed
        }
    }

    private func launchSelectedConfig(
        path: String, restarting: Bool, candidate staged: URL? = nil, commit: (() throws -> Void)? = nil,
        options: CoreBootstrapOptions
    ) async throws -> ConfigApplicationOutcome {
        let target = URL(fileURLWithPath: path)
        let replacement = staged == nil ? self.pendingRemoteConfigReplacements[target.lastPathComponent] : nil
        let originalData = replacement.flatMap { _ in try? Data(contentsOf: target) }
        defer {
            if let replacement, self.pendingRemoteConfigReplacements[target.lastPathComponent] == replacement {
                self.discardRemoteConfigReplacement(for: target, failed: true)
            }
        }
        let oldInput = self.runtimeConfigInput
        let oldPath = oldInput?.selectedPath ?? path
        let backup = self.lastLoadedConfigURL(for: oldPath)
        let recoveryPath = backup.flatMap { url in
            FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }
        let recoveryData = oldInput?.yaml.map { Data($0.utf8) } ?? (recoveryPath == nil ? originalData : nil)
        let currentSelection = self.configService.selectedConfig?.path
        let candidate = staged?.path ?? replacement?.file(beside: target).path ?? path
        let validation = await self.configValidationFailureDetails(configPath: candidate)
        guard currentSelection == self.configService.selectedConfig?.path else { throw ConfigApplicationError.stale }
        if let validation {
            if replacement == nil, staged == nil {
                self.handleConfigValidationFailure(configPath: path, details: validation)
            }
            if let oldInput, self.processManager.status == oldInput.status {
                self.restoreConfigSelection(oldPath)
                self.configApplicationFailure = validation
                return .failed
            }
            guard recoveryPath != nil || recoveryData != nil else { throw ConfigApplicationError.unverified }
        }

        let oldFile = URL(fileURLWithPath: oldPath)
        var preparedRecovery: URL?
        defer {
            if let preparedRecovery { try? FileManager.default.removeItem(at: preparedRecovery) }
        }
        func prepareRecoveryFile(_ data: Data) throws -> URL {
            let file = oldFile.deletingLastPathComponent().appendingPathComponent(".clashbar-\(UUID()).yaml")
            try ConfigImportService.writePrivateConfigData(data, to: file)
            return file
        }
        if let recoveryData, (try? Data(contentsOf: oldFile)) != recoveryData {
            do {
                preparedRecovery = try prepareRecoveryFile(recoveryData)
            } catch {
                if oldInput != nil { self.restoreConfigSelection(oldPath) }
                throw error
            }
        }
        let oldFields = await self.loadedConfigFields(for: oldInput)

        if restarting {
            await self.prepareCoreFeatureRecoveryBeforeCoreTransition(
                fallbackRecovery: self.currentCoreFeatureRecoverySnapshot(),
                transitionKind: .restart,
                disableRuntimeTunBeforeStop: false)
        }
        self.clearLoadedConfigState()
        self.statusText = "Starting"

        do {
            guard validation == nil else { throw ConfigApplicationError.unverified }
            try await self.launchConfig(
                candidate, selectedPath: path, restarting: restarting, replacing: replacement != nil)
            if let replacement {
                try self.requireConfigApplied()
                guard let originalData, (try? Data(contentsOf: target)) == originalData
                else { throw ConfigApplicationError.stale }
                try self.commitRemoteConfigReplacement(replacement, to: target)
            }
            if let commit {
                try self.requireConfigApplied()
                try commit()
            }
            await self.completeCoreBootstrap(configPath: path, options: options)
            return self.configApplicationOutcome
        } catch {
            if Self.isCancellationLike(error) {
                throw error
            }
            let failure = self.configApplicationErrorMessage(error)
            guard recoveryPath != nil || recoveryData != nil else {
                if (replacement != nil || staged != nil), self.processManager.isRunning {
                    await self.processManager.stop()
                }
                throw error
            }
            self.restoreConfigSelection(oldPath)
            do {
                if let recoveryData {
                    let recovery: URL
                    if (try? Data(contentsOf: oldFile)) == recoveryData {
                        recovery = oldFile
                    } else if let preparedRecovery {
                        recovery = preparedRecovery
                    } else {
                        recovery = try prepareRecoveryFile(recoveryData)
                        preparedRecovery = recovery
                    }
                    try await self.launchConfig(
                        recovery.path, selectedPath: oldPath, restarting: self.processManager.isRunning,
                        overrides: oldInput?.overrides)
                } else if let recoveryPath {
                    try await self.launchConfig(
                        recoveryPath, selectedPath: oldPath, restarting: self.processManager.isRunning)
                }
                try await self.requireRestoredConfig(matching: oldFields)
            } catch {
                self.clearLoadedConfigState()
                if self.processManager.isRunning { await self.processManager.stop() }
                throw ConfigApplicationError.recoveryFailed(failure + " " + self.configApplicationErrorMessage(error))
            }
            self.reportRestoredConfig(after: failure)
            await self.completeCoreBootstrap(configPath: oldPath, options: options)
            return .failed
        }
    }

    private func restoreConfigSelection(_ path: String) {
        let key = ConfigOverrides.pathKey(for: URL(fileURLWithPath: path))
        guard let config = self.configService.availableConfigs.first(where: { ConfigOverrides.pathKey(for: $0) == key })
        else { return }
        self.configService.selectConfig(config)
        _ = self.syncSelectedConfigSelection(config)
        self.syncConfigDisplayState()
    }

    private func launchConfig(
        _ path: String, selectedPath: String, restarting: Bool, replacing: Bool = false,
        overrides: [String: ConfigPatchValue]? = nil
    ) async throws {
        guard let yaml = RuntimeConfigInput.readYAML(at: path) else { throw CocoaError(.fileReadCorruptFile) }
        let controller = self.applyExternalControllerFromSelectedConfigFile(configPath: path)
        let status = try await (restarting
            ? self.processManager.restart(configPath: path, controller: controller)
            : self.processManager.start(configPath: path, controller: controller))
        do {
            guard RuntimeConfigInput.readYAML(at: path) == yaml else { throw ConfigApplicationError.stale }
            try await self.awaitConfigController(for: status)
            try await self.acknowledgeLoadedConfig(
                at: selectedPath, yaml: yaml, status: status, controller: controller,
                overrides: replacing ? [:] : overrides)
        } catch {
            if Self.isCancellationLike(error) {
                throw ConfigApplicationError.cancelled
            }
            if self.processManager.status == status {
                await self.processManager.stop()
            }
            throw error
        }
    }

    private func awaitConfigController(for status: CoreLifecycleStatus) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while self.processManager.status == status {
            do {
                let _: ConfigSnapshot = try await self.clientOrThrow().request(.getConfigs)
                return
            } catch {
                guard clock.now < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw ConfigApplicationError.stale
    }

    private func reportCoreRestartFailure(message: String, isUserInitiated: Bool) {
        if !self.processManager.isRunning {
            self.statusText = "Failed"
            self.apiStatus = .failed
            self.cancelPolling()
        }
        self.appendLog(level: NetworkLogSeverity.error.rawValue, message: message)
        self.presentCoreFailureAlert(
            title: self.tr("app.core.alert.restart_failed.title"),
            message: message,
            dedupeKey: "core-restart-failed",
            presentation: isUserInitiated ? .modal : .banner)
    }

    func performPrimaryCoreAction() async {
        guard !self.isConfigMutationBusy else { return }
        if isRuntimeRunning {
            await self.restartCore(isUserInitiated: true)
        } else {
            await self.startCore(trigger: .manual)
        }
    }

    nonisolated static func isCancellationLike(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let configError = error as? ConfigApplicationError, case .cancelled = configError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return Task.isCancelled
    }

    private func logCoreCancellation(_ logKey: String) {
        self.appendLog(level: NetworkLogSeverity.info.rawValue, message: self.tr(logKey))
    }

    func flushDeferredCoreIntentIfNeeded() {
        guard let intent = self.deferredCoreIntent else { return }
        guard !self.isConfigMutationBusy else { return }
        self.deferredCoreIntent = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch intent {
            case .running:
                await self.startCore(trigger: .manual)
            case .stopped:
                await self.stopCore(trigger: .manual)
            }
        }
    }

    func setUILanguage(_ language: AppLanguage) {
        guard uiLanguage != language else { return }
        uiLanguage = language
        defaults.set(language.rawValue, forKey: uiLanguageKey)
    }

    func setAppearanceMode(_ mode: AppAppearanceMode) {
        guard appearanceMode != mode else { return }
        appearanceMode = mode
        defaults.set(mode.rawValue, forKey: appearanceModeKey)
        self.applyAppAppearance()
    }

    func quitApp() async {
        self.prepareForTermination()
        self.isPanelPresented = false
        for window in NSApplication.shared.windows {
            window.orderOut(nil)
        }
        NSApplication.shared.terminate(nil)
    }

    func shutdownForTermination() {
        self.prepareForTermination()
        self.systemProxyService.clearBlocking(timeout: 0.35)
        if processManager.isRunning {
            self.processManager.stopImmediately()
        }
    }

    func cancelOwnedTasks() {
        self.deferredCoreIntent = nil
        if let observer = self.workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.workspaceWakeObserver = nil
        }
        self.stopNetworkReachabilityMonitoring()
        self.stopConfigDirectoryMonitoring()
        self.cancelProviderRefresh(reason: "quit requested")
        self.cancelPolling()
        self.stopRemoteConfigAutoUpdateTask()
        self.stopRemoteConfigMenuRefreshTimer()
        self.streamCoordinator.cancelAll()
        self.remoteMachineStore.stopPeriodicConnectivityChecks()
        self.ssidStrategyApplyTask?.cancel()
        self.ssidStrategyApplyTask = nil
        self.ssidMonitorService.stop()
        self.trafficDecodeTask?.cancel()
        self.trafficDecodeTask = nil
        self.mihomoLogFlushTask?.cancel()
        self.mihomoLogFlushTask = nil
        self.startupRefreshTask?.cancel()
        self.startupRefreshTask = nil
        self.autoStartTask?.cancel()
        self.autoStartTask = nil
        self.systemProxyExceptionsSaveTask?.cancel()
        self.pendingSystemProxyExceptionsSave = nil
        self.coreSettingsCommitTask?.cancel()
        self.coreSettingsCommitTask = nil
        self.coreSettingsImmediateEdits = [:]
        self.isCommittingCoreSettingImmediately = false
        self.settingsFeedbackClearTask?.cancel()
        self.settingsFeedbackClearTask = nil
        self.coreUpgradeFeedbackClearTask?.cancel()
        self.coreUpgradeFeedbackClearTask = nil
        self.geoUpdateFeedbackClearTask?.cancel()
        self.geoUpdateFeedbackClearTask = nil
    }

    private func prepareForTermination() {
        self.defaults.set(self.isSystemProxyEnabled, forKey: self.systemProxyEnabledOnQuitKey)
        self.cancelOwnedTasks()
        self.flushPendingMihomoLogsIfNeeded()
        // Bounded so a stalled disk write cannot hang the quit.
        let timeout: TimeInterval = 0.4
        self.clashbarLogStore?.flush(timeout: timeout)
        self.mihomoLogStore?.flush(timeout: timeout)
    }

    func applyAppAppearance() {
        let app = NSApplication.shared
        switch appearanceMode {
        case .system:
            app.appearance = nil
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func normalizeMode(_ raw: String?) -> CoreMode? {
        guard let raw else { return nil }
        return CoreMode(rawValue: raw.lowercased())
    }

    func configValidationFailureDetails(configPath: String) async -> String? {
        do {
            try await self.processManager.validateConfig(configPath: configPath)
            return nil
        } catch {
            let detailsRaw = self.coreErrorMessage(error).trimmingCharacters(in: .whitespacesAndNewlines)
            return detailsRaw.isEmpty ? tr("ui.common.unknown") : detailsRaw
        }
    }

    func handleConfigValidationFailure(configPath: String, details: String) {
        let fileName = URL(fileURLWithPath: configPath).lastPathComponent
        appendLog(level: "error", message: tr("log.config.validate_failed", fileName, details))
        self.presentConfigValidationFailedAlert(fileName: fileName, details: details)
    }

    func restartCoreIfNeededForConfigSwitch(previousPath: String?, nextPath: String?) async {
        guard let nextPath else { return }
        guard previousPath != nextPath else { return }
        guard processManager.isRunning else { return }

        clearProxyPresentation()
        appendLog(level: "info", message: tr("log.config.changed_restart"))
        cancelProviderRefresh(reason: "config switch requested")
        await self.restartCore(trigger: .configSwitch)
    }

    func refreshProxyGroupsAfterRestart() async {
        for _ in 0..<8 {
            await refreshProxyGroups()
            if apiStatus == .healthy {
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    func attemptAutoStartIfNeeded() async {
        if didAttemptAutoStart {
            return
        }
        didAttemptAutoStart = true
        await self.startCore(trigger: .auto)
    }

    private func completeCoreBootstrap(configPath: String, options: CoreBootstrapOptions) async {
        statusText = "Running"
        apiStatus = .healthy
        resetTrafficPresentation()
        ensureAPIClient()
        startPolling()
        await refreshFromAPI(includeSlowCalls: true)
        enqueueProviderRefresh(trigger: options.providerTrigger)

        if options.refreshProxyGroupsAfterBootstrap {
            await self.refreshProxyGroupsAfterRestart()
        }

        scheduleSystemProxyStartupPostflight(
            refreshStatusBeforeOverlay: options.refreshSystemProxyBeforeOverlay,
            refreshStatusAfterBootstrap: options.refreshSystemProxyAfterBootstrap)

        defaults.set(configPath, forKey: lastSuccessfulConfigPathKey)
        startupErrorMessage = nil
        await self.restoreCoreFeaturesAfterStartupIfNeeded()
        enforceNetworkManagedCorePolicyIfNeeded()

        if options.autoTestGroupLatencies {
            Task { [weak self] in
                await self?.refreshAllGroupLatencies()
            }
        }
    }

    private func currentCoreFeatureRecoverySnapshot() -> CoreFeatureRecoveryState {
        self.mergeCoreFeatureRecoveryStates(
            CoreFeatureRecoveryState(
                systemProxyEnabled: self.isSystemProxyEnabled,
                tunEnabled: self.isTunEnabled,
                tunConfigID: self.runningTunConfigID),
            self.pendingCoreFeatureRecoveryState)
    }

    private var runningTunConfigID: UUID? {
        if let path = self.runtimeConfigInput?.selectedPath {
            return self.configOverrides.identities[ConfigOverrides.pathKey(for: URL(fileURLWithPath: path))]
        }
        return self.activeConfigOverrideID
    }

    private func mergeCoreFeatureRecoveryStates(
        _ first: CoreFeatureRecoveryState?,
        _ second: CoreFeatureRecoveryState?) -> CoreFeatureRecoveryState
    {
        CoreFeatureRecoveryState(
            systemProxyEnabled: (first?.systemProxyEnabled ?? false) || (second?.systemProxyEnabled ?? false),
            tunEnabled: (first?.tunEnabled ?? false) || (second?.tunEnabled ?? false),
            tunConfigID: first?.tunEnabled == true ? first?.tunConfigID : second?.tunConfigID)
    }

    private func prepareCoreFeatureRecoveryBeforeCoreTransition(
        fallbackRecovery: CoreFeatureRecoveryState,
        transitionKind: CoreTransitionKind,
        disableRuntimeTunBeforeStop: Bool) async
    {
        let runtimeRunningBeforeTransition = self.isRuntimeRunning
        let capturedRecovery = CoreFeatureRecoveryState(
            systemProxyEnabled: runtimeRunningBeforeTransition && self.isSystemProxyEnabled,
            tunEnabled: runtimeRunningBeforeTransition && self.isTunEnabled,
            tunConfigID: self.runningTunConfigID)

        let baseRecovery: CoreFeatureRecoveryState = if capturedRecovery.shouldRecoverAnyFeature {
            capturedRecovery
        } else {
            fallbackRecovery
        }

        let recovery = self.mergeCoreFeatureRecoveryStates(baseRecovery, self.pendingCoreFeatureRecoveryState)
        self.pendingCoreFeatureRecoveryState = recovery.shouldRecoverAnyFeature ? recovery : nil
        self.didPresentTunRestoreFailureBanner = false

        if runtimeRunningBeforeTransition, recovery.tunEnabled {
            if transitionKind == .stop, disableRuntimeTunBeforeStop {
                do {
                    try await self.applyTunRuntimeChange(enabled: false)
                } catch {
                    self.appendLog(
                        level: "error",
                        message: self.tr("log.tun.toggle_failed", self.tunErrorMessage(error)))
                }
            }
            self.isTunEnabled = false
            self.appendLog(level: "info", message: self.tr("log.tun.toggled", self.tr("log.tun.disabled")))
        }

        guard self.isSystemProxyEnabled else { return }
        self.isProxySyncing = true
        defer { self.isProxySyncing = false }

        do {
            try await self.applySystemProxy(enabled: false, host: self.controllerHost(), ports: .disabled)
            self.isSystemProxyEnabled = false
            self.systemProxyActiveDisplay = nil
            self.clearSystemProxyOpenFailureHint()
            self.appendLog(
                level: "info",
                message: self.tr("log.system_proxy.toggled", self.tr("log.system_proxy.disabled")))
        } catch {
            self.appendLog(
                level: "error",
                message: self.tr("log.system_proxy.toggle_failed", self.systemProxyErrorMessage(error)))
            await self.refreshSystemProxyHelperStatus()
            await self.refreshSystemProxyStatus()
        }
    }

    func seedCoreFeatureRecoveryFromPersistedQuitState() {
        let wasSystemProxyEnabled = defaults.bool(forKey: systemProxyEnabledOnQuitKey)
        defaults.removeObject(forKey: systemProxyEnabledOnQuitKey)
        guard wasSystemProxyEnabled else { return }
        guard pendingCoreFeatureRecoveryState == nil else { return }
        pendingCoreFeatureRecoveryState = CoreFeatureRecoveryState(
            systemProxyEnabled: true,
            tunEnabled: false)
    }

    func restoreCoreFeaturesAfterStartupIfNeeded() async {
        guard let recovery = self.pendingCoreFeatureRecoveryState else { return }
        guard recovery.shouldRecoverAnyFeature else {
            self.pendingCoreFeatureRecoveryState = nil
            return
        }
        guard self.isRuntimeRunning else { return }

        if self.settledReachabilityStatus == .offline {
            return
        }

        var remainingSystemProxyRecovery = recovery.systemProxyEnabled

        if recovery.systemProxyEnabled {
            self.isProxySyncing = true
            defer { self.isProxySyncing = false }

            do {
                let target = try await self.resolveSystemProxyTargetFromRuntimeConfig()
                let isAlreadyConfigured = try await self.isSystemProxyConfigured(
                    host: target.host,
                    ports: target.ports)
                if !isAlreadyConfigured {
                    try await self.applySystemProxy(enabled: true, host: target.host, ports: target.ports)
                }
                self.isSystemProxyEnabled = true
                self.clearSystemProxyOpenFailureHint()
                self.systemProxyActiveDisplay = self.buildSystemProxyDisplayString(
                    host: target.host,
                    ports: target.ports)
                remainingSystemProxyRecovery = false
                self.appendLog(
                    level: "info",
                    message: self.tr("log.system_proxy.toggled", self.tr("log.system_proxy.enabled")))
            } catch {
                self.appendLog(
                    level: "error",
                    message: self.tr("log.system_proxy.toggle_failed", self.systemProxyErrorMessage(error)))
                self.updateSystemProxyOpenFailureHint(for: error)
                await self.refreshSystemProxyHelperStatus()
                await self.refreshSystemProxyStatus()
            }
        }

        var remainingTunRecovery = false
        if self.shouldRecoverTunForSelectedConfig {
            self.lastTunFailureWasPermanent = false
            let applied = await self.applyTunMode(true, requestPermissionsIfMissing: false)
            if applied {
                self.didPresentTunRestoreFailureBanner = false
            } else {
                remainingTunRecovery = !self.lastTunFailureWasPermanent
                if !self.didPresentTunRestoreFailureBanner {
                    self.didPresentTunRestoreFailureBanner = true
                    self.presentBackgroundBanner(StatusItemBanner(
                        symbolName: "exclamationmark.triangle.fill",
                        title: self.tr("ui.banner.tun_restore_failed.title"),
                        primaryDetail: self.tr("ui.banner.tun_restore_failed.detail"),
                        secondaryDetail: nil))
                }
            }
        }

        let remaining = CoreFeatureRecoveryState(
            systemProxyEnabled: remainingSystemProxyRecovery,
            tunEnabled: remainingTunRecovery,
            tunConfigID: recovery.tunConfigID)
        self.pendingCoreFeatureRecoveryState = remaining.shouldRecoverAnyFeature ? remaining : nil
    }
}
