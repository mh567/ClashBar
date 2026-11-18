import Darwin
import Foundation

/// Version helpers for the managed and bundled mihomo payloads.
///
/// The bundled payload inside the app bundle can be older than the core the user
/// already upgraded locally. Resolution always keeps whichever build is newer so
/// an app update never downgrades a managed core and a bundled upgrade still wins.
enum MihomoCoreVersion {
    static let bundledVersionFileName = "mihomo.version"

    static func parse(_ raw: String) -> AppSemanticVersion? {
        AppSemanticVersion(raw)
    }

    /// Extracts the mihomo build version from `mihomo -v` output, for example
    /// `Mihomo Meta v1.19.34 darwin arm64 with go1.22.12`.
    static func extract(from output: String) -> AppSemanticVersion? {
        if let match = Self.firstMatch(in: output, pattern: #"[vV]\d+(?:\.\d+)+"#) {
            return AppSemanticVersion(match)
        }
        if let match = Self.firstMatch(in: output, pattern: #"\b\d+\.\d+\.\d+\b"#) {
            return AppSemanticVersion(match)
        }
        return nil
    }

    static func readVersionFile(at url: URL) -> AppSemanticVersion? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.extract(from: contents)
    }

    /// Runs `mihomo -v` and parses the build version. Returns nil when the binary
    /// cannot be launched, does not exit in time, or prints no version.
    static func probe(at path: String, timeout: TimeInterval = 2) -> AppSemanticVersion? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-v"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20000)
        }
        if process.isRunning {
            process.terminate()
            usleep(100000)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Self.extract(from: String(decoding: data, as: UTF8.self))
    }

    /// True when installing the bundled payload would upgrade (or recover) the
    /// managed binary. Equal or older bundled payloads never replace a newer core.
    static func shouldPreferBundled(
        managed: AppSemanticVersion?,
        bundled: AppSemanticVersion?) -> Bool
    {
        guard let bundled else { return false }
        guard let managed else { return true }
        return bundled > managed
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text)
        else {
            return nil
        }
        return String(text[swiftRange])
    }
}
