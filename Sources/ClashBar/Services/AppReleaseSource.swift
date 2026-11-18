import Foundation

/// Repository coordinates for self-update checks.
///
/// This fork publishes its own releases, so update checks must not point at the
/// upstream project. Keeping the coordinates in one place limits the diff a
/// merge with upstream has to reconcile.
enum AppReleaseSource {
    static let owner = "mh567"
    static let repository = "ClashBar"

    static var latestReleaseURL: URL? {
        URL(string: "https://api.github.com/repos/\(self.owner)/\(self.repository)/releases/latest")
    }

    static var releasesPageURL: URL? {
        URL(string: "https://github.com/\(self.owner)/\(self.repository)/releases")
    }

    static var repositoryPageURL: URL? {
        URL(string: "https://github.com/\(self.owner)/\(self.repository)")
    }
}
