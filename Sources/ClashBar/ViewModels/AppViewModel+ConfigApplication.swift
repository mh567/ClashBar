import CryptoKit
import Foundation

@MainActor
extension AppViewModel {
    var isConfigMutationBusy: Bool {
        self.isCoreActionProcessing || self.runtimeConfigReloadCount > 0
            || self.settingsSyncingKey != nil || self.isTunSyncing || self.isProxySyncing
    }

    var configApplicationOutcome: ConfigApplicationOutcome {
        guard self.configApplicationLoaded else { return .failed }
        return self.configApplicationFailure == nil && self.configApplicationIssues.isEmpty ? .applied : .partial
    }

    func configApplicationErrorMessage(_ error: Error) -> String {
        switch error as? ConfigApplicationError {
        case .unverified: self.tr("app.config.apply.unverified")
        case .stale: self.tr("app.config.apply.stale")
        case let .fields(fields): self.tr("app.config.apply.partial", fields.joined(separator: ", "))
        case nil: self.tunErrorMessage(error)
        }
    }

    func lastLoadedConfigURL(for path: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        let key = ConfigOverrides.pathKey(for: url)
        let selected = key == self.configService.selectedConfig.map(ConfigOverrides.pathKey(for:))
        let id = self.configOverrides.identities[key] ?? (selected ? self.activeConfigOverrideID : nil)
        guard let id else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(".clashbar-loaded-\(id.uuidString).yaml")
    }

    func validateDownloadedConfig(_ data: Data, for target: URL) async throws {
        let candidate = target.deletingLastPathComponent().appendingPathComponent(".clashbar-\(UUID()).yaml")
        defer { try? FileManager.default.removeItem(at: candidate) }
        try ConfigImportService.writePrivateConfigData(data, to: candidate)
        try await self.processManager.validateConfigAsync(configPath: candidate.path)
    }

    func acknowledgeLoadedConfig(
        at path: String, yaml: String, status: CoreLifecycleStatus,
        controller: String, overrides: [String: ConfigPatchValue]? = nil, persistBackup: Bool = true
    ) async throws {
        let identity = self.activeConfigOverrideID
        let intended = overrides ?? self.activeConfigOverrides
        let baseline = try await self.fetchRuntimeConfigSnapshot()
        guard self.processManager.status == status, !self.isRemoteTarget, self.activeConfigOverrideID == identity,
              self.configService.selectedConfig.map(ConfigOverrides.pathKey(for:))
                  == ConfigOverrides.pathKey(for: URL(fileURLWithPath: path))
        else { throw ConfigApplicationError.stale }
        let baselineFields = baseline.overrideFields
        let issues = try ConfigReloadAction.baselineListenerIssues(
            yaml: yaml, observed: baselineFields, overrides: intended)
        guard issues.isEmpty else { throw ConfigApplicationError.fields(issues) }
        let expected = try ConfigReloadAction.fields(in: yaml).merging(intended) { _, override in override }
        let data = Data(yaml.utf8)
        self.runtimeConfigInput = RuntimeConfigInput(
            yaml: yaml, status: status, controller: controller,
            version: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            overrides: intended,
            selectedPath: path)
        if persistBackup, let backup = self.lastLoadedConfigURL(for: path) {
            try ConfigImportService.writePrivateConfigData(data, to: backup)
        }

        var observed: ConfigSnapshot? = baseline
        var failure: String?
        do {
            observed = try await self.applyConfigOverrides(intended, baseline: baseline)
        } catch {
            observed = try? await self.fetchRuntimeConfigSnapshot()
            failure = self.configApplicationErrorMessage(error)
        }

        let fields = observed?.overrideFields ?? [:]
        self.configApplicationIssues = expected.keys.sorted().filter {
            guard let value = expected[$0] else { return false }
            return !ConfigOverrides.matches(value, fields[$0])
        }
        self.configApplicationLoaded = true
        if RuntimeConfigInput.readYAML(at: path) == yaml {
            self.pendingConfigFileNames.remove(URL(fileURLWithPath: path).lastPathComponent)
        }
        self.configApplicationFailure = failure ?? (observed == nil ? self.tr("app.config.apply.unverified") : nil)

        if self.isSystemProxyEnabled {
            do {
                let target = try await self.resolveSystemProxyTargetFromRuntimeConfig()
                if try await !self.isSystemProxyConfigured(host: target.host, ports: target.ports) {
                    try await self.applySystemProxy(enabled: true, host: target.host, ports: target.ports)
                    try await self.applyCurrentSystemProxyExceptionsIfNeeded()
                }
                guard try await self.isSystemProxyConfigured(host: target.host, ports: target.ports) else {
                    throw ConfigApplicationError.unverified
                }
                self.systemProxyActiveDisplay = self.buildSystemProxyDisplayString(
                    host: target.host, ports: target.ports)
            } catch {
                self.configApplicationFailure = self.configApplicationErrorMessage(error)
                self.updateSystemProxyOpenFailureHint(for: error)
            }
        }

        if let failure = self.configApplicationFailure {
            self.appendLog(level: "warning", message: failure)
        }
        if !self.configApplicationIssues.isEmpty {
            let differences = self.configApplicationIssues.joined(separator: ", ")
            self.appendLog(level: "warning", message: self.tr("app.config.apply.partial", differences))
        }
        if !intended.isEmpty {
            self.configBaselineFields = baselineFields
        } else {
            self.configBaselineFields = fields
        }
    }

