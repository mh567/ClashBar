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

    private static func render(yaml: String, settings: String, controller: String) throws -> String {
        guard let liveSettings = try Yams.compose(yaml: settings), var overrides = liveSettings.mapping else {
            throw MergeError.invalidMapping
        }
        overrides["external-controller"] = Node(controller, Tag(.str))
        if let sniffing = overrides["sniffing"] {
            overrides["sniffing"] = nil
            overrides["sniffer"] = ["enable": sniffing]
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
