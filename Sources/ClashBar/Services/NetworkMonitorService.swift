import Foundation
import Network

enum NetworkReachabilityStatus: Equatable {
    case unknown
    case online
    case offline

    init(pathStatus: NWPath.Status) {
        if pathStatus == .satisfied {
            self = .online
        } else {
            self = .offline
        }
    }
}

protocol NetworkReachabilityMonitoring: AnyObject, Sendable {
    var currentStatus: NetworkReachabilityStatus { get }
    func start(handler: @escaping @Sendable (NetworkReachabilityStatus) -> Void)
    func stop()
    func refresh()
}

final class NetworkReachabilityMonitor: NetworkReachabilityMonitoring, @unchecked Sendable {
    typealias StatusHandler = @Sendable (NetworkReachabilityStatus) -> Void

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var monitor: NWPathMonitor?
    private var handler: StatusHandler?
    private var latestStatus: NetworkReachabilityStatus = .unknown

    init(queue: DispatchQueue = DispatchQueue(label: "com.clashbar.network-reachability", qos: .utility)) {
        self.queue = queue
    }

    deinit {
        self.stop()
    }

    var currentStatus: NetworkReachabilityStatus {
        self.lock.withLock { self.latestStatus }
    }

    func start(handler: @escaping StatusHandler) {
        self.stop()
        self.lock.withLock {
            self.handler = handler
            self.latestStatus = .unknown
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status = NetworkReachabilityStatus(pathStatus: path.status)
            let handler = self.lock.withLock { () -> StatusHandler? in
                self.latestStatus = status
                return self.handler
            }
            handler?(status)
        }
        monitor.start(queue: self.queue)
        self.lock.withLock { self.monitor = monitor }
    }

    func refresh() {
        let (status, handler) = self.lock.withLock {
            (self.latestStatus, self.handler)
        }
        handler?(status)
    }

    func stop() {
        let monitor = self.lock.withLock { () -> NWPathMonitor? in
            let monitor = self.monitor
            self.monitor = nil
            self.handler = nil
            self.latestStatus = .unknown
            return monitor
        }
        monitor?.cancel()
    }
}
