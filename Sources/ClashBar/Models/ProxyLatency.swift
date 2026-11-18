import Foundation

/// Resolves which delay samples a row should display.
///
/// The mihomo API stores delay history per proxy name and per test URL. A group
/// that is also a member of another group therefore has two records: its own row
/// uses the selected node's samples at the group's test URL, while a nested row
/// used to read the group's own history at the parent's test URL. Both are real
/// measurements, so the same region group showed two different latencies.
///
/// A node that is itself a group now always resolves the same way as its own row
/// in the group list. Leaf nodes resolve their own configured test URL first
/// (a group's `url` or a provider health-check URL), then the parent group's,
/// then the app default. `DIRECT` has no configured URL and is measured against
/// the direct probe URL instead.
struct ProxyGroupLatencyLookup {
    let groups: [ProxyGroup]
    let samples: [String: [String: [Int]]]
    let testURLs: [String: String]
    let nodeTypes: [String: String]
    let defaultURL: String
    let directURL: String?

    init(
        groups: [ProxyGroup],
        samples: [String: [String: [Int]]],
        testURLs: [String: String] = [:],
        nodeTypes: [String: String] = [:],
        defaultURL: String,
        directURL: String? = nil)
    {
        self.groups = groups
        self.samples = samples
        self.testURLs = testURLs
        self.nodeTypes = nodeTypes
        self.defaultURL = defaultURL
        self.directURL = directURL
    }

    func groupedSamples(groupName: String, node: String, fallbackToGroupHistory: Bool) -> [Int] {
        if let nested = self.group(named: node) {
            return self.displaySamples(for: nested)
        }

        let parent = self.group(named: groupName)
        if let url = self.targetURL(forNode: node, in: parent),
           let samples = self.samples[node]?[url], !samples.isEmpty
        {
            return samples
        }
        if let samples = self.retainedSamples(forNode: node) {
            return samples
        }
        guard fallbackToGroupHistory else { return [] }
        let groupURL = self.ownURL(forNode: groupName) ?? self.defaultURL
        return self.samples[groupName]?[groupURL] ?? []
    }

    /// Samples shown by a group's own row: the selected node's history at the
    /// URL it was tested with, then the group's own history. A selected child
    /// group resolves recursively so chained groups stay consistent.
    func displaySamples(for group: ProxyGroup) -> [Int] {
        self.displaySamples(for: group, visited: [])
    }

    func group(named name: String) -> ProxyGroup? {
        self.groups.first { $0.name == name }
    }

    private func displaySamples(for group: ProxyGroup, visited: Set<String>) -> [Int] {
        var visited = visited
        guard visited.insert(group.name).inserted else { return [] }

        if let now = group.now?.trimmedNonEmpty {
            if let nested = self.group(named: now) {
                let nestedSamples = self.displaySamples(for: nested, visited: visited)
                if !nestedSamples.isEmpty {
                    return nestedSamples
                }
            } else if let url = self.targetURL(forNode: now, in: group),
                      let samples = self.samples[now]?[url], !samples.isEmpty
            {
                return samples
            }
        }

        let groupURL = self.ownURL(forNode: group.name) ?? self.defaultURL
        return self.samples[group.name]?[groupURL] ?? []
    }

    private func targetURL(forNode node: String, in group: ProxyGroup?) -> String? {
        ProxyHealthcheck.targetURL(
            nodeType: self.nodeTypes[node],
            nodeURL: self.ownURL(forNode: node),
            groupURL: group?.testUrl,
            defaultURL: self.defaultURL,
            directURL: self.directURL ?? self.defaultURL)
    }

    private func ownURL(forNode node: String) -> String? {
        self.testURLs[node] ?? self.groups.first { $0.name == node }?.testUrl
    }

    /// Keeps a stale-but-real measurement visible when the proxy's history was
    /// recorded under an earlier URL and has not been re-tested yet. `DIRECT` is
    /// excluded so an old timeout against a foreign URL cannot resurface.
    private func retainedSamples(forNode node: String) -> [Int]? {
        let nodeType = self.nodeTypes[node]
        guard ProxyHealthcheck.isTestable(nodeType: nodeType),
              !ProxyHealthcheck.isDirect(nodeType: nodeType)
        else { return nil }
        return self.samples[node]?.values.first { ($0.last ?? 0) > 0 }
    }
}
