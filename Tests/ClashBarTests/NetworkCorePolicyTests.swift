import XCTest
@testable import ClashBar

@MainActor
final class NetworkCorePolicyTests: XCTestCase {
    private var base: Date {
        Date(timeIntervalSince1970: 1_000_000)
    }

    private func at(_ seconds: TimeInterval) -> Date {
        self.base.addingTimeInterval(seconds)
    }

    private func makePolicy(
        autoStop: Bool = true,
        autoStart: Bool = true,
        running: Bool = false,
        desired: CoreDesiredState = .running) -> NetworkCorePolicy
    {
        var policy = NetworkCorePolicy(configuration: .init(
            autoStopEnabled: autoStop,
            autoStartEnabled: autoStart))
        policy.state.desiredState = desired
        policy.state.isCoreRunning = running
        return policy
    }

    private func hasStart(_ actions: [NetworkCoreAction]) -> Bool {
        actions.contains(.startCore)
    }

    private func hasStop(_ actions: [NetworkCoreAction]) -> Bool {
        actions.contains(.stopCore)
    }

    private func scheduleDelay(_ actions: [NetworkCoreAction]) -> TimeInterval? {
        for action in actions {
            if case let .scheduleReevaluation(delay) = action {
                return delay
            }
        }
        return nil
    }

    private func retryDelay(_ actions: [NetworkCoreAction]) -> TimeInterval? {
        for action in actions {
            if case let .log(.autoStartRetry(_, delay, _)) = action {
                return delay
            }
        }
        return nil
    }

    func testBriefOfflineWithinDebounceDoesNotStopCore() {
        var policy = self.makePolicy(running: true)

        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(0))
        let actions = policy.handle(.reevaluationFired, now: self.at(4))

