import Darwin
import Foundation
import ProxyHelperShared
import Security

typealias CoreProcessSnapshot = CoreProcessInfo

struct CorePortOwner: Equatable, Sendable {
    let pid: Int32
    let startTime: UInt64
    let executablePath: String?
}

enum CoreStartError: LocalizedError, Equatable, Sendable {
    case portConflict(controller: String, port: Int, owner: CorePortOwner?)
    case staleCoreTerminationFailed(pid: Int32, reason: String, helperOutdated: Bool)
    case binaryMissing(expectedDirectory: String)
    case configInvalid(reason: String)
    case permissionDenied(reason: String)
    case launchFailed(reason: String)

    /// Deterministic failures will not fix themselves on a timer, so automatic
    /// retries stop until the user acts.
    var isDeterministic: Bool {
        switch self {
        case .portConflict, .binaryMissing, .configInvalid, .permissionDenied,
             .staleCoreTerminationFailed:
            true
        case .launchFailed:
            false
        }
    }

    /// A failed config may be replaced by the previously loaded one, but a
    /// missing binary or an occupied port blocks any config equally.
    var allowsRecoveryByReloadingPreviousConfig: Bool {
        if case .configInvalid = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case let .portConflict(controller, port, owner):
            if let owner {
                let path = owner.executablePath ?? "unknown executable"
                return "Controller \(controller) port \(port) is already in use by pid \(owner.pid) (\(path)). "
                    + "Stop that process or change external-controller, then retry."
            }
            return "Controller \(controller) port \(port) is already in use. "
                + "Stop the process holding it or change external-controller, then retry."
        case let .staleCoreTerminationFailed(pid, reason, helperOutdated):
            let hint = helperOutdated
                ? " The privileged helper is outdated or missing; reinstall it before retrying."
                : ""
            return "Could not stop the previously launched mihomo process (pid \(pid)): \(reason)\(hint)"
        case let .binaryMissing(expectedDirectory):
            return "mihomo binary not found. Expected an executable named 'mihomo' in \(expectedDirectory)."
        case let .configInvalid(reason):
            return "The configuration could not be read: \(reason)"
        case let .permissionDenied(reason):
            return "Permission denied: \(reason)"
        case let .launchFailed(reason):
            return "Failed to launch mihomo: \(reason)"
        }
    }
}

enum CoreProcessTerminationError: LocalizedError, Equatable, Sendable {
    case identityMismatch(pid: Int32)
    case permissionDenied(pid: Int32, reason: String)
    case stillRunning(pid: Int32)

    var errorDescription: String? {
        switch self {
        case let .identityMismatch(pid):
            return "Process \(pid) no longer matches the recorded mihomo instance."
        case let .permissionDenied(pid, reason):
            return "Not allowed to terminate process \(pid): \(reason)"
        case let .stillRunning(pid):
            return "Process \(pid) is still running after SIGKILL."
        }
    }
}

protocol CoreProcessInspecting: Sendable {
    var bootIdentifier: String { get }
    func snapshot(pid: Int32) -> CoreProcessSnapshot?
}

protocol CoreProcessTerminating: Sendable {
    func terminate(_ process: CoreProcessInfo, gracePeriod: TimeInterval) throws
}

protocol CorePortOwnerResolving: Sendable {
    func owner(port: Int) -> CorePortOwner?
}

struct SystemCoreProcessInspector: CoreProcessInspecting {
    let bootIdentifier: String

    init(bootIdentifier: String = SystemCoreProcessInspector.readBootIdentifier()) {
        self.bootIdentifier = bootIdentifier
    }

    func snapshot(pid: Int32) -> CoreProcessSnapshot? {
        CoreProcessIdentity.snapshot(pid: pid)
    }

    static func readBootIdentifier() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else { return "unknown" }
        return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
    }
}

struct SystemCoreProcessTerminator: CoreProcessTerminating {
    private let helperClient = ProxyHelperProcessClient()

