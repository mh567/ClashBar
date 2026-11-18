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
/// in the group list.
struct ProxyGroupLatencyLookup {
    let groups: [ProxyGroup]
    let samples: [String: [String: [Int]]]
    let defaultURL: String

    func groupedSamples(groupName: String, node: String, fallbackToGroupHistory: Bool) -> [Int] {
        if let nested = self.group(named: node) {
            return self.displaySamples(for: nested)
        }

        let url = self.testURL(for: self.group(named: groupName))
        if let samples = self.samples[node]?[url], !samples.isEmpty {
            return samples
        }
        guard fallbackToGroupHistory else { return [] }
        return self.samples[groupName]?[url] ?? []
    }

    /// Samples shown by a group's own row: the selected node's history at the
    /// group's test URL, then the group's own history at that URL. A selected
    /// child group resolves recursively so chained groups stay consistent.
    func displaySamples(for group: ProxyGroup) -> [Int] {
        self.displaySamples(for: group, visited: [])
    }

    func group(named name: String) -> ProxyGroup? {
        self.groups.first { $0.name == name }
    }

    private func displaySamples(for group: ProxyGroup, visited: Set<String>) -> [Int] {
        var visited = visited
        guard visited.insert(group.name).inserted else { return [] }

        let url = self.testURL(for: group)
        if let now = group.now?.trimmedNonEmpty {
            if let nested = self.group(named: now) {
                let nestedSamples = self.displaySamples(for: nested, visited: visited)
                if !nestedSamples.isEmpty {
                    return nestedSamples
                }
            } else if let samples = self.samples[now]?[url], !samples.isEmpty {
                return samples
            }
        }

        return self.samples[group.name]?[url] ?? []
    }

    private func testURL(for group: ProxyGroup?) -> String {
        group?.testUrl ?? self.defaultURL
    }
}
