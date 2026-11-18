import Foundation

enum AppReleaseServiceError: Error {
    case invalidResponse
    case statusCode(Int)
    case invalidReleaseURL
    case invalidChecksum
}

enum AppReleaseService {
    static func fetchLatestRelease(
        currentVersion: String,
        architecture: String,
        bundlesCore: Bool,
        session injectedSession: URLSession? = nil) async throws -> AppReleaseInfo
    {
        guard let latestReleaseURL = AppReleaseSource.latestReleaseURL else {
            throw AppReleaseServiceError.invalidReleaseURL
        }

        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClashBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let session = injectedSession ?? Self.makeSession()
        defer {
            if injectedSession == nil { session.finishTasksAndInvalidate() }
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppReleaseServiceError.invalidResponse
        }
        if self.isRateLimited(httpResponse) {
            return try await self.fetchFromReleasePage(
                currentVersion: currentVersion, architecture: architecture, bundlesCore: bundlesCore, session: session)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw AppReleaseServiceError.statusCode(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(AppReleaseInfo.self, from: data)
    }

    private static func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 429 || (response.statusCode == 403 && (
            response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.value(forHTTPHeaderField: "Retry-After") != nil))
    }

    private static func fetchFromReleasePage(
        currentVersion: String,
        architecture: String,
        bundlesCore: Bool,
        session: URLSession) async throws -> AppReleaseInfo
    {
        guard let releasesURL = AppReleaseSource.releasesPageURL else {
            throw AppReleaseServiceError.invalidReleaseURL
        }
        var request = URLRequest(url: releasesURL.appendingPathComponent("latest"))
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let releaseURL = http.url else {
            throw AppReleaseServiceError.invalidResponse
        }
        let tag = releaseURL.lastPathComponent
        guard tag.wholeMatch(of: #/v?[0-9]+\.[0-9]+\.[0-9]+/#) != nil,
              releaseURL == releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
        else { throw AppReleaseServiceError.invalidReleaseURL }

        guard AppSemanticVersion.isNewerRelease(tagName: tag, than: currentVersion),
              let url = AppReleaseInfo.expectedAssetURL(tagName: tag, architecture: architecture, bundlesCore: bundlesCore)
        else { return AppReleaseInfo(tagName: tag, releaseURL: releaseURL) }

        let asset = try await self.fetchVerifiedAsset(at: url, session: session)
        return AppReleaseInfo(tagName: tag, releaseURL: releaseURL, asset: asset)
    }

    private static func fetchVerifiedAsset(at url: URL, session: URLSession) async throws -> AppReleaseInfo.Asset? {
        let checksumURL = url.appendingPathExtension("sha256")
        let (data, response) = try await session.data(from: checksumURL)
        guard let http = response as? HTTPURLResponse, let responseURL = http.url,
              responseURL.scheme == "https",
              responseURL == checksumURL || responseURL.host == "release-assets.githubusercontent.com"
                  || responseURL.host == "objects.githubusercontent.com"
        else { throw AppReleaseServiceError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw AppReleaseServiceError.statusCode(http.statusCode) }

        let fields = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        let name = url.lastPathComponent
        guard fields.count == 2, fields[1] == name else { throw AppReleaseServiceError.invalidChecksum }
        let asset = AppReleaseInfo.Asset(name: name, downloadURL: url, digest: "sha256:\(fields[0])")
        guard asset.sha256 != nil else { throw AppReleaseServiceError.invalidChecksum }
        return asset
    }

    private static func makeSession() -> URLSession {
        URLSessionFactory.makeEphemeralSession(options: .init(
            timeoutIntervalForRequest: 8,
            timeoutIntervalForResource: 15))
    }
}
