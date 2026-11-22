import Foundation

@MainActor
extension AppViewModel {
    var pendingCoreSettingsCount: Int {
        self.coreSettingsEdits.count + self.coreSettingsRestores.count
    }

    var canApplyCoreSettings: Bool {
        !self.isApplyingCoreSettings && !self.isConfigMutationBusy && (self.isRemoteTarget || self.isRuntimeRunning)
    }

    func coreSettingValue(_ field: ConfigOverrideField) -> ConfigPatchValue? {
        if self.coreSettingsRestores.contains(field.rawValue) {
            return self.configBaselineFields[field.rawValue]
        }
        return self.coreSettingsEdits[field] ?? self.runtimeValue(for: field)
    }

    func stageCoreSetting(_ field: ConfigOverrideField, value: ConfigPatchValue) {
        guard !self.isApplyingCoreSettings else { return }
        self.coreSettingsRestores.remove(field.rawValue)
        let runtime = self.runtimeValue(for: field)
        if field.group == .ports, case let .string(text) = value, case let .string(current)? = runtime {
            let parsed = ProxyPortsDraft.parsedPort(text)
            self.coreSettingsEdits[field] = parsed != nil && parsed == ProxyPortsDraft.parsedPort(current)
                ? nil : value
        } else if field == .mode, !self.isRemoteTarget {
            let alreadyPinned = ConfigOverrides.matches(value, self.activeConfigOverrides[field.rawValue])
            self.coreSettingsEdits[field] = alreadyPinned && ConfigOverrides.matches(value, runtime) ? nil : value
        } else {
            self.coreSettingsEdits[field] = ConfigOverrides.matches(value, runtime) ? nil : value
        }
        self.coreSettingsError = nil
    }

    func stageCoreSettingsRestore(_ keys: Set<String>) {
        guard self.canRestoreConfigField else { return }
        let overridden = keys.intersection(self.activeConfigOverrides.keys)
        self.coreSettingsRestores.formUnion(overridden)
        self.coreSettingsEdits = self.coreSettingsEdits.filter { !overridden.contains($0.key.rawValue) }
        self.coreSettingsError = nil
    }

    func undoCoreSettingRestore(_ field: ConfigOverrideField) {
        guard !self.isApplyingCoreSettings else { return }
        self.coreSettingsRestores.remove(field.rawValue)
        self.coreSettingsError = nil
    }

    func discardCoreSettings() {
        self.coreSettingsEdits = [:]
        self.coreSettingsRestores = []
        self.coreSettingsError = nil
    }

    func applyCoreSettings() async {
        guard self.pendingCoreSettingsCount > 0, self.canApplyCoreSettings,
              self.coreSettingsRestores.isEmpty || self.canRestoreConfigField
        else { return }

        var values: [String: ConfigPatchValue] = [:]
        var blocked: [ConfigSubmitGroup: String] = [:]
        for field in ConfigOverrideField.allCases {
            guard let edit = self.coreSettingsEdits[field] else { continue }
            if field.group == .ports {
                guard case let .string(text) = edit, let port = ProxyPortsDraft.parsedPort(text) else {
                    blocked[field.submitGroup] = blocked[field.submitGroup]
                        ?? self.tr("ui.settings.core.invalid_port", self.tr(field.titleKey))
                    continue
                }
                values[field.rawValue] = .int(port)
            } else {
                values[field.rawValue] = edit
            }
        }

        if values[ConfigOverrideField.tunStack.rawValue] == .string("mips"), !self.isMipsStackSupported {
            blocked[.tun] = self.tr("app.tun.mips_requires_upgrade", Self.mipsStackMinimumCoreVersion)
        }
        self.isApplyingCoreSettings = true
        self.coreSettingsError = nil
        self.settingsSavedMessage = nil
        defer { self.isApplyingCoreSettings = false }

        guard self.coreSettingsRestores.isEmpty else {
            // A reload carries every field at once, so one invalid draft blocks it.
            guard blocked.isEmpty else {
                self.applyCoreSettingsFailure(self.coreSettingsFailure(blocked, appliedGroups: 0))
                return
            }
            do {
                try await self.applyCoreSettingsRestores(self.coreSettingsRestores, edits: values)
                self.reportCoreSettingsApplied()
                self.discardCoreSettings()
            } catch {
                self.coreSettingsError = self.configApplicationErrorMessage(error)
            }
            return
        }

        await self.applyCoreSettingGroups(values, blocked: blocked)
    }

    private func reportCoreSettingsApplied() {
        let message = self.tr("ui.settings.core.applied")
        self.settingsSavedMessage = message
        self.scheduleSettingsFeedbackAutoClearIfNeeded(message: message)
    }

