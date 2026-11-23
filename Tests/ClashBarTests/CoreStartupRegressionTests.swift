import Darwin
import XCTest
@testable import ClashBar

final class CoreStartupRegressionTests: XCTestCase {
    func testControllerListenerProbeIgnoresClosedConnectionOnPreviouslyListeningPort() throws {
        let endpoint = try Self.makeListener()
        let client = try Self.connect(to: endpoint.port)
        let accepted = Darwin.accept(endpoint.socket, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        Darwin.close(endpoint.socket)
        _ = Darwin.shutdown(accepted, SHUT_WR)
        Darwin.close(accepted)
        Darwin.close(client)

        XCTAssertFalse(MihomoProcessManager.controllerPortHasListener("0.0.0.0:\(endpoint.port)"))
    }

    func testControllerListenerProbeDetectsAnActiveListener() throws {
        let endpoint = try Self.makeListener()
        defer { Darwin.close(endpoint.socket) }

        XCTAssertTrue(MihomoProcessManager.controllerPortHasListener("0.0.0.0:\(endpoint.port)"))
    }

    func testControllerPortAvailabilityStillRejectsAnActiveListener() throws {
        let endpoint = try Self.makeListener()
        defer { Darwin.close(endpoint.socket) }

        XCTAssertThrowsError(try MihomoProcessManager.checkControllerPortAvailability("0.0.0.0:\(endpoint.port)")) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EADDRINUSE)
        }
    }

    func testAutomaticCoreStartFailureDoesNotPresentAModalAlert() {
        XCTAssertFalse(StartTrigger.auto.shouldPresentFailureModal)
        XCTAssertTrue(StartTrigger.manual.shouldPresentFailureModal)
        XCTAssertFalse(StartTrigger.networkRecovery.shouldPresentFailureModal)
    }

    private static func makeListener() throws -> (socket: Int32, port: Int) {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(socket, socketAddress, length) == 0,
                      Darwin.listen(socket, 1) == 0
                else { return Int32(-1) }
                return getsockname(socket, socketAddress, &length)
            }
        }
        guard result == 0 else {
            Darwin.close(socket)
            throw POSIXError(.EADDRINUSE)
        }
        return (socket, Int(UInt16(bigEndian: address.sin_port)))
    }

    private static func connect(to port: Int) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(socket, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(socket)
            throw POSIXError(.ECONNREFUSED)
        }
        return socket
    }
}
