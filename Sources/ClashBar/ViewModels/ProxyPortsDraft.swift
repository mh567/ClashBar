import Foundation

enum ProxyPortsDraft {
    static let portRange = 0...65535

    static func parsedPort(_ raw: String) -> Int? {
        guard let value = Int(raw.trimmed), self.portRange.contains(value) else { return nil }
        return value
    }
}
