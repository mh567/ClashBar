import CryptoKit
import Darwin
import Foundation

enum AppUpdateInstallPhase: Sendable, Equatable {
    case downloading(progress: Double?)
    case verifying
    case installing
    case relaunching
}

struct AppUpdateRelaunchOutcome: Codable, Equatable {
    enum Result: String, Codable {
        case succeeded
        case timedOut
        case openFailed
        case rolledBack
    }

    let result: Result
    let installedVersion: String
    let previousVersion: String
    let date: Date
}

enum AppUpdateInstaller {
    /// Which step failed. `install_failed` alone cannot tell a blocked download from a
    /// rejected code signature, and the update UI shows one message for all of them, so the
    /// step travels with the error and goes into the log.
    enum Stage: String, Sendable {
        case download
        case verifyChecksum
        case verifyBundle
        case stageImage
        case replaceBundle
        case scheduleRelaunch
    }

    enum Failure: Error {
        case incompatibleAsset
        case nonWritableInstallation
        case download
        case verification
        case command(String)
        case replacement
        case staged(Stage, underlying: String)
    }

    static var architecture: String {
        #if arch(arm64)
            "apple-silicon"
        #else
            "intel"
        #endif
    }

    static func asset(for release: AppReleaseInfo, bundlesCore: Bool) -> AppReleaseInfo.Asset? {
        release.installableAsset(architecture: self.architecture, bundlesCore: bundlesCore)
    }

    static func relaunchOutcomeURL() -> URL {
        WorkingDirectoryManager()
            .stateDirectoryURL
            .appendingPathComponent("app-update-relaunch.json", isDirectory: false)
    }

