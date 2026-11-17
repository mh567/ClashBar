import XCTest

/// Exercises the shell tooling that drives releases and packaging.
///
/// These run the real scripts (no mocks) so a change to the workflow's version
/// derivation or the icon pipeline fails here rather than at release time.
final class ScriptToolingTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClashBarTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private struct ScriptResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    private func run(
        _ executable: String,
        _ arguments: [String],
        stdin: String? = nil,
        environment: [String: String] = [:])
        throws -> ScriptResult
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = self.repoRoot
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()
        if let stdin, let data = stdin.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        return ScriptResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    private func bump(forMessage message: String) throws -> ScriptResult {
        try self.run(
            "/bin/bash",
            [self.repoRoot.appendingPathComponent("Scripts/resolve_version_bump.sh").path],
            stdin: message)
    }

    // MARK: - Version bump derivation

    func testBumpDetectsFeatureAsMinorWithEmojiPrefix() throws {
        let result = try self.bump(forMessage: "✨ feat: 更新 v0.3.6，修复系统代理 Helper 安装问题\n")

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "minor")
    }

    func testBumpDetectsFixAsPatch() throws {
        let result = try self.bump(forMessage: "🐞 fix: 修复日志搜索截断\n")

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "patch")
    }

    func testBumpDetectsBreakingChangeBodyAsMajor() throws {
        let result = try self.bump(forMessage: "✨ feat: 重构配置层\n\nBREAKING CHANGE: 移除旧配置格式\n")

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "major")
    }

    func testBumpDetectsBangTypeAsMajor() throws {
        let result = try self.bump(forMessage: "feat(config)!: drop legacy field\n")

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "major")
    }

    func testBumpWorksWithoutEmojiPrefix() throws {
        let result = try self.bump(forMessage: "refactor: 状态栏图标改为离屏合成\n")

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "patch")
    }

    /// The pre-fix workflow exited 1 here because `^feat` never matched an
    /// emoji-prefixed subject.
    func testBumpRejectsNonConventionalMessages() throws {
        let result = try self.bump(forMessage: "更新了一些东西\nno type prefix\n")

        XCTAssertNotEqual(result.status, 0)
    }

    // MARK: - Script syntax

    func testAllRepositoryScriptsParse() throws {
        let scriptsDirectory = self.repoRoot.appendingPathComponent("Scripts")
        let scripts = try FileManager.default
            .contentsOfDirectory(atPath: scriptsDirectory.path)
            .filter { $0.hasSuffix(".sh") }
            .sorted()

        XCTAssertFalse(scripts.isEmpty, "expected shell scripts under Scripts/")

        for script in scripts {
            let result = try self.run("/bin/bash", ["-n", scriptsDirectory.appendingPathComponent(script).path])
            XCTAssertEqual(result.status, 0, "\(script) failed bash -n: \(result.stderr)")
        }
    }

    // MARK: - Icon generation

    /// Guards the @2x regression: the pipeline must emit Retina variants without
    /// upscaling past the source artwork size.
    func testIconPipelineEmitsRetinaVariantsWithoutUpscaling() throws {
        let source = self.repoRoot
            .appendingPathComponent("Sources/ClashBar/Resources/Assets.xcassets/BrandLogo.imageset/logo.png")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("brand logo source not present")
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clashbar-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = workDirectory.appendingPathComponent("app.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let sourcePixels = try self.pixelWidth(of: source)
        for size in [16, 32, 128, 256, 512] {
            try self.resize(source, to: size, output: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
            let doubleSize = size * 2
            if doubleSize <= sourcePixels {
                try self.resize(
                    source,
                    to: doubleSize,
                    output: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
            }
        }

        let generated = try FileManager.default.contentsOfDirectory(atPath: iconset.path).sorted()
        XCTAssertEqual(generated.count, 9, "expected 5 base + 4 @2x variants, got \(generated)")
        XCTAssertTrue(generated.contains("icon_256x256@2x.png"))
        XCTAssertFalse(generated.contains("icon_512x512@2x.png"), "must not upscale past a 512px source")

        for name in generated {
            let width = try self.pixelWidth(of: iconset.appendingPathComponent(name))
            XCTAssertLessThanOrEqual(width, max(sourcePixels, 512), "\(name) was upscaled")
        }

        let icns = workDirectory.appendingPathComponent("app.icns")
        let result = try self.run("/usr/bin/iconutil", ["--convert", "icns", iconset.path, "--output", icns.path])
        XCTAssertEqual(result.status, 0, "iconutil failed: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: icns.path))
    }

    private func resize(_ source: URL, to size: Int, output: URL) throws {
        let result = try self.run("/usr/bin/sips", ["-z", "\(size)", "\(size)", source.path, "--out", output.path])
        XCTAssertEqual(result.status, 0, "sips failed: \(result.stderr)")
    }

    private func pixelWidth(of url: URL) throws -> Int {
        let result = try self.run("/usr/bin/sips", ["-g", "pixelWidth", url.path])
        let digits = result.stdout
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int($0) }
        return try XCTUnwrap(digits.first, "could not read pixelWidth from: \(result.stdout)")
    }
}

extension ScriptToolingTests {
    func testSyncUpstreamScriptParses() throws {
        let result = try self.run(
            "/bin/bash",
            ["-n", self.repoRoot.appendingPathComponent("Scripts/sync_upstream.sh").path])
        XCTAssertEqual(result.status, 0, result.stderr)
    }
}

extension ScriptToolingTests {
    /// The cask lives in a tap only the upstream owner can push to. If this guard
    /// is dropped, every fork release fails at the final job.
    ///
    /// Fork-only: this assertion cannot live on `main`, where the workflow still
    /// legitimately targets upstream's tap.
    func testReleaseWorkflowGuardsHomebrewTapForUpstreamOnly() throws {
        let workflow = self.repoRoot.appendingPathComponent(".github/workflows/release-dmg.yml")
        let contents = try String(contentsOf: workflow, encoding: .utf8)

        XCTAssertTrue(
            contents.contains("if: github.repository == 'Sitoi/ClashBar'"),
            "update-formula must be gated so forks do not attempt to push to upstream's tap")
    }
}

extension ScriptToolingTests {
    private func releaseNotes(variants: String?) throws -> String {
        var environment = ["GITHUB_REPOSITORY": "mh567/ClashBar"]
        if let variants {
            environment["RELEASE_VARIANTS"] = variants
        }
        let result = try self.run(
            "/bin/bash",
            [
                self.repoRoot.appendingPathComponent("Scripts/generate_release_notes.sh").path,
                "v1.0.0", "1.0.0", "/dev/stdout",
            ],
            environment: environment)
        XCTAssertEqual(result.status, 0, result.stderr)
        return result.stdout
    }

    /// The workflow matrix was trimmed to a single artifact to fit the macOS
    /// runner quota; the download table must not advertise files that are not built.
    func testReleaseNotesOnlyListBuiltVariants() throws {
        let notes = try self.releaseNotes(variants: nil)

        XCTAssertTrue(notes.contains("ClashBar-1.0.0-apple-silicon.dmg"), notes)
        XCTAssertFalse(notes.contains("apple-silicon-no-core.dmg"), notes)
        XCTAssertFalse(notes.contains("ClashBar-1.0.0-intel.dmg"), notes)
    }

    func testReleaseNotesListFullMatrixWhenEnabled() throws {
        let notes = try self.releaseNotes(
            variants: "apple-silicon apple-silicon-no-core intel intel-no-core")

        for suffix in ["apple-silicon", "apple-silicon-no-core", "intel", "intel-no-core"] {
            XCTAssertTrue(notes.contains("ClashBar-1.0.0-\(suffix).dmg"), "missing \(suffix)")
        }
    }
}
