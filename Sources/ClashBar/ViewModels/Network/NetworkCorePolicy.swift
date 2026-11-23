import Foundation

enum CoreDesiredState: Equatable {
    case running
    case stopped
}

enum NetworkBannerKind: Equatable {
    case corePausedByNetworkLoss
    case coreResumedAfterNetworkRecovery
    case coreAutoStartFailed(message: String, quietRetryInterval: TimeInterval)
}

enum NetworkLogSeverity: String {
    case info
    case warning
    case error
}

enum NetworkLogEvent: Equatable {
    case offlineConfirmed(seconds: TimeInterval)
    case onlineConfirmed(seconds: TimeInterval)
    case autoStartRetry(attempt: Int, delay: TimeInterval, message: String)
    case autoStartGaveUp(interval: TimeInterval)
    case userStartWhileOffline
    case suppressedTransition
}

enum NetworkCoreEvent: Equatable {
    case reachabilityChanged(NetworkReachabilityStatus)
    case reevaluationFired
    case coreDidStart
    case coreDidStop
    case coreCrashed
    case userRequestedStart
    case userRequestedStop
    case autoStartFailed(message: String)
    case systemDidWake
    case ownTransitionBegan
    case actionSkipped
}

enum NetworkCoreAction: Equatable {
    case startCore
    case stopCore
    case presentBanner(NetworkBannerKind)
    case log(NetworkLogEvent)
    case scheduleReevaluation(after: TimeInterval)
    case refreshReachability
}

@MainActor
struct NetworkCorePolicy {
    struct Configuration: Equatable {
        var offlineDebounce: TimeInterval = 5
        var onlineDebounce: TimeInterval = 3
        var transitionSuppression: TimeInterval = 8
        var wakeSettle: TimeInterval = 4
        var startRetryDelays: [TimeInterval] = [2, 4, 8, 15, 30, 60]
        var quietRetryInterval: TimeInterval = 60
        var maxLoudRetries: Int = 4
        var autoStopEnabled: Bool = true
        var autoStartEnabled: Bool = true
        var enabled: Bool = true
    }

    struct State: Equatable {
        var rawReachability: NetworkReachabilityStatus = .unknown
        var settledReachability: NetworkReachabilityStatus = .unknown
        var candidateStatus: NetworkReachabilityStatus?
        var candidateSince: Date?
        var desiredState: CoreDesiredState = .running
        var isCoreRunning = false
        var suppressionUntil: Date?
        var retryAttempt = 0
        var nextEligibleStartAt: Date?
        var offlineStopSuppressed = false
        var didAnnouncePause = false
        var shouldAnnounceResume = false
        var isActionInFlight = false
    }

    var configuration: Configuration
    var state: State

    init(configuration: Configuration = Configuration(), state: State = State()) {
        self.configuration = configuration
        self.state = state
    }

    mutating func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    mutating func handle(_ event: NetworkCoreEvent, now: Date) -> [NetworkCoreAction] {
        switch event {
        case let .reachabilityChanged(status):
            return self.handleReachability(status, now: now)
        case .reevaluationFired:
            return self.handleReevaluation(now: now)
        case .coreDidStart:
            return self.handleCoreDidStart(now: now)
        case .coreDidStop:
            self.state.isCoreRunning = false
            self.state.isActionInFlight = false
            self.state.suppressionUntil = now.addingTimeInterval(self.configuration.transitionSuppression)
            return [.scheduleReevaluation(after: self.configuration.transitionSuppression)]
        case .coreCrashed:
            self.state.desiredState = .stopped
            self.state.isCoreRunning = false
            self.state.isActionInFlight = false
            self.state.suppressionUntil = now.addingTimeInterval(self.configuration.transitionSuppression)
            return [.scheduleReevaluation(after: self.configuration.transitionSuppression)]
        case .userRequestedStart:
            self.state.desiredState = .running
            self.state.retryAttempt = 0
            self.state.nextEligibleStartAt = nil
            self.state.shouldAnnounceResume = false
            let isOffline = self.state.settledReachability == .offline
                || (self.state.settledReachability == .unknown && self.state.rawReachability == .offline)
            guard isOffline else { return [] }
            self.state.offlineStopSuppressed = true
            return [.log(.userStartWhileOffline)]
        case .userRequestedStop:
            self.state.desiredState = .stopped
            self.state.retryAttempt = 0
            self.state.nextEligibleStartAt = nil
            self.state.offlineStopSuppressed = false
            self.state.shouldAnnounceResume = false
            guard self.state.isCoreRunning, !self.state.isActionInFlight else { return [] }
            self.state.isActionInFlight = true
            return [.stopCore]
        case let .autoStartFailed(message):
            return self.handleAutoStartFailure(message: message, now: now)
        case .systemDidWake:
            self.state.suppressionUntil = now.addingTimeInterval(self.configuration.wakeSettle)
            return [.scheduleReevaluation(after: self.configuration.wakeSettle)]
        case .ownTransitionBegan:
            self.state.suppressionUntil = now.addingTimeInterval(self.configuration.transitionSuppression)
            return [
                .log(.suppressedTransition),
                .scheduleReevaluation(after: self.configuration.transitionSuppression),
            ]
        case .actionSkipped:
            self.state.isActionInFlight = false
            return [.scheduleReevaluation(after: 0.5)]
        }
    }

    private func debounce(for status: NetworkReachabilityStatus) -> TimeInterval {
        switch status {
        case .offline: self.configuration.offlineDebounce
        case .online: self.configuration.onlineDebounce
        case .unknown: 0
        }
    }

