import XCTest
@testable import ClashBar

final class SSIDStrategyRuleTests: XCTestCase {
    func testNormalizeTrimsAndDropsEmptyEntries() {
        let rules = [
            SSIDStrategyRule(ssid: " Home ", configFileName: " home.yaml "),
            SSIDStrategyRule(ssid: "", configFileName: "ignored.yaml"),
            SSIDStrategyRule(ssid: "Office", configFileName: "   "),
        ]

        let normalized = SSIDStrategyRule.normalized(rules)

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].ssid, "Home")
        XCTAssertEqual(normalized[0].configFileName, "home.yaml")
    }

    /// One SSID maps to exactly one config, so a later rule must win.
    func testNormalizeKeepsLastRulePerSSID() {
        let rules = [
            SSIDStrategyRule(ssid: "Home", configFileName: "old.yaml"),
            SSIDStrategyRule(ssid: "Home", configFileName: "new.yaml"),
        ]

        XCTAssertEqual(SSIDStrategyRule.normalized(rules).map(\.configFileName), ["new.yaml"])
    }

    func testUpsertingReplacesExistingBinding() {
        let existing = [SSIDStrategyRule(ssid: "Home", configFileName: "a.yaml")]
        let updated = SSIDStrategyRule.upserting(ssid: "Home", configFileName: "b.yaml", into: existing)

        XCTAssertEqual(updated.map(\.configFileName), ["b.yaml"])
    }

    func testRemovingOnlyAffectsTargetSSID() {
        let rules = [
            SSIDStrategyRule(ssid: "Home", configFileName: "a.yaml"),
            SSIDStrategyRule(ssid: "Office", configFileName: "b.yaml"),
        ]

        let remaining = SSIDStrategyRule.removing(ssid: "Home", from: rules)

        XCTAssertEqual(remaining.map(\.ssid), ["Office"])
    }
}

final class FilterEnumTests: XCTestCase {
    func testRulesTypeFilterClassifiesKnownTypes() {
        XCTAssertTrue(RulesTypeFilter.domain.matches("DOMAIN-SUFFIX"))
        XCTAssertTrue(RulesTypeFilter.domain.matches("GEOSITE"))
        XCTAssertTrue(RulesTypeFilter.ip.matches("IP-CIDR"))
        XCTAssertTrue(RulesTypeFilter.ip.matches("GEOIP"))
        XCTAssertTrue(RulesTypeFilter.ruleSet.matches("RULE-SET"))
        XCTAssertTrue(RulesTypeFilter.other.matches("MATCH"))
        XCTAssertTrue(RulesTypeFilter.all.matches("ANYTHING"))
    }

    /// An empty type must land in "other" rather than being silently dropped.
    func testRulesTypeFilterTreatsMissingTypeAsOther() {
        XCTAssertTrue(RulesTypeFilter.other.matches(nil))
        XCTAssertFalse(RulesTypeFilter.domain.matches(nil))
    }

    func testConnectionsTransportFilterMatchesNetwork() {
        XCTAssertTrue(ConnectionsTransportFilter.tcp.matches("TCP"))
        XCTAssertTrue(ConnectionsTransportFilter.udp.matches("udp"))
        XCTAssertTrue(ConnectionsTransportFilter.other.matches("QUIC"))
        XCTAssertFalse(ConnectionsTransportFilter.other.matches("tcp"))
        XCTAssertTrue(ConnectionsTransportFilter.all.matches(nil))
    }
}

final class ConnectionSnapshotDecodingTests: XCTestCase {
    func testRetainsLimitButReportsTotalCount() throws {
        let items = (0..<200).map {
            #"{"id":"\#($0)","metadata":{"network":"tcp"}}"#
        }.joined(separator: ",")
        let json = Data(#"{"connections":[\#(items)]}"#.utf8)

        let snapshot = try JSONDecoder().decode(ConnectionsSnapshot.self, from: json)

        XCTAssertEqual(snapshot.connections.count, ConnectionsSnapshot.retainedConnectionLimit)
        XCTAssertEqual(snapshot.totalCount, 200)
    }

    func testDecodesAlternativeKeySpellings() throws {
        let json = Data(#"""
        {"connections":[{"id":"x","rule_payload":"cn","chain":["A","B"],
        "metadata":{"destinationHost":"example.com"}}]}
        """#.utf8)

        let snapshot = try JSONDecoder().decode(ConnectionsSnapshot.self, from: json)
        let connection = try XCTUnwrap(snapshot.connections.first)

        XCTAssertEqual(connection.rulePayload, "cn")
        XCTAssertEqual(connection.chains, ["A", "B"])
        XCTAssertEqual(connection.metadata?.host, "example.com")
    }

    func testMissingConnectionsArrayDecodesAsEmpty() throws {
        let snapshot = try JSONDecoder().decode(ConnectionsSnapshot.self, from: Data("{}".utf8))
        XCTAssertTrue(snapshot.connections.isEmpty)
        XCTAssertEqual(snapshot.totalCount, 0)
    }

    func testDelayHistoryIsTrimmedToLimit() throws {
        let entries = (1...10).map { #"{"delay":\#($0)}"# }.joined(separator: ",")
        let url = "https://example.com"
        let json = Data(#"{"extra":{"\#(url)":{"history":[\#(entries)]}}}"#.utf8)
        let node = try JSONDecoder().decode(ProviderProxyNode.self, from: json)
        let samples = try XCTUnwrap(node.delayHistoryByURL[url])

        XCTAssertEqual(samples.count, ProxyDelayHistory.limit)
        XCTAssertEqual(samples.last, 10)
    }

    func testFlexibleBoolAndStringDecoding() throws {
        let json = Data(#"{"tun":{"enable":"true","stack":123}}"#.utf8)
        let config = try JSONDecoder().decode(ConfigSnapshot.self, from: json)

        XCTAssertEqual(config.tunEnabled, true)
        XCTAssertEqual(config.tun?.stack, "123")
    }
}

final class ProxyDelayHistoryTests: XCTestCase {
    func testSharedDirectHistoryKeepsProbeURLsIndependent() throws {
        let payload = Data("""
        {
          "name": "DIRECT",
          "history": [{"delay": 21}, {"delay": 0}],
          "extra": {
            "http://connect.rom.miui.com/generate_204": {"history": [{"delay": 21}]},
            "https://www.gstatic.com/generate_204": {"history": [{"delay": 0}]}
          }
        }
        """.utf8)

        let proxy = try JSONDecoder().decode(ProxyGroup.self, from: payload)
        let providerNode = try JSONDecoder().decode(ProviderProxyNode.self, from: payload)
        XCTAssertEqual(proxy.delayHistoryByURL["http://connect.rom.miui.com/generate_204"], [21])
        XCTAssertEqual(proxy.delayHistoryByURL["https://www.gstatic.com/generate_204"], [0])
        XCTAssertNil(proxy.delayHistoryByURL["https://example.com"])
        XCTAssertEqual(proxy.delayHistoryByURL, providerNode.delayHistoryByURL)
    }

    func testUnscopedHistoryCannotEstablishProbeResult() throws {
        let payload = Data(#"{"name":"DIRECT","history":[{"delay":0}]}"#.utf8)
        let proxy = try JSONDecoder().decode(ProxyGroup.self, from: payload)
        XCTAssertTrue(proxy.delayHistoryByURL.isEmpty)
    }
}
