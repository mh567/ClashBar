import Foundation

@MainActor
extension AppViewModel: NetworkCoreDriverHost {
    var networkPolicyConfiguration: NetworkCorePolicy.Configuration {
        NetworkCorePolicy.Configuration(
            autoStopEnabled: self.autoStopCoreOnNetworkLoss,
            autoStartEnabled: self.autoStartCoreOnNetworkRecovery,
            enabled: !self.isRemoteTarget)
    }

    var isCoreTransitionBlocked: Bool {
        self.isConfigMutationBusy
    }

    var currentReachability: NetworkReachabilityStatus {
        self.networkReachabilityMonitor.currentStatus
    }

    func performNetworkStart() async -> NetworkCoreDriver.Outcome {
        guard !self.isRemoteTarget, !self.isConfigMutationBusy else { return .skipped }
        await self.startCore(trigger: .networkRecovery)
        if self.lastCoreStartWasCancelled {
            return .skipped
        }
        guard self.isRuntimeRunning else {
            let message = self.configApplicationFailure ?? self.startupErrorMessage ?? ""
            return .failed(message: message)
        }
        return .started
    }

    func performNetworkStop() async -> NetworkCoreDriver.Outcome {
        guard !self.isRemoteTarget, !self.isConfigMutationBusy else { return .skipped }
        await self.stopCore(trigger: .networkLoss)
        return self.isRuntimeRunning ? .skipped : .stopped
    }

    func networkReachabilityDidSettle(_ status: NetworkReachabilityStatus) {
        self.settledReachabilityStatus = status
    }
}

@MainActor
extension AppViewModel {
    func enforceNetworkManagedCorePolicyIfNeeded() {
        self.networkDriver?.refreshCurrentReachability()
    }

    func updateNetworkReachabilityMonitoringState() {
        self.startNetworkReachabilityMonitoringIfNeeded()
        self.enforceNetworkManagedCorePolicyIfNeeded()
    }

    private func startNetworkReachabilityMonitoringIfNeeded() {
        guard !self.isNetworkReachabilityMonitoring else { return }
        self.isNetworkReachabilityMonitoring = true

        let initialDesiredState: CoreDesiredState = (self.autoStartCore || self.processManager.isRunning)
            ? .running
            : .stopped
        let driver = NetworkCoreDriver(host: self, initialDesiredState: initialDesiredState)
        self.networkDriver = driver

        self.networkReachabilityMonitor.start { [weak self] status in
            Task { @MainActor in
                self?.networkDriver?.handleReachability(status)
            }
        }
    }

    func stopNetworkReachabilityMonitoring() {
        self.networkDriver?.stop()
        self.networkDriver = nil

        if self.isNetworkReachabilityMonitoring {
            self.networkReachabilityMonitor.stop()
            self.isNetworkReachabilityMonitoring = false
        }

        self.settledReachabilityStatus = .unknown
    }

    func handleSystemDidWake() {
        self.networkReachabilityMonitor.refresh()
        self.networkDriver?.systemDidWake()
    }
}
