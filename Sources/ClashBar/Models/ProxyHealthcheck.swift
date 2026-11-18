import Foundation

enum ProxyHealthcheck {
    private static let directNodeType = "direct"

    private static let untestableNodeTypes: Set<String> = [
        "reject",
        "rejectdrop",
        "pass",
        "compatible",
    ]

    static func isTestable(nodeType: String?) -> Bool {
        !Self.untestableNodeTypes.contains(self.normalizedType(nodeType))
    }

    static func isDirect(nodeType: String?) -> Bool {
        self.normalizedType(nodeType) == Self.directNodeType
    }

    static func resolvedDirectURL(configured: String, fallback: String) -> String {
        configured.trimmedNonEmpty ?? fallback
    }

    static func targetURL(
        nodeType: String?,
        nodeURL: String?,
        groupURL: String?,
        defaultURL: String,
        directURL: String) -> String?
    {
        let type = self.normalizedType(nodeType)
        if Self.untestableNodeTypes.contains(type) {
            return nil
        }
        if type == Self.directNodeType {
            return directURL
        }
        if let nodeURL = nodeURL?.trimmedNonEmpty {
            return nodeURL
        }
        if let groupURL = groupURL?.trimmedNonEmpty {
            return groupURL
        }
        return defaultURL
    }

    static func testURLs(proxies: [ProxyGroup], providers: [ProviderDetail]) -> [String: String] {
        var urls: [String: String] = [:]
        for proxy in proxies {
            if let testURL = proxy.testUrl.trimmedNonEmpty {
                urls[proxy.name] = testURL
            }
        }
        for provider in providers {
            guard let providerURL = provider.testUrl.trimmedNonEmpty else { continue }
            for node in provider.proxies ?? [] where urls[node.name] == nil {
                urls[node.name] = providerURL
            }
        }
        return urls
    }

    private static func normalizedType(_ type: String?) -> String {
        type?.trimmed.lowercased() ?? ""
    }
}
