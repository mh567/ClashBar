import CryptoKit
import Darwin
import Foundation

enum AppUpdateInstaller {
    enum Failure: Error {
        case incompatibleAsset
        case nonWritableInstallation
        case download
        case verification
        case command(String)
        case replacement
    }

    static func asset(for release: AppReleaseInfo, bundlesCore: Bool) -> AppReleaseInfo.Asset? {
        #if arch(arm64)
            let architecture = "apple-silicon"
        #else
            let architecture = "intel"
        #endif
        return release.installableAsset(architecture: architecture, bundlesCore: bundlesCore)
    }

    @concurrent
    static func install(_ release: AppReleaseInfo, bundlesCore: Bool) async throws {
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

        let session = URLSessionFactory.makeEphemeralSession(options: .init(
            timeoutIntervalForRequest: 30,
            timeoutIntervalForResource: 600))
        defer { session.finishTasksAndInvalidate() }
        let (download, response) = try await session.download(from: asset.downloadURL)
        defer { try? files.removeItem(at: download) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https"
        else { throw Failure.download }

        let input = try FileHandle(forReadingFrom: download)
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else { throw Failure.verification }

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
        try self.stageApplication(from: image, mountedAt: mount, to: replacement)

        let infoURL = replacement.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
        guard let info = info as? [String: Any],
              info["CFBundleIdentifier"] as? String == installedID,
              info["CFBundleExecutable"] as? String == "ClashBar",
              info["CFBundleShortVersionString"] as? String == release.displayVersion,
              info["ClashBarBundlesMihomoCore"] as? Bool == bundlesCore
        else { throw Failure.verification }
        try self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", replacement.path])
        try Task.checkCancellation()

        // Keep the running bundle intact on disk until the new bundle is fully verified.
        guard renameatx_np(AT_FDCWD, replacement.path, AT_FDCWD, installed.path, UInt32(RENAME_SWAP)) == 0
        else { throw Failure.replacement }
        keepStage = true

        do {
            try self.scheduleRelaunch(installed: installed, stage: stage)
        } catch {
            if renameatx_np(AT_FDCWD, replacement.path, AT_FDCWD, installed.path, UInt32(RENAME_SWAP)) == 0 {
                keepStage = false
            }
            throw error
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

    private static func scheduleRelaunch(installed: URL, stage: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", """
            remaining=300
            while kill -0 "$1" 2>/dev/null; do
                [ "$remaining" -gt 0 ] || exit 1
                remaining=$((remaining - 1))
                /bin/sleep 0.1
            done
            /usr/bin/open -n -a "$2" && /bin/rm -rf -- "$3"
            """, "clashbar-relaunch", String(ProcessInfo.processInfo.processIdentifier), installed.path, stage.path,
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
        guard process.terminationStatus == 0 else { throw Failure.command(URL(fileURLWithPath: executable).lastPathComponent) }
    }
}
