import Foundation
import Yams

enum ConfigApplicationError: Error {
    case unverified
    case stale
    case recoveryFailed(String)
    case fields([String])
}

enum ConfigApplicationOutcome {
    case skipped
    case applied
    case partial
    case failed
}

enum ConfigReloadAction {
    case reload
    case listeners
    case restart

    private static let ports = ["port", "socks-port", "mixed-port", "redir-port", "tproxy-port"]
    private static let listenerKeys = Set(ports + [
        "allow-lan", "bind-address", "lan-allowed-ips", "lan-disallowed-ips", "skip-auth-prefixes",
        "ss-config", "vmess-config", "tuic-server",
    ])
    private static let reloadKeys = Set([
        "rules", "sub-rules", "rule-providers", "proxy-providers", "proxies", "proxy-groups", "listeners",
        "dns", "hosts", "tun", "mode", "log-level", "ipv6", "tcp-concurrent", "unified-delay", "authentication",
        "profile", "sniffer", "geox-url", "geo-auto-update", "geo-update-interval", "geodata-mode", "geodata-loader",
    ])

    static func between(_ loaded: String?, _ candidate: String?) -> Self {
        guard let loaded, let candidate,
              let oldValues = try? self.mapping(in: loaded), let newValues = try? self.mapping(in: candidate)
        else { return .restart }
        let changes = Set(oldValues.keys).union(newValues.keys).filter {
            !NSDictionary(dictionary: ["field": oldValues[$0] ?? NSNull()])
                .isEqual(to: ["field": newValues[$0] ?? NSNull()])
        }
        if !Set(changes).isSubset(of: self.listenerKeys.union(self.reloadKeys)) { return .restart }
        return self.listenerKeys.isDisjoint(with: changes) ? .reload : .listeners
    }

    static func baselineListenerIssues(
        declared: [String: ConfigPatchValue], observed: [String: ConfigPatchValue],
        overrides: [String: ConfigPatchValue]
    ) -> [String] {
        let checked = self.ports + ["allow-lan", "bind-address", "tun.enable"]
        return checked.filter { key in
            guard overrides[key] == nil, let expected = declared[key], let actual = observed[key] else {
                return false
            }
            return !ConfigOverrides.matches(expected, actual)
        }.sorted()
    }

    static func baselineListenerIssues(
        yaml: String, observed: [String: ConfigPatchValue], overrides: [String: ConfigPatchValue]
    ) throws -> [String] {
        self.baselineListenerIssues(
            declared: try self.fields(in: yaml), observed: observed, overrides: overrides)
    }

    struct ParsedConfig {
        let fields: [String: ConfigPatchValue]
        let tunRouteExcludeAddress: [String]?
    }

    /// Parses the loaded YAML exactly once. Callers on the render path must not
    /// re-parse per frame: a 45 KB config costs ~8 ms with Yams.
    static func parse(_ yaml: String) throws -> ParsedConfig {
        let mapping = try self.mapping(in: yaml)
        let tun = mapping["tun"] as? [String: Any]
        var fields = self.ports.reduce(into: [String: ConfigPatchValue]()) {
            $0[$1] = .int(mapping[$1] as? Int ?? 0)
        }
        fields["allow-lan"] = .bool(mapping["allow-lan"] as? Bool ?? false)
        fields["bind-address"] = .string(mapping["bind-address"] as? String ?? "*")
        fields["tun.enable"] = .bool(tun?["enable"] as? Bool ?? false)
        fields["tun.stack"] = (tun?["stack"] as? String).map(ConfigPatchValue.string)
        for key in ["mode", "log-level"] {
            fields[key] = (mapping[key] as? String).map(ConfigPatchValue.string)
        }
        for key in ["ipv6", "tcp-concurrent"] {
            fields[key] = (mapping[key] as? Bool).map(ConfigPatchValue.bool)
        }
        return ParsedConfig(
            fields: fields,
            tunRouteExcludeAddress: tun?["route-exclude-address"] as? [String])
    }

    static func fields(in yaml: String) throws -> [String: ConfigPatchValue] {
        try self.parse(yaml).fields
    }

    private static func mapping(in yaml: String) throws -> [String: Any] {
        guard let mapping = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ConfigApplicationError.unverified
        }
        return mapping
    }
}
