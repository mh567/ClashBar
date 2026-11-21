import Foundation
import XCTest
import Yams
@testable import ClashBar

final class RuntimeConfigPreviewTests: XCTestCase {
    func testPreviewDetailsReportLoadedSourcesAndGeoDifference() async throws {
        let details = try await RuntimeConfigYAML.inspect(
            yaml: "dns: {enable: true}\nlog-level: warning\ngeox-url: {geoip: https://example.com/source}",
            settings: #"""
            {"log-level":"debug","geox-url":{"geo-ip":"https://example.com/other","geoip":"https://example.com/actual"}}
            """#,
            controller: "127.0.0.1:9090")
        XCTAssertTrue(details.declaredOnly.contains("dns"))
        XCTAssertTrue(details.runtimeFields.contains("geox-url.geoip"))
        XCTAssertEqual(details.declarationDifferences["geox-url.geoip"], "https://example.com/source")
        XCTAssertEqual(details.declarationDifferences["log-level"], "warning")
        XCTAssertEqual(details.geoAliasConflicts, ["geox-url.geoip"])
    }

    func testPreviewMergesLiveOverridesIntoLoadedYAML() async throws {
        let yaml = """
        mixed-port: 7000
        external-controller: old.example:9090
        defaults: &tun-defaults {enable: false, route-exclude-address: [10.0.0.0/8]}
        tun: {<<: *tun-defaults, stack: mixed}
        dns:
          enable: true
        proxies:
        - name: 'on'
          type: direct
          password: !!str 123
          port: 123
        rules:
        - MATCH,on
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let input = RuntimeConfigInput(
            yaml: try XCTUnwrap(RuntimeConfigInput.readYAML(at: file.path)),
            status: .running(pid: 42),
            controller: "127.0.0.1:9090")
        try "mixed-port: 6000".write(to: file, atomically: true, encoding: .utf8)
        let preview = try await input.preview(
            liveSettings: #"{"mixed-port":7890,"tun":{"enable":true,"stack":"system"},"sniffing":false}"#)

        let config = try XCTUnwrap(Yams.compose(yaml: preview))
        XCTAssertEqual(config["mixed-port"]?.int, 7890)
        XCTAssertEqual(config["external-controller"]?.string, "127.0.0.1:9090")
        XCTAssertEqual(config["defaults"]?["enable"]?.bool, false)
        XCTAssertEqual(config["tun"]?["enable"]?.bool, true)
        XCTAssertEqual(config["tun"]?["stack"]?.string, "system")
        XCTAssertEqual(config["tun"]?["route-exclude-address"]?.array(of: String.self), ["10.0.0.0/8"])
        XCTAssertEqual(config["dns"]?["enable"]?.bool, true)
        XCTAssertEqual(config["proxies"]?.array().first?["name"]?.string, "on")
        let password = config["proxies"]?.array().first?["password"]
        XCTAssertEqual(password?.string, "123")
        XCTAssertEqual(password?.tag, Tag(.str))
        XCTAssertEqual(config["proxies"]?.array().first?["port"]?.tag, Tag(.int))
        XCTAssertEqual(config["rules"]?.array(of: String.self), ["MATCH,on"])
        XCTAssertEqual(config["sniffer"]?["enable"]?.bool, false)
        XCTAssertNil(config["sniffing"])
    }

    func testPreviewNormalizesGeoURLKeysAndPrefersMatchingAPIKeys() async throws {
        let aliasPreview = try await RuntimeConfigYAML.merge(
            yaml: "geox-url: {geoip: yaml-geoip, geosite: yaml-geosite}",
            settings: "geox-url: {geo-ip: runtime-geoip, geo-site: runtime-geosite}",
            controller: "127.0.0.1:9090")
        let aliasConfig = try XCTUnwrap(Yams.compose(yaml: aliasPreview))
        XCTAssertEqual(aliasConfig["geox-url"]?["geoip"]?.string, "runtime-geoip")
        XCTAssertEqual(aliasConfig["geox-url"]?["geosite"]?.string, "runtime-geosite")

        let preview = try await RuntimeConfigYAML.merge(
            yaml: """
            geox-url:
              geoip: yaml-geoip
              geosite: yaml-geosite
              mmdb: yaml-mmdb
              asn: yaml-asn
            """,
            settings: """
            geox-url:
              geo-ip: runtime-geoip
              geo-site: runtime-geosite
              geoip: preferred-geoip
              geosite: preferred-geosite
              mmdb: runtime-mmdb
            """,
            controller: "127.0.0.1:9090")

        let config = try XCTUnwrap(Yams.compose(yaml: preview))
        let geoURL = try XCTUnwrap(config["geox-url"])
        XCTAssertEqual(geoURL["geoip"]?.string, "preferred-geoip")
        XCTAssertEqual(geoURL["geosite"]?.string, "preferred-geosite")
        XCTAssertEqual(geoURL["mmdb"]?.string, "runtime-mmdb")
        XCTAssertEqual(geoURL["asn"]?.string, "yaml-asn")
        XCTAssertNil(geoURL["geo-ip"])
        XCTAssertNil(geoURL["geo-site"])
    }

    func testPreviewPreservesNestedRuntimeFields() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigResponse.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = MihomoAPIService(controller: "127.0.0.1:9090", secret: "test-secret", session: session)

        let preview = try await service.runtimeConfigPreview()

        XCTAssertTrue(preview.contains("\n"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any])
        XCTAssertEqual(json["mixed-port"] as? Int, 7890)
        let nested = try XCTUnwrap(json["additional-setting"] as? [String: Any])
        XCTAssertEqual(nested["long-value"] as? String, String(repeating: "x", count: 1024))
    }

    private final class ConfigResponse: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = self.request.url, url.path == "/configs", self.request.httpMethod == "GET",
                  self.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret",
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            let value = String(repeating: "x", count: 1024)
            let body = #"{"mixed-port":7890,"additional-setting":{"long-value":"\#(value)"}}"#
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
