import XCTest
@testable import ClashBar

final class ProxyHealthcheckTests: XCTestCase {
    private let defaultURL = "https://www.gstatic.com/generate_204"
    private let directURL = "http://connect.rom.miui.com/generate_204"

    func testDirectProxyUsesDirectProbeURL() {
        let url = ProxyHealthcheck.targetURL(
            nodeType: "Direct",
            nodeURL: nil,
            groupURL: self.defaultURL,
            defaultURL: self.defaultURL,
            directURL: self.directURL)

        XCTAssertEqual(url, self.directURL)
    }

    func testBlankDirectProbeURLFallsBackToBuiltInDefault() {
        let resolved = ProxyHealthcheck.resolvedDirectURL(configured: "   ", fallback: self.directURL)
        let url = ProxyHealthcheck.targetURL(
            nodeType: "direct",
            nodeURL: nil,
            groupURL: nil,
            defaultURL: self.defaultURL,
            directURL: resolved)

        XCTAssertEqual(url, self.directURL)
    }

    func testConfiguredDirectProbeURLIsUsed() {
        let resolved = ProxyHealthcheck.resolvedDirectURL(
            configured: " http://cp.cloudflare.com/generate_204 ",
            fallback: self.directURL)

        XCTAssertEqual(resolved, "http://cp.cloudflare.com/generate_204")
    }

    func testNodeOwnURLWinsOverGroupURL() {
        let url = ProxyHealthcheck.targetURL(
            nodeType: "Shadowsocks",
            nodeURL: "http://node.example/generate_204",
            groupURL: "http://group.example/generate_204",
            defaultURL: self.defaultURL,
            directURL: self.directURL)

        XCTAssertEqual(url, "http://node.example/generate_204")
    }

    func testNestedGroupUsesItsOwnURL() {
        let url = ProxyHealthcheck.targetURL(
            nodeType: nil,
            nodeURL: "http://connect.rom.miui.com/generate_204",
            groupURL: self.defaultURL,
            defaultURL: self.defaultURL,
            directURL: self.directURL)

        XCTAssertEqual(url, "http://connect.rom.miui.com/generate_204")
    }

    func testGroupURLUsedWhenNodeHasNone() {
        let url = ProxyHealthcheck.targetURL(
            nodeType: "Vmess",
            nodeURL: nil,
            groupURL: "http://group.example/generate_204",
            defaultURL: self.defaultURL,
            directURL: self.directURL)

        XCTAssertEqual(url, "http://group.example/generate_204")
    }

    func testFallsBackToDefaultURL() {
        let url = ProxyHealthcheck.targetURL(
            nodeType: nil,
            nodeURL: nil,
            groupURL: nil,
            defaultURL: self.defaultURL,
            directURL: self.directURL)

        XCTAssertEqual(url, self.defaultURL)
    }

    func testUntestableNodesHaveNoTarget() {
        for type in ["Reject", "RejectDrop", "Pass", "Compatible"] {
            XCTAssertFalse(ProxyHealthcheck.isTestable(nodeType: type))
            XCTAssertNil(ProxyHealthcheck.targetURL(
                nodeType: type,
                nodeURL: nil,
                groupURL: self.defaultURL,
                defaultURL: self.defaultURL,
                directURL: self.directURL))
        }
    }

    func testTestURLsPreferConfiguredGroupAndFallBackToProvider() {
        let regional = ProxyGroup(
            name: "🇭🇰",
            type: "Selector",
            all: ["DIRECT"],
            testUrl: "http://connect.rom.miui.com/generate_204")
        let implicitDefault = ProxyGroup(name: "微软服务", type: "Selector", all: ["DIRECT"])
        let provider = ProviderDetail(
            name: "JMS",
            vehicleType: "HTTP",
            testUrl: "http://provider.example/generate_204",
            timeout: 3000,
            updatedAt: nil,
            ruleCount: nil,
            subscriptionInfo: nil,
            proxies: [ProviderProxyNode(name: "us-1", type: "Vmess")])

        let urls = ProxyHealthcheck.testURLs(proxies: [regional, implicitDefault], providers: [provider])

        XCTAssertEqual(urls["🇭🇰"], "http://connect.rom.miui.com/generate_204")
        XCTAssertNil(urls["微软服务"])
        XCTAssertEqual(urls["us-1"], "http://provider.example/generate_204")
    }

    func testLookupUsesPerNodeURLAndDirectProbe() {
        let nodeURL = "http://provider.example/generate_204"
        let parent = ProxyGroup(name: "微软服务", now: "DIRECT", all: ["DIRECT", "us-1"])
        let samples = [
            "DIRECT": [self.directURL: [18]],
            "us-1": [nodeURL: [120]],
        ]
        let lookup = ProxyGroupLatencyLookup(
            groups: [parent],
            samples: samples,
            testURLs: ["us-1": nodeURL],
            nodeTypes: ["DIRECT": "Direct"],
            defaultURL: self.defaultURL,
            directURL: self.directURL)

        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: "DIRECT", fallbackToGroupHistory: false),
            [18])
        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: "us-1", fallbackToGroupHistory: false),
            [120])
        XCTAssertEqual(lookup.displaySamples(for: parent), [18])
    }

    func testLookupDoesNotResurrectDirectForeignURLHistory() {
        let parent = ProxyGroup(name: "微软服务", now: "DIRECT", all: ["DIRECT"])
        let samples = ["DIRECT": [self.defaultURL: [0]]]
        let lookup = ProxyGroupLatencyLookup(
            groups: [parent],
            samples: samples,
            nodeTypes: ["DIRECT": "Direct"],
            defaultURL: self.defaultURL,
            directURL: self.directURL)

        XCTAssertEqual(
            lookup.groupedSamples(groupName: parent.name, node: "DIRECT", fallbackToGroupHistory: true),
            [])
        XCTAssertEqual(lookup.displaySamples(for: parent), [])
    }

    func testDecodingMihomoProxiesPayloadKeepsTestURLsAndHistory() throws {
        let payload = """
        {"proxies":{
          "微软服务":{"type":"Selector","now":"DIRECT","all":["DIRECT"],"testUrl":""},
          "🇭🇰":{"type":"Selector","now":"DIRECT","all":["DIRECT"],
                 "testUrl":"http://connect.rom.miui.com/generate_204"},
          "DIRECT":{"type":"Direct","udp":true,
            "extra":{"http://connect.rom.miui.com/generate_204":{"history":[{"delay":18},{"delay":20}]}}}
        }}
        """
        let response = try JSONDecoder().decode(
            ProxyGroupsResponse.self,
            from: Data(payload.utf8))

        XCTAssertEqual(
            response.proxies["🇭🇰"]?.testUrl,
            "http://connect.rom.miui.com/generate_204")
        XCTAssertNil(response.proxies["微软服务"]?.testUrl)
        XCTAssertEqual(
            response.proxies["DIRECT"]?.delayHistoryByURL["http://connect.rom.miui.com/generate_204"],
            [18, 20])
    }
}
