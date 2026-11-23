import Foundation
@testable import ClashBar

final class FakeNetworkReachabilityMonitor: NetworkReachabilityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (NetworkReachabilityStatus) -> Void)?
    private var status: NetworkReachabilityStatus

    init(status: NetworkReachabilityStatus = .unknown) {
        self.status = status
    }

    var currentStatus: NetworkReachabilityStatus {
        self.lock.withLock { self.status }
    }

    var isMonitoring: Bool {
        self.lock.withLock { self.handler != nil }
    }

    func start(handler: @escaping @Sendable (NetworkReachabilityStatus) -> Void) {
        self.lock.withLock { self.handler = handler }
    }

    func stop() {
        self.lock.withLock { self.handler = nil }
    }

    func refresh() {
        let (handler, status) = self.lock.withLock { (self.handler, self.status) }
        handler?(status)
    }

    func emit(_ status: NetworkReachabilityStatus) {
        let handler = self.lock.withLock { () -> (@Sendable (NetworkReachabilityStatus) -> Void)? in
            self.status = status
            return self.handler
        }
        handler?(status)
    }
}
