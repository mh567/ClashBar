import Foundation
import XCTest
@testable import ClashBar

final class AppReleaseServiceTests: XCTestCase {
    func testRateLimitedUpdateFindsVerifiedDownloadOnReleasePage() async throws {
        let release = try await self.fetchRelease(bundlesCore: true)

        XCTAssertEqual(release.tagName, "v1.1.0")
        let asset = try XCTUnwrap(release.installableAsset(architecture: "apple-silicon", bundlesCore: true))
        XCTAssertEqual(asset.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(
            asset.downloadURL.absoluteString,
            "https://github.com/mh567/ClashBar/releases/download/v1.1.0/ClashBar-1.1.0-apple-silicon.dmg")
    }

    func testRateLimitedUpdateRejectsChecksumForDifferentAsset() async throws {
        do {
            _ = try await self.fetchRelease(bundlesCore: false)
            XCTFail("Accepted a checksum for a different asset")
        } catch AppReleaseServiceError.invalidChecksum {
            return
        }
    }

    private func fetchRelease(bundlesCore: Bool) async throws -> AppReleaseInfo {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitedRelease.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        return try await AppReleaseService.fetchLatestRelease(
            currentVersion: "1.0.1",
            architecture: "apple-silicon",
            bundlesCore: bundlesCore,
            session: session)
    }

    private final class RateLimitedRelease: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = self.request.url else { return self.fail() }
            switch (url.host, url.path, self.request.httpMethod) {
            case ("api.github.com", "/repos/mh567/ClashBar/releases/latest", "GET"):
                self.respond(at: url, status: 403, headers: ["X-RateLimit-Remaining": "0"])
            case ("github.com", "/mh567/ClashBar/releases/latest", "HEAD"):
                let target = url.deletingLastPathComponent().appendingPathComponent("tag/v1.1.0")
                self.respond(at: target, status: 200)
            case ("github.com", let path, "GET") where path.hasPrefix("/mh567/ClashBar/releases/download/v1.1.0/"):
                guard ["ClashBar-1.1.0-apple-silicon.dmg.sha256", "ClashBar-1.1.0-apple-silicon-no-core.dmg.sha256"]
                    .contains(url.lastPathComponent)
                else { return self.fail() }
                let digest = String(repeating: "a", count: 64)
                self.respond(at: url, status: 200, body: "\(digest)  ClashBar-1.1.0-apple-silicon.dmg\n")
            default:
                self.fail()
            }
        }

        override func stopLoading() {}

        private func fail() {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }

        private func respond(at url: URL, status: Int, headers: [String: String] = [:], body: String = "") {
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)
            else { return self.fail() }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
}