    private func applyConfigOverrides(
        _ fields: [String: ConfigPatchValue], baseline: ConfigSnapshot
    ) async throws -> ConfigSnapshot {
        guard !fields.isEmpty else { return baseline }
        var permitted = fields
        if fields["tun.enable"] == .bool(true), baseline.tunEnabled != true {
            do {
                try await self.ensureTunPermissions(requestIfMissing: false)
            } catch {
                permitted.removeValue(forKey: "tun.enable")
                let body = ConfigOverrides.request(for: permitted, tunEnabled: baseline.tunEnabled)
                if !body.isEmpty {
                    try await self.clientOrThrow().requestNoResponse(.patchConfigs(body: body.mapValues(\.jsonValue)))
                }
                throw error
            }
        }
        let body = ConfigOverrides.request(for: permitted, tunEnabled: baseline.tunEnabled)
        guard !body.isEmpty else { return baseline }
        try await self.clientOrThrow().requestNoResponse(.patchConfigs(body: body.mapValues(\.jsonValue)))
        return try await self.fetchRuntimeConfigSnapshot()
    }

    func restoreConfigField(_ key: String) async {
        guard !self.isConfigMutationBusy, let id = self.activeConfigOverrideID,
              let input = self.runtimeConfigInput, let yaml = input.yaml,
              let path = self.configService.selectedConfig?.path, let backup = self.lastLoadedConfigURL(for: path),
              self.configOverrides.values[id]?[key] != nil
        else { return }
        var remaining = self.activeConfigOverrides
        remaining.removeValue(forKey: key)
        self.runtimeConfigReloadCount += 1
        self.configReadEpoch = UUID()
        defer {
            self.configReadEpoch = UUID()
            self.runtimeConfigReloadCount -= 1
        }
        do {
            guard RuntimeConfigInput.readYAML(at: backup.path) == yaml else {
                throw ConfigApplicationError.stale
            }
            try await self.clientOrThrow().requestNoResponse(.putConfigs(force: true, path: backup.path, payload: nil))
            try await self.acknowledgeLoadedConfig(
                at: path, yaml: yaml, status: input.status, controller: input.controller, overrides: remaining)
            guard let expected = self.configBaselineFields[key], !self.configApplicationIssues.contains(key) else {
                throw ConfigApplicationError.unverified
            }
            let observed = try await self.fetchRuntimeConfigSnapshot()
            guard ConfigOverrides.matches(expected, observed.overrideFields[key]) else {
                throw ConfigApplicationError.unverified
            }
            self.configOverrides.values[id] = remaining
            self.runtimeConfigInput?.overrides = remaining
            self.persistConfigOverrides()
        } catch {
            self.configApplicationFailure = self.configApplicationErrorMessage(error)
            self.settingsErrorMessage = self.tr("app.config.apply.restore_failed", self.configApplicationFailure ?? "")
        }
    }
}