        XCTAssertFalse(self.hasStop(actions))
        XCTAssertEqual(self.scheduleDelay(actions) ?? -1, 1, accuracy: 0.01)
        XCTAssertEqual(policy.state.settledReachability, .unknown)
    }

    func testSustainedOfflineStopsCoreOnce() {
        var policy = self.makePolicy(running: true)

        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(0))
        let actions = policy.handle(.reevaluationFired, now: self.at(5))

        XCTAssertTrue(self.hasStop(actions))
        XCTAssertTrue(actions.contains(.presentBanner(.corePausedByNetworkLoss)))
        XCTAssertEqual(policy.state.settledReachability, .offline)

        let next = policy.handle(.reevaluationFired, now: self.at(8))
        XCTAssertFalse(self.hasStop(next))
    }

    func testFlappingDoesNotThrash() {
        var policy = self.makePolicy(running: true)
        var actions: [NetworkCoreAction] = []

        for index in 0..<20 {
            let status: NetworkReachabilityStatus = index.isMultiple(of: 2) ? .offline : .online
            actions += policy.handle(.reachabilityChanged(status), now: self.at(Double(index)))
            actions += policy.handle(.reevaluationFired, now: self.at(Double(index)))
        }

        XCTAssertFalse(self.hasStart(actions))
        XCTAssertFalse(self.hasStop(actions))
        XCTAssertEqual(policy.state.settledReachability, .unknown)
    }

    func testLongOfflineThenOnlineStartsCoreAndAnnounces() {
        var policy = self.makePolicy(running: true)

        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(0))
        let stopActions = policy.handle(.reevaluationFired, now: self.at(5))
        XCTAssertTrue(self.hasStop(stopActions))
        _ = policy.handle(.coreDidStop, now: self.at(5))

        let expired = policy.handle(.reevaluationFired, now: self.at(120))
        XCTAssertEqual(expired, [.refreshReachability])
        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(121))

        _ = policy.handle(.reachabilityChanged(.online), now: self.at(200))
        let pendingDelay = self.scheduleDelay(policy.handle(.reevaluationFired, now: self.at(201)))
        XCTAssertEqual(pendingDelay ?? -1, 2, accuracy: 0.01)

        let startActions = policy.handle(.reevaluationFired, now: self.at(203))
        XCTAssertTrue(self.hasStart(startActions))

        let didStart = policy.handle(.coreDidStart, now: self.at(203))
        XCTAssertTrue(didStart.contains(.presentBanner(.coreResumedAfterNetworkRecovery)))
    }

    func testUserStopWhileOfflinePreventsAutoStart() {
        var policy = self.makePolicy(running: true)

        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(0))
        _ = policy.handle(.reevaluationFired, now: self.at(5))
        _ = policy.handle(.coreDidStop, now: self.at(5))
        _ = policy.handle(.userRequestedStop, now: self.at(6))

        _ = policy.handle(.reevaluationFired, now: self.at(20))
        _ = policy.handle(.reachabilityChanged(.online), now: self.at(21))
        let actions = policy.handle(.reevaluationFired, now: self.at(24))

        XCTAssertFalse(self.hasStart(actions))
        XCTAssertEqual(policy.state.desiredState, .stopped)
    }

    func testUserStartWhileOfflineSuppressesAutoStopUntilOnline() {
        var policy = self.makePolicy(running: false, desired: .stopped)

        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(0))
        _ = policy.handle(.reevaluationFired, now: self.at(5))

        let userActions = policy.handle(.userRequestedStart, now: self.at(6))
        XCTAssertTrue(userActions.contains(.log(.userStartWhileOffline)))
        XCTAssertTrue(policy.state.offlineStopSuppressed)

        _ = policy.handle(.coreDidStart, now: self.at(6))
        XCTAssertFalse(self.hasStop(policy.handle(.reevaluationFired, now: self.at(20))))

        _ = policy.handle(.reevaluationFired, now: self.at(20))
        _ = policy.handle(.reachabilityChanged(.online), now: self.at(21))
        _ = policy.handle(.reevaluationFired, now: self.at(24))
        XCTAssertFalse(policy.state.offlineStopSuppressed)
    }

    func testAutoStartFailureBacksOffThenGoesQuiet() {
        var policy = self.makePolicy(running: false)

        _ = policy.handle(.reachabilityChanged(.online), now: self.at(0))
        _ = policy.handle(.reevaluationFired, now: self.at(3))

        let expectedDelays: [TimeInterval] = [2, 4, 8]
        for (index, delay) in expectedDelays.enumerated() {
            let actions = policy.handle(
                .autoStartFailed(message: "boom", retryable: true),
                now: self.at(Double(10 + index * 100)))
            XCTAssertEqual(self.retryDelay(actions) ?? -1, delay, accuracy: 0.01)
        }

        let gaveUp = policy.handle(.autoStartFailed(message: "boom", retryable: true), now: self.at(400))
        XCTAssertTrue(gaveUp.contains(.presentBanner(
            .coreAutoStartFailed(message: "boom", quietRetryInterval: 60))))

        let quiet = policy.handle(.autoStartFailed(message: "boom", retryable: true), now: self.at(500))
        XCTAssertEqual(self.retryDelay(quiet) ?? -1, 60, accuracy: 0.01)
    }

    func testDeterministicAutoStartFailureStopsRetrying() {
        var policy = self.makePolicy(running: false)
        _ = policy.handle(.reachabilityChanged(.online), now: self.at(0))
        _ = policy.handle(.reevaluationFired, now: self.at(3))

        let actions = policy.handle(
            .autoStartFailed(message: "port busy", retryable: false),
            now: self.at(10))

        XCTAssertTrue(actions.contains(.presentBanner(.coreAutoStartBlocked(message: "port busy"))))
        XCTAssertTrue(actions.contains(.log(.autoStartBlocked(message: "port busy"))))
        XCTAssertNil(self.retryDelay(actions))
        XCTAssertNil(policy.state.nextEligibleStartAt)
        XCTAssertEqual(policy.state.retryAttempt, 0)
    }

    func testUserRequestedStopEmitsStopCoreWhenRunning() {
        var policy = self.makePolicy(running: true)

        let actions = policy.handle(.userRequestedStop, now: self.at(0))

        XCTAssertTrue(self.hasStop(actions))
        XCTAssertEqual(policy.state.desiredState, .stopped)
    }

    func testUserRequestedStopDoesNotEmitWhenStopped() {
        var policy = self.makePolicy(running: false)

        XCTAssertFalse(self.hasStop(policy.handle(.userRequestedStop, now: self.at(0))))
    }

    func testActionSkippedDoesNotCountAsFailure() {
        var policy = self.makePolicy(running: false)

        _ = policy.handle(.reachabilityChanged(.online), now: self.at(0))
        _ = policy.handle(.reevaluationFired, now: self.at(3))
        let attempt = policy.state.retryAttempt

        let actions = policy.handle(.actionSkipped, now: self.at(4))

        XCTAssertEqual(policy.state.retryAttempt, attempt)
        XCTAssertFalse(self.hasStart(actions))
        XCTAssertNotNil(self.scheduleDelay(actions))
    }

    func testCoreCrashDoesNotAutoRestart() {
        var policy = self.makePolicy(running: false)

        _ = policy.handle(.reachabilityChanged(.online), now: self.at(0))
        _ = policy.handle(.reevaluationFired, now: self.at(3))
        _ = policy.handle(.coreDidStart, now: self.at(4))
        _ = policy.handle(.coreCrashed, now: self.at(5))
        XCTAssertEqual(policy.state.desiredState, .stopped)

        _ = policy.handle(.reevaluationFired, now: self.at(13))
        let actions = policy.handle(.reachabilityChanged(.online), now: self.at(14))
        XCTAssertFalse(self.hasStart(actions))
    }

    func testSuppressionWindowIgnoresOwnTransition() {
        var policy = self.makePolicy(running: true)

        _ = policy.handle(.coreDidStart, now: self.at(0))
        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(1))

        let early = policy.handle(.reevaluationFired, now: self.at(6))
        XCTAssertFalse(self.hasStop(early))
        XCTAssertEqual(self.scheduleDelay(early) ?? -1, 2, accuracy: 0.01)

        let expired = policy.handle(.reevaluationFired, now: self.at(8))
        XCTAssertEqual(expired, [.refreshReachability])
    }

    func testDisabledSettingsSuppressAutomaticActions() {
        var noStop = self.makePolicy(autoStop: false, running: true)
        _ = noStop.handle(.reachabilityChanged(.offline), now: self.at(0))
        XCTAssertFalse(self.hasStop(noStop.handle(.reevaluationFired, now: self.at(5))))

        var noStart = self.makePolicy(autoStart: false, running: false)
        _ = noStart.handle(.reachabilityChanged(.online), now: self.at(0))
        XCTAssertFalse(self.hasStart(noStart.handle(.reevaluationFired, now: self.at(3))))
    }

    func testWakeSettlesBeforeEvaluating() {
        var policy = self.makePolicy(running: true)

        let wake = policy.handle(.systemDidWake, now: self.at(0))
        XCTAssertEqual(self.scheduleDelay(wake) ?? -1, 4, accuracy: 0.01)

        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(0))
        let early = policy.handle(.reevaluationFired, now: self.at(2))
        XCTAssertFalse(self.hasStop(early))

        let expired = policy.handle(.reevaluationFired, now: self.at(4))
        XCTAssertEqual(expired, [.refreshReachability])
    }

    func testInitialOfflineDefersAutoStartUntilRecovery() {
        var policy = self.makePolicy(running: false, desired: .running)

        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(0))
        XCTAssertFalse(self.hasStart(policy.handle(.reevaluationFired, now: self.at(5))))

        _ = policy.handle(.reachabilityChanged(.online), now: self.at(10))
        XCTAssertTrue(self.hasStart(policy.handle(.reevaluationFired, now: self.at(13))))
    }

    func testOfflineDetectedDuringStartStopsCoreAfterTransition() {
        var policy = self.makePolicy(running: false, desired: .running)

        _ = policy.handle(.reachabilityChanged(.online), now: self.at(0))
        XCTAssertTrue(self.hasStart(policy.handle(.reevaluationFired, now: self.at(3))))

        _ = policy.handle(.reachabilityChanged(.offline), now: self.at(4))
        XCTAssertFalse(self.hasStop(policy.handle(.reevaluationFired, now: self.at(9))))

        _ = policy.handle(.coreDidStart, now: self.at(10))
        let expired = policy.handle(.reevaluationFired, now: self.at(18))
        XCTAssertEqual(expired, [.refreshReachability])

        let actions = policy.handle(.reachabilityChanged(.offline), now: self.at(19))
        XCTAssertTrue(self.hasStop(actions))
    }
}
