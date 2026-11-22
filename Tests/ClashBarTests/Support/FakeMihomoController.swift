import Darwin
import Foundation

/// Minimal loopback HTTP server that answers as a Mihomo controller.
///
/// Exists so tests can drive the real `MihomoAPIService` path (URLSession, JSON
/// encoding, read-back verification) without launching a core, and without touching
/// the user's running instance on port 9090.
final class FakeMihomoController: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let body: String
    }

    private let lock = NSLock()
    private var config: [String: Any]
    private var recordedRequests: [Request] = []
    private var socket: Int32 = -1
    private var acceptThread: Thread?
    private(set) var port: Int = 0

    /// Requests seen so far, oldest first.
    var requests: [Request] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recordedRequests
    }

    /// Current simulated core config.
    var currentConfig: [String: Any] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.config
    }

    init(config: [String: Any]) {
        self.config = config
    }

    deinit {
        self.stop()
    }

    func start() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, length)
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(fd, raw, &length)
            }
        }

        self.socket = fd
        self.port = Int(UInt16(bigEndian: address.sin_port))

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
        self.acceptThread = thread
    }

    func stop() {
        let fd = self.socket
        guard fd >= 0 else { return }
        self.socket = -1
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        self.acceptThread = nil
    }

    private func acceptLoop() {
        while true {
            let fd = self.socket
            guard fd >= 0 else { return }
            let connection = Darwin.accept(fd, nil, nil)
            guard connection >= 0 else { return }
            self.serve(connection)
            Darwin.close(connection)
        }
    }

    private func serve(_ connection: Int32) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let count = Darwin.recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            request.append(contentsOf: buffer[0..<count])
            guard let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) else { continue }

            let headerData = request.subdata(in: request.startIndex..<headerEnd.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            let contentLength = header
                .split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0

            let bodyStart = headerEnd.upperBound
            if request.count - bodyStart < contentLength { continue }

            let bodyData = request.subdata(in: bodyStart..<(bodyStart + contentLength))
            let body = String(data: bodyData, encoding: .utf8) ?? ""
            let firstLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1]) : ""

            let (status, payload) = self.handle(Request(method: method, path: path, body: body))
            self.write(status: status, payload: payload, to: connection)
            return
        }
    }

    private func handle(_ request: Request) -> (Int, Any) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.recordedRequests.append(request)

        guard request.path == "/configs" else {
            return (404, ["message": "unsupported \(request.path)"])
        }
        switch request.method {
        case "GET":
            return (200, self.config)
        case "PATCH":
            guard let patch = try? JSONSerialization.jsonObject(with: Data(request.body.utf8))
                as? [String: Any]
            else { return (400, ["message": "bad json"]) }
            self.apply(patch)
            return (204, [:])
        default:
            return (405, ["message": "unsupported \(request.method)"])
        }
    }

    private func apply(_ patch: [String: Any]) {
        for (key, value) in patch {
            if key == "tun", let tun = value as? [String: Any] {
                var current = self.config["tun"] as? [String: Any] ?? [:]
                for (innerKey, innerValue) in tun {
                    current[innerKey] = innerValue
                }
                self.config["tun"] = current
            } else {
                self.config[key] = value
            }
        }
    }

    private func write(status: Int, payload: Any, to connection: Int32) {
        let body: Data
        if let dictionary = payload as? [String: Any], !dictionary.isEmpty {
            body = (try? JSONSerialization.data(withJSONObject: dictionary)) ?? Data()
        } else {
            body = Data()
        }
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "No Content")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        // send() may write fewer bytes than asked; loop until the response is out.
        try? out.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let written = Darwin.send(
                    connection, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard written > 0 else { return }
                sent += written
            }
        }
    }
}