    /// Submits each submit group on its own. A group carries the fields that
    /// constrain each other, so a rejection only rolls back that group and leaves
    /// the other drafts applied.
    private func applyCoreSettingGroups(
        _ values: [String: ConfigPatchValue], blocked: [ConfigSubmitGroup: String]
    ) async {
        // One baseline serves every group: rollback and verification both compare
        // against the same pre-apply state.
        let baseline = try? await self.fetchRuntimeConfigSnapshot()
        var failures = blocked
        var applied = 0
        for group in ConfigSubmitGroup.ordered where failures[group] == nil {
            var fields: [String: ConfigPatchValue] = [:]
            for field in group.fields {
                guard let value = values[field.rawValue] else { continue }
                fields[field.rawValue] = value
            }
            guard !fields.isEmpty else { continue }

            let success = await self.patchConfigBody(
                fields, syncingKey: self.tr(group.titleKey), baseline: baseline)
            guard success else {
                failures[group] = self.settingsErrorMessage ?? self.tr("app.config.apply.unverified")
                self.settingsErrorMessage = nil
                continue
            }
            applied += 1
            for field in group.fields {
                self.coreSettingsEdits.removeValue(forKey: field)
            }
        }
        self.settingsErrorMessage = nil

        guard failures.isEmpty else {
            self.applyCoreSettingsFailure(self.coreSettingsFailure(failures, appliedGroups: applied))
            return
        }
        self.reportCoreSettingsApplied()
    }

    /// Every failing group keeps its own reason, and the wording only claims that
    /// the remaining groups applied when at least one actually did.
    func coreSettingsFailure(
        _ failures: [ConfigSubmitGroup: String], appliedGroups: Int
    ) -> CoreSettingsFailure {
        let ordered = ConfigSubmitGroup.ordered.filter { failures[$0] != nil }
        guard ordered.count > 1 else {
            return .reason(failures[ordered.first ?? .ports] ?? "")
        }
        let details = ordered.compactMap { group in
            failures[group].map { "\(self.tr(group.titleKey)): \($0)" }
        }.joined(separator: " ")
        return .grouped(key: appliedGroups > 0 ? "ui.settings.core.partial_failed" : "ui.settings.core.all_failed",
                        details: details)
    }

    private func applyCoreSettingsFailure(_ failure: CoreSettingsFailure) {
        switch failure {
        case let .reason(text):
            self.coreSettingsError = text
        case let .grouped(key, details):
            self.coreSettingsError = self.tr(key, details)
        }
    }

    func syncEditableSettings(from config: ConfigSnapshot) {
        let incoming = EditableSettingsSnapshot(config: config)
            .withTunEnabled(self.isAwaitingTunRecovery ? self.isTunEnabled : nil)

        guard let previous = lastSyncedEditableSettings else {
            self.applyEditableSettingsSnapshotToUI(incoming)
            lastSyncedEditableSettings = incoming
            persistEditableSettingsSnapshot()
            return
        }

        suppressSettingsPersistence = true
        self.isTunEnabled = incoming.tunEnabled

        let boolFields: [(ReferenceWritableKeyPath<AppViewModel, Bool>, KeyPath<EditableSettingsSnapshot, Bool>)] = [
            (\.settingsAllowLan, \.allowLan),
            (\.settingsIPv6, \.ipv6),
            (\.settingsTCPConcurrent, \.tcpConcurrent),
        ]
        self.syncEditableFields(from: previous, to: incoming, fields: boolFields)

        self.syncEditableFields(
            from: previous,
            to: incoming,
            fields: [
                (\.settingsLogLevel, \.logLevel),
                (\.settingsPort, \.port),
                (\.settingsSocksPort, \.socksPort),
                (\.settingsMixedPort, \.mixedPort),
                (\.settingsRedirPort, \.redirPort),
                (\.settingsTProxyPort, \.tproxyPort),
            ])
        suppressSettingsPersistence = false

        self.lastSyncedEditableSettings = incoming
        self.persistEditableSettingsSnapshot()
    }

    func currentEditableSettingsSnapshot() -> EditableSettingsSnapshot {
        EditableSettingsSnapshot(
            mode: currentMode,
            allowLan: settingsAllowLan,
            ipv6: settingsIPv6,
            tcpConcurrent: settingsTCPConcurrent,
            tunEnabled: isTunEnabled,
            logLevel: settingsLogLevel,
            port: settingsPort,
            socksPort: settingsSocksPort,
            mixedPort: settingsMixedPort,
            redirPort: settingsRedirPort,
            tproxyPort: settingsTProxyPort)
    }

}
