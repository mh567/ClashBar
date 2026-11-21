import Foundation

struct ConfigOverrides: Codable, Equatable {
    var identities: [String: UUID] = [:]
    var fileIDs: [String: String] = [:]
    var values: [UUID: [String: ConfigPatchValue]] = [:]

    static func pathKey(for file: URL) -> String {
        file.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(file.lastPathComponent).path
    }

    mutating func id(for path: String) -> UUID {
        if let id = self.identities[path] { return id }
        let id = UUID()
        self.identities[path] = id
        return id
    }

    mutating func remove(_ path: String) {
        if let id = self.identities.removeValue(forKey: path) {
            self.values.removeValue(forKey: id)
        }
    }

    mutating func move(from oldPath: String, to newPath: String) {
        if let id = self.identities.removeValue(forKey: oldPath) {
            self.remove(newPath)
            self.identities[newPath] = id
        }
    }

    mutating func reconcileFiles(_ files: [String: String], in directory: String) -> [String: String] {
        let previous = self.fileIDs.filter {
            URL(fileURLWithPath: $0.key).deletingLastPathComponent().path == directory
        }
        let newPaths = files.keys.filter { previous[$0] == nil }
        var renames: [String: String] = [:]
        for old in previous.keys where files[old] == nil {
            let matches = newPaths.filter { files[$0] == previous[old] }
            if matches.count == 1, let new = matches.first {
                self.move(from: old, to: new)
                renames[old] = new
            } else {
                self.remove(old)
            }
            self.fileIDs.removeValue(forKey: old)
        }
        self.fileIDs.merge(files) { _, current in current }
        return renames
    }

    static func matches(_ expected: ConfigPatchValue, _ actual: ConfigPatchValue?) -> Bool {
        if case let .string(left) = expected, case let .string(right)? = actual {
            return left.caseInsensitiveCompare(right) == .orderedSame
        }
        return expected == actual
    }

    static func persistableFields(
        from values: [String: ConfigPatchValue]) -> [String: ConfigPatchValue]
    {
        values.filter { key, _ in ConfigOverrideField.isPersistableKey(key) }
    }

    static func request(
        for fields: [String: ConfigPatchValue], tunEnabled: Bool?
    ) -> [String: ConfigPatchValue] {
        var body = fields
        var tun: [String: ConfigPatchValue] = [:]
        tun["enable"] = body.removeValue(forKey: "tun.enable")
        tun["stack"] = body.removeValue(forKey: "tun.stack")
        if !tun.isEmpty {
            tun["enable"] = tun["enable"] ?? tunEnabled.map(ConfigPatchValue.bool)
            if tun["enable"] != nil {
                body["tun"] = .object(tun)
            }
        }
        return body
    }
}

@MainActor
extension AppViewModel {
    var activeConfigOverrideID: UUID? {
        guard !self.isRemoteTarget, let url = self.configService.selectedConfig else { return nil }
        let path = ConfigOverrides.pathKey(for: url)
        if let id = self.configOverrides.identities[path] { return id }
        let id = self.configOverrides.id(for: path)
        self.persistConfigOverrides()
        return id
    }

    var activeConfigOverrides: [String: ConfigPatchValue] {
        guard !self.isRemoteTarget, let url = self.configService.selectedConfig,
              let id = self.configOverrides.identities[ConfigOverrides.pathKey(for: url)]
        else { return [:] }
        return self.configOverrides.values[id] ?? [:]
    }

    func persistConfigOverrides() {
        self.encodeToDefaults(self.configOverrides, key: "config-overrides")
    }

    func removeConfigOverrides(at url: URL) {
        let path = ConfigOverrides.pathKey(for: url)
        if let id = self.configOverrides.identities[path] {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent(".clashbar-loaded-\(id.uuidString).yaml")
            try? FileManager.default.removeItem(at: backup)
        }
        self.configOverrides.remove(path)
        self.configOverrides.fileIDs.removeValue(forKey: path)
        self.persistConfigOverrides()
    }