    private mutating func handleReachability(
        _ status: NetworkReachabilityStatus,
        now: Date) -> [NetworkCoreAction]
    {
        guard status != .unknown else { return [] }
        self.state.rawReachability = status
        if status == self.state.settledReachability {
            self.state.candidateStatus = nil
            self.state.candidateSince = nil
            return self.reconcile(now: now, announceResume: false)
        }
        if self.state.candidateStatus == status, let since = self.state.candidateSince {
            let remaining = max(0, self.debounce(for: status) - now.timeIntervalSince(since))
            return [.scheduleReevaluation(after: remaining)]
        }
        self.state.candidateStatus = status
        self.state.candidateSince = now
        return [.scheduleReevaluation(after: self.debounce(for: status))]
    }

    private mutating func handleReevaluation(now: Date) -> [NetworkCoreAction] {
        if let until = self.state.suppressionUntil {
            if now < until {
                return [.scheduleReevaluation(after: until.timeIntervalSince(now))]
            }
            self.state.suppressionUntil = nil
            return [.refreshReachability]
        }
        if let status = self.state.candidateStatus, let since = self.state.candidateSince {
            let required = self.debounce(for: status)
            let elapsed = now.timeIntervalSince(since)
            if elapsed < required {
                return [.scheduleReevaluation(after: required - elapsed)]
            }
            self.state.candidateStatus = nil
            self.state.candidateSince = nil
            guard status != self.state.settledReachability else { return [] }
            self.state.settledReachability = status
            return self.applySettled(status, now: now)
        }
        return self.reconcile(now: now, announceResume: false)
    }

    private mutating func applySettled(
        _ status: NetworkReachabilityStatus,
        now: Date) -> [NetworkCoreAction]
    {
        var actions: [NetworkCoreAction] = []
        switch status {
        case .unknown:
            return []
        case .offline:
            actions.append(.log(.offlineConfirmed(seconds: self.configuration.offlineDebounce)))
        case .online:
            self.state.offlineStopSuppressed = false
            self.state.retryAttempt = 0
            self.state.nextEligibleStartAt = nil
            self.state.didAnnouncePause = false
            if !self.state.isCoreRunning {
                actions.append(.log(.onlineConfirmed(seconds: self.configuration.onlineDebounce)))
            }
        }
        actions.append(contentsOf: self.reconcile(now: now, announceResume: status == .online))
        return actions
    }

    private mutating func reconcile(now: Date, announceResume: Bool) -> [NetworkCoreAction] {
        switch self.state.settledReachability {
        case .unknown:
            return []
        case .offline:
            guard self.configuration.enabled,
                  self.configuration.autoStopEnabled,
                  self.state.desiredState == .running,
                  self.state.isCoreRunning,
                  !self.state.offlineStopSuppressed,
                  !self.state.isActionInFlight
            else { return [] }
            self.state.isActionInFlight = true
            var actions: [NetworkCoreAction] = [.stopCore]
            if !self.state.didAnnouncePause {
                self.state.didAnnouncePause = true
                actions.append(.presentBanner(.corePausedByNetworkLoss))
            }
            return actions
        case .online:
            guard self.configuration.enabled,
                  self.configuration.autoStartEnabled,
                  self.state.desiredState == .running,
                  !self.state.isCoreRunning,
                  !self.state.isActionInFlight
            else { return [] }
            if let next = self.state.nextEligibleStartAt, now < next {
                return [.scheduleReevaluation(after: next.timeIntervalSince(now))]
            }
            self.state.isActionInFlight = true
            self.state.shouldAnnounceResume = announceResume
            return [.startCore]
        }
    }

    private mutating func handleCoreDidStart(now: Date) -> [NetworkCoreAction] {
        self.state.isCoreRunning = true
        self.state.isActionInFlight = false
        self.state.retryAttempt = 0
        self.state.nextEligibleStartAt = nil
        self.state.didAnnouncePause = false
        self.state.suppressionUntil = now.addingTimeInterval(self.configuration.transitionSuppression)
        var actions: [NetworkCoreAction] = []
        if self.state.shouldAnnounceResume {
            self.state.shouldAnnounceResume = false
            actions.append(.presentBanner(.coreResumedAfterNetworkRecovery))
        }
        actions.append(.scheduleReevaluation(after: self.configuration.transitionSuppression))
        return actions
    }

    private mutating func handleAutoStartFailure(message: String, now: Date) -> [NetworkCoreAction] {
        self.state.isActionInFlight = false
        self.state.shouldAnnounceResume = false
        self.state.retryAttempt += 1
        let attempt = self.state.retryAttempt
        let delay: TimeInterval
        if attempt <= self.configuration.maxLoudRetries, !self.configuration.startRetryDelays.isEmpty {
            let index = min(attempt, self.configuration.startRetryDelays.count) - 1
            delay = self.configuration.startRetryDelays[max(index, 0)]
        } else {
            delay = self.configuration.quietRetryInterval
        }
        self.state.nextEligibleStartAt = now.addingTimeInterval(delay)

        var actions: [NetworkCoreAction] = []
        if attempt == self.configuration.maxLoudRetries {
            actions.append(.presentBanner(.coreAutoStartFailed(
                message: message,
                quietRetryInterval: self.configuration.quietRetryInterval)))
            actions.append(.log(.autoStartGaveUp(interval: self.configuration.quietRetryInterval)))
        } else {
            actions.append(.log(.autoStartRetry(attempt: attempt, delay: delay, message: message)))
        }
        if self.state.settledReachability == .online, self.state.desiredState == .running {
            actions.append(.scheduleReevaluation(after: delay))
        }
        return actions
    }
}
