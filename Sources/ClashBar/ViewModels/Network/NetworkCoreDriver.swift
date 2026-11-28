import Foundation

@MainActor
protocol NetworkCoreDriverHost: AnyObject {
    var networkPolicyConfiguration: NetworkCorePolicy.Configuration { get }
    var isCoreTransitionBlocked: Bool { get }
    var currentReachability: NetworkReachabilityStatus { get }

    func performNetworkStart() async -> NetworkCoreDriver.Outcome
    func performNetworkStop() async -> NetworkCoreDriver.Outcome
    func presentNetworkBanner(_ kind: NetworkBannerKind)
    func logNetworkEvent(_ event: NetworkLogEvent)
    func networkReachabilityDidSettle(_ status: NetworkReachabilityStatus)
}

@MainActor
final class NetworkCoreDriver {
    enum Outcome: Equatable {
        case started
        case stopped
        case failed(message: String, retryable: Bool)
        case skipped
    }

    private enum Action {
        case start
        case stop
    }

    private weak var host: (any NetworkCoreDriverHost)?
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> Date

    private var policy: NetworkCorePolicy
    private var scheduledTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var isStopped = false
    private var isPerformingAction = false
    private var lastReportedReachability: NetworkReachabilityStatus

    init(
        host: any NetworkCoreDriverHost,
        initialDesiredState: CoreDesiredState,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping () -> Date = Date.init)
    {
        var policy = NetworkCorePolicy(configuration: host.networkPolicyConfiguration)
        policy.state.desiredState = initialDesiredState
        self.policy = policy
        self.host = host
        self.sleep = sleep
        self.now = now
        self.lastReportedReachability = policy.state.settledReachability
    }

    func handleReachability(_ status: NetworkReachabilityStatus) {
        self.dispatch(.reachabilityChanged(status))
    }

    func refreshCurrentReachability() {
        guard let host = self.host else { return }
        self.dispatch(.reachabilityChanged(host.currentReachability))
    }

    func coreDidStart() {
        self.dispatch(.coreDidStart)
    }

    func coreDidStop() {
        self.dispatch(.coreDidStop)
    }

    func coreCrashed() {
        self.dispatch(.coreCrashed)
    }

    func userRequestedStart() {
        self.dispatch(.userRequestedStart)
    }

    func userRequestedStop() {
        self.dispatch(.userRequestedStop)
    }

    func autoStartFailed(message: String, retryable: Bool) {
        self.dispatch(.autoStartFailed(message: message, retryable: retryable))
    }

    func systemDidWake() {
        self.dispatch(.systemDidWake)
    }

    func ownTransitionBegan() {
        self.dispatch(.ownTransitionBegan)
    }

    func stop() {
        self.isStopped = true
        self.scheduledTask?.cancel()
        self.scheduledTask = nil
        self.actionTask?.cancel()
        self.actionTask = nil
    }

    private func dispatch(_ event: NetworkCoreEvent) {
        guard !self.isStopped else { return }
        guard let host = self.host else { return }
        self.policy.updateConfiguration(host.networkPolicyConfiguration)
        let actions = self.policy.handle(event, now: self.now())
        self.reportSettledIfNeeded()
        self.apply(actions)
    }

    private func reportSettledIfNeeded() {
        let settled = self.policy.state.settledReachability
        guard settled != self.lastReportedReachability else { return }
        self.lastReportedReachability = settled
        self.host?.networkReachabilityDidSettle(settled)
    }

    private func apply(_ actions: [NetworkCoreAction]) {
        guard !actions.isEmpty, let host = self.host else { return }

        var scheduleDelay: TimeInterval?
        var shouldStart = false
        var shouldStop = false

        for action in actions {
            switch action {
            case let .presentBanner(kind):
                host.presentNetworkBanner(kind)
            case let .log(event):
                host.logNetworkEvent(event)
            case let .scheduleReevaluation(delay):
                scheduleDelay = min(scheduleDelay ?? delay, delay)
            case .startCore:
                shouldStart = true
            case .stopCore:
                shouldStop = true
            case .refreshReachability:
                self.dispatch(.reachabilityChanged(host.currentReachability))
                return
            }
        }

        if shouldStop {
            self.begin(.stop)
        }
        if shouldStart {
            self.begin(.start)
        }
        if let scheduleDelay {
            self.schedule(after: scheduleDelay)
        }
    }

    private func begin(_ action: Action) {
        guard let host = self.host else { return }
        guard !self.isPerformingAction else {
            self.dispatch(.actionSkipped)
            return
        }
        guard !host.isCoreTransitionBlocked else {
            self.dispatch(.actionSkipped)
            return
        }
        self.isPerformingAction = true
        self.actionTask = Task { [weak self] in
            guard let self else { return }
            let outcome: Outcome = switch action {
            case .start: await host.performNetworkStart()
            case .stop: await host.performNetworkStop()
            }
            guard !Task.isCancelled, !self.isStopped else { return }
            self.isPerformingAction = false
            switch outcome {
            case .started:
                self.dispatch(.coreDidStart)
            case .stopped:
                self.dispatch(.coreDidStop)
            case let .failed(message, retryable):
                self.dispatch(.autoStartFailed(message: message, retryable: retryable))
            case .skipped:
                self.dispatch(.actionSkipped)
            }
        }
    }

    private func schedule(after delay: TimeInterval) {
        self.scheduledTask?.cancel()
        let clamped = max(delay, 0.05)
        self.scheduledTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(clamped)
            } catch {
                return
            }
            guard !Task.isCancelled, !self.isStopped else { return }
            self.dispatch(.reevaluationFired)
        }
    }
}
