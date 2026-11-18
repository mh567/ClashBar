import XCTest
@testable import ClashBar

final class AppSemanticVersionTests: XCTestCase {
    func testClientUpdateSelectsOnlyMatchingForkAssetWithDigest() throws {
        let digest = String(repeating: "a", count: 64)
        let base = "https://github.com/mh567/ClashBar/releases/download/v1.2.3"
        let release = try JSONDecoder().decode(AppReleaseInfo.self, from: Data("""
        {
          "tag_name": "v1.2.3", "html_url": "\(base)", "draft": false, "prerelease": false,
          "assets": [
            {"name": "ClashBar-1.2.3-apple-silicon.dmg", "digest": "sha256:\(digest)",
             "browser_download_url": "\(base)/ClashBar-1.2.3-apple-silicon.dmg"},
            {"name": "ClashBar-1.2.3-apple-silicon-no-core.dmg",
             "browser_download_url": "\(base)/ClashBar-1.2.3-apple-silicon-no-core.dmg"},
            {"name": "ClashBar-1.2.3-intel.dmg", "digest": "sha256:\(digest)",
             "browser_download_url": "https://github.com/Sitoi/ClashBar/releases/download/v1.2.3/ClashBar-1.2.3-intel.dmg"}
          ]
        }
        """.utf8))

        XCTAssertEqual(release.installableAsset(architecture: "apple-silicon", bundlesCore: true)?.sha256, digest)
        XCTAssertNil(release.installableAsset(architecture: "apple-silicon", bundlesCore: false))
        XCTAssertNil(release.installableAsset(architecture: "intel", bundlesCore: true))
    }

    func testParsesPrefixedAndBareVersions() {
        XCTAssertEqual(AppSemanticVersion("v1.19.31")?.displayString, "1.19.31")
        XCTAssertEqual(AppSemanticVersion("1.19.31")?.displayString, "1.19.31")
        XCTAssertEqual(AppSemanticVersion("Mihomo Meta v1.19.31")?.displayString, "1.19.31")
    }

    /// Hyphenated build labels are treated as prerelease suffixes and dropped, so
    /// the version must still be found when it appears after the hyphen.
    func testHyphenatedLabelsAreNotParsedAsVersions() {
        XCTAssertNil(AppSemanticVersion("alpha-git-abc123"))
        XCTAssertNil(AppSemanticVersion("meta-v1.2.3"))
    }

    func testStripsPrereleaseAndBuildMetadata() {
        XCTAssertEqual(AppSemanticVersion("v1.2.3-beta.1")?.displayString, "1.2.3")
        XCTAssertEqual(AppSemanticVersion("v1.2.3+build.9")?.displayString, "1.2.3")
    }

    func testRejectsVersionsWithoutDigits() {
        XCTAssertNil(AppSemanticVersion(""))
        XCTAssertNil(AppSemanticVersion("alpha"))
    }

    func testComparableAcrossDifferentComponentCounts() {
        XCTAssertLessThan(AppSemanticVersion("1.19.9")!, AppSemanticVersion("1.19.31")!)
        XCTAssertLessThan(AppSemanticVersion("1.19")!, AppSemanticVersion("1.19.1")!)
        XCTAssertFalse(AppSemanticVersion("1.2")! < AppSemanticVersion("1.2.0")!)
    }

    func testIsNewerReleaseIgnoresLeadingV() {
        XCTAssertTrue(AppSemanticVersion.isNewerRelease(tagName: "v0.3.7", than: "0.3.6"))
        XCTAssertFalse(AppSemanticVersion.isNewerRelease(tagName: "v0.3.6", than: "0.3.6"))
        XCTAssertFalse(AppSemanticVersion.isNewerRelease(tagName: "v0.3.5", than: "0.3.6"))
    }

    func testNormalizedDisplayVersionFallsBackWhenUnparsable() {
        XCTAssertEqual(AppSemanticVersion.normalizedDisplayVersion(from: "v1.2.3"), "1.2.3")
        XCTAssertEqual(AppSemanticVersion.normalizedDisplayVersion(from: " alpha "), "alpha")
    }

    /// Guards the TUN `mips` stack gate: the runtime compares the core version
    /// string against this minimum, so the comparison must be numeric.
    @MainActor
    func testMipsStackMinimumGate() {
        let minimum = AppSemanticVersion(AppViewModel.mipsStackMinimumCoreVersion)!
        XCTAssertTrue(AppSemanticVersion("v1.19.31")! >= minimum)
        XCTAssertTrue(AppSemanticVersion("v1.20.0")! >= minimum)
        XCTAssertFalse(AppSemanticVersion("v1.19.30")! >= minimum)
    }
}

final class AppReleaseSourceTests: XCTestCase {
    /// A fork must not advertise upstream releases: update checks and links point
    /// at this repository, otherwise users get sent to install upstream builds.
    func testReleaseCoordinatesPointAtThisFork() {
        XCTAssertEqual(AppReleaseSource.owner, "mh567")
        XCTAssertEqual(AppReleaseSource.repository, "ClashBar")
        XCTAssertEqual(
            AppReleaseSource.latestReleaseURL?.absoluteString,
            "https://api.github.com/repos/mh567/ClashBar/releases/latest")
        XCTAssertEqual(
            AppReleaseSource.repositoryPageURL?.absoluteString,
            "https://github.com/mh567/ClashBar")
    }
}
