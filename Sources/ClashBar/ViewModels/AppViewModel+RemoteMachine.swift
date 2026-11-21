import Foundation

@MainActor
extension AppViewModel {
    func switchToMachineTarget(_ target: MachineTarget) async {
        guard !self.isConfigMutationBusy else { return }
        let previous = self.remoteMachineStore.activeTarget
        if case let .remote(machine) = target {
            let status = await self.remoteMachineStore.refreshConnectivity(for: machine)
            guard status.isConnected else { return }
        }

        guard !self.isConfigMutationBusy, self.remoteMachineStore.activeTarget == previous else { return }
        if previous != target {
            self.discardCoreSettings()
        }
        self.configReadEpoch = UUID()
        self.remoteMachineStore.selectTarget(target)

        self.cancelPolling()
        self.resetTrafficPresentation()
        self.clearAllLogs()
        self.clearProxyPresentation()
        self.ruleItems = []
        self.connectionsStore.connections = []
        self.connectionsStore.connectionsCount = 0

        switch target {
        case .local:
            self.appendLog(level: "info", message: self.tr("log.remote.switched_to_local"))
            if let input = self.runtimeConfigInput, input.status == self.processManager.status {
                self.restoreLoadedController(input)
            } else if let configPath = await self.resolveSelectedConfigPath() {
                self.applyExternalControllerFromSelectedConfigFile(configPath: configPath)
            } else {
                let fallback = "127.0.0.1:9090"
                self.controller = fallback
                self.controllerSecret = nil
                self.externalControllerDisplay = fallback
                self.localExternalControllerDisplay = fallback
                self.applyExternalUIConfiguration(hasURL: false, name: nil)
                self.ensureAPIClient()
            }

            if let snapshot = self.loadPersistedEditableSettingsSnapshot() {
                self.applyEditableSettingsSnapshotToUI(snapshot)
            }
            self.lastSyncedEditableSettings = nil

        case let .remote(machine):
            self.appendLog(
                level: "info",
                message: self.tr("log.remote.switched_to_remote", machine.name, machine.displayAddress))
            self.controller = machine.controllerAddress
            self.controllerSecret = machine.secret
            self.externalControllerDisplay = machine.displayAddress
            self.applyExternalUIConfiguration(hasURL: false, name: nil)
            self.ensureAPIClient()
            self.lastSyncedEditableSettings = nil
        }

        await self.refreshFromAPI(includeSlowCalls: true)

        if self.lastSyncedEditableSettings == nil {
            _ = try? await self.fetchRuntimeConfigSnapshot()
        }

        if case .local = target {
            self.refreshSSIDStrategyState(requestAuthorizationIfNeeded: self.ssidStrategyEnabled)
            await self.applySSIDStrategyForCurrentSSIDIfNeeded()
        }

        switch target {
        case .remote:
            self.statusText = (self.apiStatus == .healthy || self.apiStatus == .degraded)
                ? "Running" : "Stopped"
        case .local:
            if !self.processManager.isRunning {
                self.statusText = "Stopped"
            }
        }

        if self.apiStatus == .healthy || self.apiStatus == .degraded {
            self.startPolling()
        }
    }
}
