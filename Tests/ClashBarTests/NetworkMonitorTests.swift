import XCTest
@testable import ClashBar

private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NetworkReachabilityStatus] = []

    func append(_ status: NetworkReachabilityStatus) {
        self.lock.withLock { self.values.append(status) }
    }

    var snapshot: [NetworkReachabilityStatus] {
        self.lock.withLock { self.values }
    }
}

final class NetworkMonitorTests: XCTestCase {
    func testFakeMonitorTracksCurrentStatus() {
        let monitor = FakeNetworkReachabilityMonitor()
        let recorder = StatusRecorder()

        monitor.start { recorder.append($0) }
        monitor.emit(.offline)
        monitor.refresh()

        XCTAssertEqual(monitor.currentStatus, .offline)
        XCTAssertEqual(recorder.snapshot, [.offline, .offline])

        monitor.stop()
        XCTAssertFalse(monitor.isMonitoring)
    }
}