    static func readRelaunchOutcome(
        at url: URL = AppUpdateInstaller.relaunchOutcomeURL()
    ) -> AppUpdateRelaunchOutcome? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(AppUpdateRelaunchOutcome.self, from: data)
    }

    @discardableResult
    static func consumeRelaunchOutcome(
        at url: URL = AppUpdateInstaller.relaunchOutcomeURL()) -> AppUpdateRelaunchOutcome?
    {
        let outcome = self.readRelaunchOutcome(at: url)
        try? FileManager.default.removeItem(at: url)
        return outcome
    }

    @concurrent
    static func install(
        _ release: AppReleaseInfo,
        bundlesCore: Bool,
        onPhase: @escaping @Sendable (AppUpdateInstallPhase) -> Void) async throws
    {
        let files = FileManager.default
        let bundle = Bundle.main
        let installed = bundle.bundleURL.standardizedFileURL
        let parent = installed.deletingLastPathComponent()
        let userApplications = files.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        guard installed.pathExtension == "app",
              ["/Applications", userApplications].contains(parent.path),
              installed.resolvingSymlinksInPath().path == installed.path,
              files.isWritableFile(atPath: parent.path),
              files.isWritableFile(atPath: installed.path),
              let installedID = bundle.bundleIdentifier
        else { throw Failure.nonWritableInstallation }

        guard let asset = self.asset(for: release, bundlesCore: bundlesCore),
              let expectedHash = asset.sha256
        else { throw Failure.incompatibleAsset }

        let previousVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        onPhase(.downloading(progress: 0))

        let download = files.temporaryDirectory
            .appendingPathComponent("clashbar-update-\(UUID().uuidString).dmg", isDirectory: false)
        defer { try? files.removeItem(at: download) }

        var request = URLRequest(url: asset.downloadURL)
        request.timeoutInterval = 30
        let response: URLResponse?
        do {
            response = try await AppUpdateDownloader().download(request, to: download) { fraction in
                onPhase(.downloading(progress: fraction))
            }
        } catch {
            throw Failure.staged(.download, underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https"
        else {
            let status = (response as? HTTPURLResponse).map { "\($0.statusCode)" } ?? "non-http"
            throw Failure.staged(.download, underlying: "status \(status)")
        }

        onPhase(.verifying)
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: download)
        } catch {
            throw Failure.staged(.verifyChecksum, underlying: error.localizedDescription)
        }
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else {
            throw Failure.staged(.verifyChecksum, underlying: "sha256 mismatch")
        }

        let stage = try files.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: installed,
            create: true)
        var keepStage = false
        defer {
            if !keepStage { try? files.removeItem(at: stage) }
        }

        let image = stage.appendingPathComponent(asset.name)
        try files.moveItem(at: download, to: image)
        let mount = stage.appendingPathComponent("mount", isDirectory: true)
        try files.createDirectory(at: mount, withIntermediateDirectories: false)
        let replacement = stage.appendingPathComponent(installed.lastPathComponent)
        onPhase(.installing)
        do {
            try self.stageApplication(from: image, mountedAt: mount, to: replacement)
        } catch {
            throw Failure.staged(.stageImage, underlying: self.describe(error))
        }

        do {
            let infoURL = replacement.appendingPathComponent("Contents/Info.plist")
            let info = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoURL), format: nil)
            guard let info = info as? [String: Any],
                  info["CFBundleIdentifier"] as? String == installedID,
                  info["CFBundleExecutable"] as? String == "ClashBar",
                  info["CFBundleShortVersionString"] as? String == release.displayVersion,
                  info["ClashBarBundlesMihomoCore"] as? Bool == bundlesCore
            else {
                throw Failure.staged(.verifyBundle, underlying: "unexpected Info.plist")
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.staged(.verifyBundle, underlying: error.localizedDescription)
        }

        do {
            try self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", replacement.path])
        } catch {
            throw Failure.staged(.verifyBundle, underlying: self.describe(error))
        }
        try Task.checkCancellation()

        // Keep the running bundle intact on disk until the new bundle is fully verified.
        guard renameatx_np(AT_FDCWD, replacement.path, AT_FDCWD, installed.path, UInt32(RENAME_SWAP)) == 0
        else {
            throw Failure.staged(.replaceBundle, underlying: String(cString: strerror(errno)))
        }
        keepStage = true

        do {
            onPhase(.relaunching)
            try self.scheduleRelaunch(
                installed: installed,
                stage: stage,
                previousBundle: replacement,
                version: release.displayVersion,
                previousVersion: previousVersion)
        } catch {
            if renameatx_np(AT_FDCWD, replacement.path, AT_FDCWD, installed.path, UInt32(RENAME_SWAP)) == 0 {
                keepStage = false
            }
            throw Failure.staged(.scheduleRelaunch, underlying: self.describe(error))
        }
    }

    /// A one-line description of a failure for the log, keeping the command name that the
    /// `Failure.command` case already carries.
    static func describe(_ error: Error) -> String {
        switch error as? Failure {
        case let .staged(_, underlying): underlying
        case let .command(name): "command failed: \(name)"
        case .verification: "verification failed"
        case .replacement: "bundle swap failed"
        case .download: "download failed"
        case .incompatibleAsset: "no compatible asset"
        case .nonWritableInstallation: "installation not writable"
        case nil: error.localizedDescription
        }
    }

    private static func stageApplication(from image: URL, mountedAt mount: URL, to replacement: URL) throws {
        let hdiutil = "/usr/bin/hdiutil"
        try self.run(hdiutil, ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path])
        do {
            let source = mount.appendingPathComponent("ClashBar.app")
            guard source.resolvingSymlinksInPath().path == source.path else { throw Failure.verification }
            try FileManager.default.copyItem(at: source, to: replacement)
        } catch {
            try? self.run(hdiutil, ["detach", mount.path])
            throw error
        }
        try self.run(hdiutil, ["detach", mount.path])
        try FileManager.default.removeItem(at: image)
    }

    /// The relaunch helper outlives this process, so every outcome is written to
    /// a status file the next launch can read. A failed `open` falls back to the
    /// bundle kept in the staging directory instead of leaving no app installed.
    static let relaunchScript = """
    installed_path=$1
    stage_path=$2
    previous_bundle=$3
    new_version=$4
    old_version=$5
    status_file=$6
    /bin/mkdir -p "$(/usr/bin/dirname "$status_file")"
    write_status() {
        /usr/bin/printf '{"result":"%s","installedVersion":"%s","previousVersion":"%s","date":%s}\\n' \
            "$1" "$new_version" "$old_version" "$(/bin/date +%s)" > "$status_file"
    }
    remaining=300
    while kill -0 "$7" 2>/dev/null; do
        if [ "$remaining" -le 0 ]; then
            write_status timedOut
            exit 0
        fi
        remaining=$((remaining - 1))
        /bin/sleep 0.1
    done
    attempts=0
    # Right after the bundle swap, LaunchServices may still resolve the old inode, so the
    # first `open` can fail even though the new app is fine. Back off further on each try
    # instead of giving up after three quick attempts, which used to show as a failed
    # update that succeeded on a manual retry.
    for wait_seconds in 1 1 2 3 4 5; do
        if /usr/bin/open -n -a "$installed_path"; then
            write_status succeeded
            /bin/rm -rf "$stage_path"
            exit 0
        fi
        attempts=$((attempts + 1))
        /bin/sleep "$wait_seconds"
    done
    failed_path="$installed_path.failed-update"
    if /bin/mv -f "$installed_path" "$failed_path"; then
        if /bin/mv -f "$previous_bundle" "$installed_path"; then
            if /usr/bin/open -n -a "$installed_path"; then
                write_status rolledBack
                /bin/rm -rf "$failed_path" "$stage_path"
                exit 0
            fi
        else
            /bin/mv -f "$failed_path" "$installed_path"
        fi
    fi
    write_status openFailed
    exit 0
    """

    private static func scheduleRelaunch(
        installed: URL,
        stage: URL,
        previousBundle: URL,
        version: String,
        previousVersion: String) throws
    {
        let statusURL = self.relaunchOutcomeURL()
        try? FileManager.default.createDirectory(
            at: statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", self.relaunchScript, "clashbar-relaunch",
            installed.path,
            stage.path,
            previousBundle.path,
            version,
            previousVersion,
            statusURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        try process.run()
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.command(URL(fileURLWithPath: executable).lastPathComponent)
        }
    }
}

private final class AppUpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var destinationURL: URL?
    private var progressHandler: (@Sendable (Double?) -> Void)?
    private var response: URLResponse?

    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Double?) -> Void) async throws -> URLResponse?
    {
        let configuration = URLSessionFactory.makeEphemeralConfiguration(options: .init(
            timeoutIntervalForRequest: 30,
            timeoutIntervalForResource: 600))
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        self.lock.withLock {
            self.destinationURL = destination
            self.progressHandler = progress
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.lock.withLock { self.continuation = continuation }
            session.downloadTask(with: request).resume()
        }

        return self.lock.withLock { self.response }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64)
    {
        let handler = self.lock.withLock { self.progressHandler }
        guard totalBytesExpectedToWrite > 0 else {
            handler?(nil)
            return
        }
        handler?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL)
    {
        let destination = self.lock.withLock { self.destinationURL }
        guard let destination else {
            self.finish(error: AppUpdateInstaller.Failure.download, response: downloadTask.response)
            return
        }

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            self.finish(error: nil, response: downloadTask.response)
        } catch {
            self.finish(error: error, response: downloadTask.response)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        self.finish(error: error, response: task.response)
    }

    private func finish(error: Error?, response: URLResponse?) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let current = self.continuation
            self.continuation = nil
            self.response = response
            return current
        }
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
