import Darwin
import Foundation

public struct CoreProcessInfo: Equatable, Sendable {
    public let pid: Int32
    public let startTime: UInt64
    public let executablePath: String?
    public let uid: UInt32

    public init(pid: Int32, startTime: UInt64, executablePath: String?, uid: UInt32) {
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
        self.uid = uid
    }
}

public enum ProxyHelperTerminationCode: Int32, Sendable {
    case success = 0
    case invalidRequest = 1
    case identityMismatch = 2
    case stillRunning = 3
    case failed = 4
}

public enum CoreProcessIdentity {
    public static func snapshot(pid: Int32) -> CoreProcessInfo? {
        guard pid > 0 else { return nil }

        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let executablePath = pathLength > 0
            ? String(
                decoding: pathBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                as: UTF8.self)
            : nil
        let startTime = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        return CoreProcessInfo(
            pid: pid,
            startTime: startTime,
            executablePath: executablePath,
            uid: info.pbi_ruid)
    }

    public static func normalizedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public static func isRunning(pid: Int32) -> Bool {
        guard Darwin.kill(pid, 0) == 0 else { return errno != ESRCH }
        return true
    }

    /// Sends SIGTERM, waits for the grace period, then SIGKILL. Returns true
    /// when the process is gone.
    @discardableResult
    public static func terminate(pid: Int32, gracePeriod: TimeInterval) -> Bool {
        _ = Darwin.kill(pid, SIGTERM)
        if self.waitUntilGone(pid, timeout: max(0, gracePeriod)) { return true }
        _ = Darwin.kill(pid, SIGKILL)
        return self.waitUntilGone(pid, timeout: 1.0)
    }

    /// Scans `lsof` for TCP listeners on `port`. Root-owned listeners are only
    /// visible when the caller is root, so an empty result can mean "unknown".
    public static func listeningPIDs(port: Int) -> [Int32] {
        guard (1...65_535).contains(port) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return []
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output
            .components(separatedBy: .newlines)
            .compactMap { line in
                guard line.hasPrefix("p") else { return nil }
                return Int32(line.dropFirst())
            }
    }

    private static func waitUntilGone(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !self.isRunning(pid: pid) { return true }
            usleep(50_000)
        }
        return !self.isRunning(pid: pid)
    }
}
