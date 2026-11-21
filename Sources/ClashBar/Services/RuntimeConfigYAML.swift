import Yams

enum RuntimeConfigYAML {
    private enum MergeError: Error {
        case invalidMapping
        case expansionLimit
    }

    static func merge(yaml: String, settings: String, controller: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try self.render(yaml: yaml, settings: settings, controller: controller)
        }.value
    }

    struct Details: Sendable {
        let yaml: String
        let declaredOnly: [String]
        let runtimeFields: [String]
        let declarationDifferences: [String: String]
        let geoAliasConflicts: [String]
    }

    static func inspect(yaml: String, settings: String, controller: String) async throws -> Details {
        try await Task.detached(priority: .userInitiated) {
            let raw = try Yams.compose(yaml: settings)?.mapping ?? .init([])
            let declarations = try self.expandMergeKeys(Yams.compose(yaml: yaml)?.mapping ?? .init([]))
            let sourceGeo = try self.expandMergeKeys(declarations["geox-url"]?.mapping ?? .init([]))
            let apiGeo = raw["geox-url"]?.mapping ?? .init([])
            let geo = self.normalizeGeoURLKeys(apiGeo)
            let displayKeys = Set(raw.map { $0.key.string ?? "" }).subtracting(["sniffing", "geox-url"])
            var runtimeFields = displayKeys.sorted()
            if raw["sniffing"] != nil { runtimeFields.append("sniffer.enable") }
            var differences: [String: String] = [:]
            for key in displayKeys where key != "tun" {
                if let source = declarations[key]?.scalar?.string, let actual = raw[key]?.scalar?.string,
                   source.caseInsensitiveCompare(actual) != .orderedSame
                {
                    differences[key] = source
                }
            }
            let sourceTun = try self.expandMergeKeys(declarations["tun"]?.mapping ?? .init([]))
            let runtimeTun = raw["tun"]?.mapping ?? .init([])
            for (key, value) in runtimeTun {
                if let name = key.string, let source = sourceTun[key]?.scalar?.string,
                   let actual = value.scalar?.string, source.caseInsensitiveCompare(actual) != .orderedSame
                {
                    differences["tun." + name] = source
                }
            }
            for (key, value) in geo {
                guard let name = key.string else { continue }
                let path = "geox-url." + name
                runtimeFields.append(path)
                if let declaration = sourceGeo[key]?.string, declaration != value.string {
                    differences[path] = declaration
                }
            }
            let conflicts = [("geoip", "geo-ip"), ("geosite", "geo-site")].compactMap { key, alias in
                guard let declared = apiGeo[key]?.string, let alternate = apiGeo[alias]?.string,
                      declared != alternate
                else { return nil as String? }
                return "geox-url." + key
            }
            let declaredOnly = declarations.flatMap { entry -> [String] in
                guard let key = entry.key.string, key != "external-controller" else { return [] }
                if key == "sniffer", raw["sniffing"] != nil, let sniffer = entry.value.mapping {
                    return sniffer.compactMap { item in
                        guard let name = item.key.string, name != "enable" else { return nil }
                        return "sniffer." + name
                    }
                }
                return raw[key] == nil ? [key] : []
            }.sorted()
            return Details(
                yaml: try self.render(yaml: yaml, settings: settings, controller: controller),
                declaredOnly: declaredOnly,
                runtimeFields: runtimeFields.sorted(),
                declarationDifferences: differences,
                geoAliasConflicts: conflicts)
        }.value
    }

    private static func render(yaml: String, settings: String, controller: String) throws -> String {
        guard let liveSettings = try Yams.compose(yaml: settings), var overrides = liveSettings.mapping else {
            throw MergeError.invalidMapping
        }
        overrides["external-controller"] = Node(controller, Tag(.str))
        if let sniffing = overrides["sniffing"] {
            overrides["sniffing"] = nil
            overrides["sniffer"] = ["enable": sniffing]
        }
        if let geoURL = overrides["geox-url"]?.mapping {
            overrides["geox-url"] = .mapping(self.normalizeGeoURLKeys(geoURL))
        }

        var preparation = Preparation()
        let base = try preparation.prepare(Yams.compose(yaml: yaml) ?? [:])
        let live = try preparation.prepare(.mapping(overrides))
        guard let baseMapping = base.mapping ?? (base.tag == Tag(.null) ? Node.Mapping([]) : nil),
              let liveMapping = live.mapping
        else {
            throw MergeError.invalidMapping
        }
        let merged = try self.overlay(liveMapping, onto: baseMapping)
        return try Yams.serialize(
            node: .mapping(merged), canonical: preparation.needsExplicitTags, width: -1, allowUnicode: true)
    }

    private static func normalizeGeoURLKeys(_ mapping: Node.Mapping) -> Node.Mapping {
        var result = mapping
        for (yamlKey, apiKey) in [("geoip", "geo-ip"), ("geosite", "geo-site")] {
            if result[yamlKey] == nil {
                result[yamlKey] = result[apiKey]
            }
            result[apiKey] = nil
        }
        return result
    }

    private static func overlay(_ overrides: Node.Mapping, onto base: Node.Mapping) throws -> Node.Mapping {
        var result = try self.expandMergeKeys(base)
        for (key, value) in overrides {
            if let mapping = value.mapping {
                result[key] = .mapping(try self.overlay(mapping, onto: result[key]?.mapping ?? .init([])))
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func expandMergeKeys(_ mapping: Node.Mapping) throws -> Node.Mapping {
        let mergeTag = Tag(.merge)
        var result = Node.Mapping([], mapping.tag, .block)
        for (key, value) in mapping where key.tag == mergeTag {
            let sources = value.sequence.map(Array.init) ?? [value]
            for source in sources {
                guard let inherited = source.mapping else { throw MergeError.invalidMapping }
                let inheritedEntries = try self.expandMergeKeys(inherited)
                for (inheritedKey, inheritedValue) in inheritedEntries where result[inheritedKey] == nil {
                    result[inheritedKey] = inheritedValue
                }
            }
        }
        for (key, value) in mapping where key.tag != mergeTag {
            result[key] = value
        }
        return result
    }

    private struct Preparation {
        private(set) var needsExplicitTags = false
        private var budget = 64 * 1024 * 1024
        private var inferredTags: [String: Tag] = [:]
        private let implicitTag = Tag(.implicit)
        private let stringTag = Tag(.str)

        mutating func prepare(_ node: Node, depth: Int = 0) throws -> Node {
            self.budget -= 32 + (node.scalar?.string.utf8.count ?? 0)
            guard self.budget >= 0, depth <= 128 else { throw MergeError.expansionLimit }

            switch node {
            case var .scalar(scalar):
                if scalar.style == .any || scalar.style == .plain {
                    let inferred = self.inferredTag(for: scalar.string)
                    if scalar.tag == self.implicitTag {
                        scalar.tag = inferred
                    } else {
                        let tag = node.tag
                        if tag == self.stringTag, inferred != self.stringTag {
                            scalar.style = .singleQuoted
                        } else if tag != inferred {
                            self.needsExplicitTags = true
                        }
                    }
                } else if node.tag != self.stringTag {
                    self.needsExplicitTags = true
                }
                return .scalar(scalar)
            case let .mapping(mapping):
                let pairs = try mapping.map { key, value in
                    (try self.prepare(key, depth: depth + 1), try self.prepare(value, depth: depth + 1))
                }
                return Node(pairs, mapping.tag, mapping.style)
            case let .sequence(sequence):
                let values = try sequence.map { try self.prepare($0, depth: depth + 1) }
                return Node(values, sequence.tag, sequence.style)
            case .alias:
                throw MergeError.invalidMapping
            }
        }

        private mutating func inferredTag(for value: String) -> Tag {
            if let cached = self.inferredTags[value] {
                return cached
            }
            let name = Resolver.default.resolveTag(of: Node(value))
            let tag = name == .str ? self.stringTag : Tag(name)
            if self.inferredTags.count < 4096, value.utf8.count <= 128 {
                self.inferredTags[value] = tag
            }
            return tag
        }
    }
}