    @discardableResult
    func reconcileConfigFileIdentities() -> [String: String] {
        guard let directory = self.configService.configDirectory?.standardizedFileURL.resolvingSymlinksInPath().path
        else { return [:] }
        var files: [String: String] = [:]
        for url in self.configService.availableConfigs {
            let path = ConfigOverrides.pathKey(for: url)
            if let metadata = try? FileManager.default.attributesOfItem(atPath: path),
               let device = metadata[.systemNumber], let number = metadata[.systemFileNumber]
            {
                files[path] = "\(device):\(number)"
            }
        }

        var store = self.configOverrides
        let renames = store.reconcileFiles(files, in: directory)
        if store != self.configOverrides {
            self.configOverrides = store
            self.persistConfigOverrides()
        }
        for (old, new) in renames {
            let oldName = URL(fileURLWithPath: old).lastPathComponent
            let newName = URL(fileURLWithPath: new).lastPathComponent
            if let subscription = self.remoteConfigSubscriptions.removeValue(forKey: oldName) {
                self.remoteConfigSubscriptions[newName] = subscription
                self.persistRemoteConfigSubscriptions()
            }
            if let replacement = self.pendingRemoteConfigReplacements.removeValue(forKey: oldName) {
                self.pendingRemoteConfigReplacements[newName] = replacement
                self.persistRemoteConfigReplacements()
            }
            if self.pendingConfigFileNames.remove(oldName) != nil {
                self.pendingConfigFileNames.insert(newName)
            }
        }
        return renames
    }

    func recordConfigOverrides(_ values: [String: ConfigPatchValue], for id: UUID?) {
        guard let id, id == self.activeConfigOverrideID else { return }
        let persistable = ConfigOverrides.persistableFields(from: values)
        guard !persistable.isEmpty else { return }
        self.configOverrides.values[id, default: [:]].merge(persistable) { _, new in new }
        self.runtimeConfigInput?.overrides = self.configOverrides.values[id] ?? [:]
        self.persistConfigOverrides()
    }

    /// Older builds stored `mode` as an override when the proxy mode was switched.
    /// Drop those records once so the mode follows the configuration again.
    func pruneNonPersistableConfigOverrides() {
        var removedAny = false
        for (id, values) in self.configOverrides.values {
            let kept = ConfigOverrides.persistableFields(from: values)
            guard kept.count != values.count else { continue }
            self.configOverrides.values[id] = kept.isEmpty ? nil : kept
            removedAny = true
        }
        if removedAny {
            self.persistConfigOverrides()
            self.runtimeConfigInput?.overrides = self.activeConfigOverrides
        }
    }
}

extension ConfigSnapshot {
    var overrideFields: [String: ConfigPatchValue] {
        [
            "mode": self.mode.map(ConfigPatchValue.string),
            "allow-lan": self.allowLan.map(ConfigPatchValue.bool),
            "bind-address": self.bindAddress.map(ConfigPatchValue.string),
            "ipv6": self.ipv6.map(ConfigPatchValue.bool),
            "tcp-concurrent": self.tcpConcurrent.map(ConfigPatchValue.bool),
            "log-level": self.logLevel.map(ConfigPatchValue.string),
            "port": self.port.map(ConfigPatchValue.int),
            "socks-port": self.socksPort.map(ConfigPatchValue.int),
            "mixed-port": self.mixedPort.map(ConfigPatchValue.int),
            "redir-port": self.redirPort.map(ConfigPatchValue.int),
            "tproxy-port": self.tproxyPort.map(ConfigPatchValue.int),
            "tun.enable": self.tunEnabled.map(ConfigPatchValue.bool),
            "tun.stack": self.tun?.stack.map(ConfigPatchValue.string),
        ].compactMapValues { $0 }
    }
}
