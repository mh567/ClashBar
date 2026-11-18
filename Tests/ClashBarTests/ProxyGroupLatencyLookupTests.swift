import XCTest
@testable import ClashBar

final class ProxyGroupLatencyLookupTests: XCTestCase {
    private let defaultURL = "https://www.gstatic.com/generate_204"

    private func lookup(
        groups: [ProxyGroup],
        samples: [String: [String: [Int]]]) -> ProxyGroupLatencyLookup
    {
        ProxyGroupLatencyLookup(groups: groups, samples: samples, defaultURL: self.defaultURL)
    }

    /// The nested region row must show the same value as that region's own row:
    /// the selected node's samples at the group's test URL.
    func testNestedGroupMatchesItsOwnRow() throws {
        let region = ProxyGroup(name: "🇺🇸", now: "us-1", all: ["us-1", "us-2"])
        let parent = ProxyGroup(name: "节点选择", now: "🇺🇸", all: ["🇺🇸", "🇭🇰"])
        let samples = [
            "us-1": [self.defaultURL: [181]],
            "🇺🇸": [self.defaultURL: [168]],
        ]
        let lookup = self.lookup(groups: [parent, region], samples: samples)

        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: region.name, fallbackToGroupHistory: false),
            [181])
        XCTAssertEqual(lookup.displaySamples(for: region), [181])
        XCTAssertEqual(
            lookup.groupedSamples(groupName: region.name, node: "us-1", fallbackToGroupHistory: true),
            [181])
        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: parent.now!, fallbackToGroupHistory: true),
            [181])
    }

    /// A group with its own test URL must not borrow the parent's URL samples.
    func testNestedGroupUsesItsOwnTestURL() {
        let childURL = "http://connect.rom.miui.com/generate_204"
        let region = ProxyGroup(name: "🇭🇰", now: "hk-1", all: ["hk-1"], testUrl: childURL)
        let parent = ProxyGroup(name: "节点选择", now: "🇭🇰", all: ["🇭🇰", "DIRECT"])
        let samples = [
            "hk-1": [childURL: [120]],
            "🇭🇰": [self.defaultURL: [999]],
        ]
        let lookup = self.lookup(groups: [parent, region], samples: samples)

        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: region.name, fallbackToGroupHistory: false),
            [120])
        XCTAssertEqual(
            lookup.groupedSamples(groupName: region.name, node: "hk-1", fallbackToGroupHistory: true),
            [120])
    }

    func testFallsBackToGroupHistoryWhenSelectedNodeHasNoSamples() {
        let region = ProxyGroup(name: "🇯🇵", now: "jp-1", all: ["jp-1"])
        let parent = ProxyGroup(name: "节点选择", now: "🇯🇵", all: ["🇯🇵"])
        let samples = ["🇯🇵": [self.defaultURL: [200]]]
        let lookup = self.lookup(groups: [parent, region], samples: samples)

        XCTAssertEqual(lookup.displaySamples(for: region), [200])
        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: region.name, fallbackToGroupHistory: false),
            [200])
    }

    func testChainedGroupsResolveDeepestSelection() {
        let leafGroup = ProxyGroup(name: "🇸🇬", now: "sg-1", all: ["sg-1"])
        let middle = ProxyGroup(name: "自动选择", now: "🇸🇬", all: ["🇸🇬"])
        let outer = ProxyGroup(name: "节点选择", now: "自动选择", all: ["自动选择"])
        let samples = ["sg-1": [self.defaultURL: [88]]]
        let lookup = self.lookup(groups: [outer, middle, leafGroup], samples: samples)

        XCTAssertEqual(lookup.displaySamples(for: outer), [88])
        XCTAssertEqual(lookup.displaySamples(for: middle), [88])
        XCTAssertEqual(
            lookup.groupedSamples(groupName: outer.name, node: middle.name, fallbackToGroupHistory: false),
            [88])
    }

    func testCyclicSelectionsDoNotRecurseForever() {
        let first = ProxyGroup(name: "A", now: "B", all: ["B"])
        let second = ProxyGroup(name: "B", now: "A", all: ["A"])
        let lookup = self.lookup(groups: [first, second], samples: [:])

        XCTAssertEqual(lookup.displaySamples(for: first), [])
        XCTAssertEqual(
            lookup.groupedSamples(groupName: first.name, node: second.name, fallbackToGroupHistory: false),
            [])
    }

    func testLeafNodeStillUsesParentTestURL() {
        let parent = ProxyGroup(name: "节点选择", now: "us-1", all: ["us-1", "hk-1"])
        let samples = [
            "us-1": [self.defaultURL: [50]],
            "hk-1": [self.defaultURL: [80]],
        ]
        let lookup = self.lookup(groups: [parent], samples: samples)

        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: "hk-1", fallbackToGroupHistory: false),
            [80])
        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: "missing", fallbackToGroupHistory: false),
            [])
        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: "missing", fallbackToGroupHistory: true),
            [])
    }
}