    func terminate(_ process: CoreProcessInfo, gracePeriod: TimeInterval) throws {
        guard let current = CoreProcessIdentity.snapshot(pid: process.pid) else { return }
        guard current.startTime == process.startTime else {
            throw CoreProcessTerminationError.identityMismatch(pid: process.pid)
        }
        if let expected = CoreProcessIdentity.normalizedPath(process.executablePath),
           CoreProcessIdentity.normalizedPath(current.executablePath) != expected
        {
            throw CoreProcessTerminationError.identityMismatch(pid: process.pid)
        }

        if current.uid == getuid() {
            guard CoreProcessIdentity.terminate(pid: process.pid, gracePeriod: gracePeriod) else {
                throw CoreProcessTerminationError.stillRunning(pid: process.pid)
            }
            return
        }

        try self.helperClient.terminate(process, gracePeriod: gracePeriod)
    }
}

struct SystemCorePortOwnerResolver: CorePortOwnerResolving {
    private let helperClient = ProxyHelperProcessClient()

    func owner(port: Int) -> CorePortOwner? {
        if let owner = Self.localOwner(port: port) { return owner }
        return self.helperClient.listenerOwner(port: port)
    }

    private static func localOwner(port: Int) -> CorePortOwner? {
        guard let pid = CoreProcessIdentity.listeningPIDs(port: port).first,
              let snapshot = CoreProcessIdentity.snapshot(pid: pid)
        else { return nil }
        return CorePortOwner(
            pid: pid,
            startTime: snapshot.startTime,
            executablePath: snapshot.executablePath)
    }
}

struct ProxyHelperProcessClient: Sendable {
    func terminate(_ process: CoreProcessInfo, gracePeriod: TimeInterval) throws {
        let result = try self.invoke(timeout: max(1, gracePeriod + 3)) { helper, completion in
            helper.terminateProcess(
                pid: process.pid,
                startTime: process.startTime,
                expectedExecutablePath: process.executablePath ?? "",
                gracePeriod: gracePeriod)
            { code, message in
                completion(.success((code, message)))
            }
        }

        switch ProxyHelperTerminationCode(rawValue: result.0) ?? .failed {
        case .success:
            return
        case .identityMismatch:
            throw CoreProcessTerminationError.identityMismatch(pid: process.pid)
        case .stillRunning:
            throw CoreProcessTerminationError.stillRunning(pid: process.pid)
        case .invalidRequest, .failed:
            throw CoreProcessTerminationError.permissionDenied(
                pid: process.pid,
                reason: result.1 ?? "Unknown helper error.")
        }
    }

    func listenerOwner(port: Int) -> CorePortOwner? {
        let result = try? self.invoke(timeout: 2) { helper, completion in
            helper.listenerOwner(port: port) { found, pid, startTime, path, _ in
                completion(.success((found, pid, startTime, path)))
            }
        }
        guard let result, result.0 else { return nil }
        return CorePortOwner(pid: result.1, startTime: result.2, executablePath: result.3)
    }

    private func invoke<Value: Sendable>(
        timeout: TimeInterval,
        _ body: @escaping (ProxyHelperProtocol, @escaping (Result<Value, Error>) -> Void) -> Void) throws
        -> Value
    {
        let connection = NSXPCConnection(
            machServiceName: ProxyHelperConstants.machServiceName,
            options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
        if let team = Self.signingTeamIdentifier(at: Bundle.main.bundleURL) {
            connection.setCodeSigningRequirement(
                "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        }
        connection.activate()
        defer { connection.invalidate() }

        let resultBox = HelperResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        guard let helper = connection.remoteObjectProxyWithErrorHandler({ error in
            resultBox.store(.failure(CoreProcessTerminationError.permissionDenied(
                pid: 0,
                reason: error.localizedDescription)))
            semaphore.signal()
        }) as? ProxyHelperProtocol else {
            throw CoreProcessTerminationError.permissionDenied(
                pid: 0,
                reason: "Unable to create helper proxy.")
        }

        body(helper) { result in
            resultBox.store(result)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw CoreProcessTerminationError.permissionDenied(
                pid: 0,
                reason: "Helper response timed out.")
        }
        return try resultBox.load().get()
    }

    private static func signingTeamIdentifier(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

private final class HelperResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error> = .failure(CoreProcessTerminationError.permissionDenied(
        pid: 0,
        reason: "No helper response."))

    func store(_ value: Result<Value, Error>) {
        self.lock.withLock { self.result = value }
    }

    func load() -> Result<Value, Error> {
        self.lock.withLock { self.result }
    }
}
