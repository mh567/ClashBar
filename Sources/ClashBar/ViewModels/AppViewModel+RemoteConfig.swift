import AppKit
import Foundation
import UniformTypeIdentifiers

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

@MainActor
extension AppViewModel {
    func importRemoteConfigFile() async {
        guard let configDirectory = ensureConfigDirectoryAvailable() else { return }
        guard let input = promptRemoteConfigImportInput() else { return }

        let urlText = input.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remoteURL = URL(string: urlText), isSupportedRemoteConfigURL(remoteURL) else {
            let message = tr("log.config.remote.invalid_url", urlText)
            appendLog(level: "error", message: message)
            self.presentRemoteConfigImportResultAlert(success: false, message: message)
            return
        }

        let fallbackName = self.inferredRemoteConfigFileName(from: remoteURL)
        guard let fileName = normalizedConfigFileName(input.fileName, fallback: fallbackName) else {
            let message = tr("log.config.import.invalid_filename", input.fileName)
            appendLog(level: "error", message: message)
            self.presentRemoteConfigImportResultAlert(success: false, message: message)
            return
        }

        let targetURL = configDirectory.appendingPathComponent(fileName, isDirectory: false)
        let existsAlready = FileManager.default.fileExists(atPath: targetURL.path)
        let existingIsRemote = self.remoteConfigSubscriptions[fileName] != nil

        if existsAlready, !existingIsRemote {
            guard self.confirmOverwriteConfig(named: fileName) else {
                appendLog(level: "info", message: tr("log.config.import.cancelled", fileName))
                return
            }
        }

        let oldData = try? Data(contentsOf: targetURL)
        let oldSubscription = self.remoteConfigSubscriptions[fileName]
        let epoch = self.configReadEpoch
        let selection = self.configService.selectedConfig
        do {
            let userAgent = await remoteSubscriptionUserAgent()
            let data = try await downloadRemoteConfigData(from: remoteURL, userAgent: userAgent)
            let subscription = RemoteConfigSubscription(
                urlString: remoteURL.absoluteString,
                autoUpdateEnabled: input.autoUpdateEnabled,
                autoUpdateIntervalHours: input.autoUpdateIntervalHours,
                lastUpdateCheckAt: Date())
            guard self.configReadEpoch == epoch, self.configService.selectedConfig == selection,
                  self.configService.configDirectory == configDirectory,
                  self.remoteConfigSubscriptions[fileName] == oldSubscription,
                  (try? Data(contentsOf: targetURL)) == oldData
            else { throw ConfigApplicationError.stale }
            try await self.installDownloadedRemoteSubscription(data, at: targetURL, subscription: subscription)
            let message = tr("log.config.import_remote.success", fileName)
            self.appendLog(level: "info", message: message)
            self.presentRemoteConfigImportResultAlert(success: true, message: message)
        } catch {
            let message = tr("log.config.import_remote.failed", fileName, self.configApplicationErrorMessage(error))
            appendLog(level: "error", message: message)
            self.presentRemoteConfigImportResultAlert(success: false, message: message)
        }
    }

    @discardableResult
    func installDownloadedRemoteSubscription(
        _ data: Data, at target: URL, subscription: RemoteConfigSubscription
    ) async throws -> Bool {
        let name = target.lastPathComponent
        let previous = self.remoteConfigSubscriptions[name]
        let previousReplacement = self.pendingRemoteConfigReplacements[name]
        guard !Task.isCancelled else { throw ConfigApplicationError.stale }
        let existingData = try? Data(contentsOf: target)
        let key = ConfigOverrides.pathKey(for: target)
        let selection = self.configService.selectedConfig
        let directory = self.configService.configDirectory
        let epoch = self.configReadEpoch
        let isActive = !self.isRemoteTarget && self.processManager.isRunning
            && selection.map(ConfigOverrides.pathKey(for:)) == key
        let isReplacement = existingData != nil && previous?.urlString != subscription.urlString
        let replacement = PendingRemoteConfigReplacement(identity: UUID(), subscription: subscription)
        let changed = data != existingData
        let needsApply = isActive && (changed || String(data: data, encoding: .utf8) != self.runtimeConfigInput?.yaml)
        if !isReplacement, !changed, !needsApply {
            self.upsertRemoteConfigSubscription(for: name, subscription: subscription)
            return false
        }
        if isActive {
            guard let loaded = self.runtimeConfigInput, loaded.yaml != nil,
                  loaded.status == self.processManager.status, let loadedPath = loaded.selectedPath,
                  ConfigOverrides.pathKey(for: URL(fileURLWithPath: loadedPath)) == key
            else { throw ConfigApplicationError.unverified }
        }
        let candidate = isReplacement ? replacement.file(beside: target)
            : target.deletingLastPathComponent().appendingPathComponent(".clashbar-\(UUID()).yaml")
        var staged = false
        defer {
            if !staged { try? FileManager.default.removeItem(at: candidate) }
        }

        try ConfigImportService.writePrivateConfigData(data, to: candidate)
        try await self.processManager.validateConfigAsync(configPath: candidate.path)
        func checkTarget() throws {
            guard !Task.isCancelled, self.configService.selectedConfig == selection,
                  self.configService.configDirectory == directory, self.remoteConfigSubscriptions[name] == previous,
                  (try? Data(contentsOf: target)) == existingData
            else { throw ConfigApplicationError.stale }
        }
        try checkTarget()
        guard !self.isConfigMutationBusy, self.configReadEpoch == epoch,
              self.pendingRemoteConfigReplacements[name] == previousReplacement
        else { throw ConfigApplicationError.stale }
        self.discardRemoteConfigReplacement(for: target)
        if isReplacement {
            self.pendingRemoteConfigReplacements[name] = replacement
            self.persistRemoteConfigReplacements()
            self.pendingConfigFileNames.insert(name)
            self.setRemoteConfigMenuState(for: name, phase: .idle, updatedAt: self.remoteConfigUpdatedAt(for: name))
            staged = true
            if isActive {
                let outcome = await self.restartCore()
                guard outcome == .applied else { throw ConfigApplicationError.unverified }
            }
            return changed
        }

        if needsApply {
            let outcome = await self.reloadRefreshedRemoteConfig(named: name, candidate: candidate) {
                try checkTarget()
                guard String(data: data, encoding: .utf8) == self.runtimeConfigInput?.yaml else {
                    throw ConfigApplicationError.stale
                }
                try self.writeConfigData(data, to: target)
                self.pendingConfigFileNames.remove(name)
                self.removeLegacyConfigBackup(for: target.path)
                self.syncConfigSignatureSnapshotToMonitorBaseline()
            }
            guard outcome == .applied else {
                if self.configApplicationLoaded { try checkTarget() }
                throw ConfigApplicationError.unverified
            }
            self.upsertRemoteConfigSubscription(for: name, subscription: subscription)
            return changed
        }
        try self.writeConfigData(data, to: target)
        self.pendingConfigFileNames.insert(name)
        self.upsertRemoteConfigSubscription(for: name, subscription: subscription)
        self.syncConfigSignatureSnapshotToMonitorBaseline()
        self.setRemoteConfigMenuState(for: name, phase: .idle, updatedAt: self.remoteConfigUpdatedAt(for: name))
        return changed
    }

    func commitRemoteConfigReplacement(_ replacement: PendingRemoteConfigReplacement, to target: URL) throws {
        let name = target.lastPathComponent
        guard self.pendingRemoteConfigReplacements[name] == replacement else { throw ConfigApplicationError.stale }
        let data = try Data(contentsOf: replacement.file(beside: target))
        guard String(data: data, encoding: .utf8) == self.runtimeConfigInput?.yaml else {
            throw ConfigApplicationError.stale
        }
        try self.writeConfigData(data, to: target)
        self.removeConfigOverrides(at: target)
        try? FileManager.default.removeItem(at: replacement.file(beside: target))
        self.configOverrides.identities[ConfigOverrides.pathKey(for: target)] = replacement.identity
        self.persistConfigOverrides()
        self.pendingRemoteConfigReplacements.removeValue(forKey: name)
        self.persistRemoteConfigReplacements()
        self.pendingConfigFileNames.remove(name)
        self.upsertRemoteConfigSubscription(for: name, subscription: replacement.subscription)
        self.syncConfigSignatureSnapshotToMonitorBaseline()
        self.setRemoteConfigMenuState(for: name, phase: .applied, updatedAt: self.remoteConfigUpdatedAt(for: name))
    }

    func discardRemoteConfigReplacement(for target: URL, failed: Bool = false) {
        let name = target.lastPathComponent
        guard let pending = self.pendingRemoteConfigReplacements.removeValue(forKey: name) else { return }
        try? FileManager.default.removeItem(at: pending.file(beside: target))
        self.persistRemoteConfigReplacements()
        self.pendingConfigFileNames.remove(name)
        if failed {
            self.setRemoteConfigMenuState(for: name, phase: .applyFailed, updatedAt: self.remoteConfigUpdatedAt(for: name))
        }
    }

    func persistRemoteConfigReplacements() {
        self.encodeToDefaults(self.pendingRemoteConfigReplacements, key: "remote-config-replacements")
    }

    func updateAllRemoteConfigFiles() async -> RemoteConfigUpdateSummary? {
        guard self.ensureConfigDirectoryAvailable() != nil else { return nil }
        self.pruneRemoteConfigSubscriptionsIfNeeded()
        let names = self.remoteConfigSubscriptions.keys.sorted()
        guard !names.isEmpty else {
            self.appendLog(level: "info", message: self.tr("log.config.remote.no_sources"))
            return nil
        }

        var updatedCount = 0
        var failedCount = 0
        for name in names {
            guard !Task.isCancelled else { break }
            switch await self.refreshRemoteConfigFile(named: name) {
            case true?: updatedCount += 1
            case false?: break
            case nil: failedCount += 1
            }
        }

        self.appendLog(level: "info", message: self.tr("log.config.remote.update_summary", updatedCount, failedCount))
        return RemoteConfigUpdateSummary(updatedCount: updatedCount, failedCount: failedCount)
    }

    func deleteConfigFile(named fileName: String) async {
        guard !self.isConfigMutationBusy else { return }
        guard self.confirmDeleteConfig(named: fileName) else { return }
        guard let configDirectory = ensureConfigDirectoryAvailable() else { return }

        let targetURL = configDirectory.appendingPathComponent(fileName, isDirectory: false)
        let isDeletingSelected = fileName == selectedConfigName
        let isCurrentlyRunning = isRuntimeRunning

        do {
            try FileManager.default.removeItem(at: targetURL)
        } catch {
            appendLog(level: "error", message: tr("log.config.delete.failed", fileName, error.localizedDescription))
            return
        }

        self.discardRemoteConfigReplacement(for: targetURL)
        self.pendingConfigFileNames.remove(fileName)
        self.removeConfigOverrides(at: targetURL)
        self.removeRemoteConfigSubscription(for: fileName)
        _ = configService.reloadConfigs()
        syncConfigDisplayState()

        appendLog(level: "info", message: tr("log.config.delete.success", fileName))

        guard isDeletingSelected else { return }

        if let nextConfig = configService.availableConfigs.first {
            configService.selectConfig(nextConfig)
            let nextName = nextConfig.lastPathComponent
            selectedConfigName = nextName
            defaults.set(nextName, forKey: selectedConfigKey)
            appendLog(level: "info", message: tr("log.config.selected", nextName))
            if isCurrentlyRunning {
                await restartCoreIfNeededForConfigSwitch(
                    previousPath: targetURL.path,
                    nextPath: nextConfig.path)
            }
        } else {
            selectedConfigName = "-"
            defaults.removeObject(forKey: selectedConfigKey)
            if isCurrentlyRunning {
                await stopCore(trigger: .manual)
            }
        }
    }

    private func confirmDeleteConfig(named fileName: String) -> Bool {
        self.runModalAlert(
            style: .warning,
            message: tr("app.config.delete.title", fileName),
            informative: tr("app.config.delete.message"),
            buttons: [tr("ui.action.delete"), tr("ui.action.cancel")]) == .alertFirstButtonReturn
    }

    func showSelectedConfigInFinder() {
        guard let configDirectory = ensureConfigDirectoryAvailable() else { return }
        if let selected = configService.selectedConfig, FileManager.default.fileExists(atPath: selected.path) {
            NSWorkspace.shared.activateFileViewerSelecting([selected])
            return
        }

        if !NSWorkspace.shared.open(configDirectory) {
            appendLog(level: "error", message: tr("log.config.show_in_finder.failed", configDirectory.path))
        }
    }

    func showCoreDirectoryInFinder() {
        do {
            try workingDirectoryManager.bootstrapDirectories()
            let coreDirectory = try workingDirectoryManager.normalizeAndValidateWithinRoot(
                workingDirectoryManager.coreDirectoryURL,
                mustBeDirectory: true)
            if !NSWorkspace.shared.open(coreDirectory) {
                appendLog(level: "error", message: tr("log.core.show_in_finder.failed", coreDirectory.path))
            }
        } catch {
            appendLog(
                level: "error",
                message: tr("log.core.show_in_finder.failed", workingDirectoryManager.coreDirectoryURL.path))
        }
    }

    @discardableResult
    func reloadConfigFileList() -> Int? {
        guard self.ensureConfigDirectoryAvailable() != nil else { return nil }
        self.refreshConfigStateAfterMutation()
        let count = configService.availableConfigs.count
        appendLog(level: "info", message: tr("log.config.loaded_count", count))
        return count
    }

    func refreshRemoteConfigMenuStates() {
        let subscriptions = self.remoteConfigSubscriptions
        guard !subscriptions.isEmpty else {
            self.remoteConfigMenuStates = [:]
            return
        }

        var nextStates: [String: RemoteConfigMenuState] = [:]
        nextStates.reserveCapacity(subscriptions.count)

        for (fileName, sub) in subscriptions {
            let updatedAt = self.remoteConfigUpdatedAt(for: fileName)
            nextStates[fileName] = self.mergedRemoteConfigMenuState(
                for: fileName,
                updatedAt: updatedAt,
                subscription: sub)
        }

        self.remoteConfigMenuStates = nextStates
    }

    func remoteConfigMenuState(for fileName: String) -> RemoteConfigMenuState {
        self.remoteConfigMenuStates[fileName] ?? .idle
    }

    @discardableResult
    func refreshRemoteConfigFile(named fileName: String) async -> Bool? {
        guard !self.remoteConfigMenuState(for: fileName).phase.isInProgress,
              self.pendingRemoteConfigReplacements[fileName] == nil
        else { return false }
        guard let configDirectory = self.ensureConfigDirectoryAvailable() else { return nil }

        self.pruneRemoteConfigSubscriptionsIfNeeded()
        let previousPhase = self.remoteConfigMenuState(for: fileName).phase
        self.setRemoteConfigMenuState(for: fileName, phase: .refreshing)
        defer {
            let phase = self.remoteConfigMenuState(for: fileName).phase
            if phase == .refreshing || phase == .validating {
                self.setRemoteConfigMenuState(for: fileName, phase: self.previousApplicationPhase(for: previousPhase))
            }
        }

        guard let sub = self.remoteConfigSubscriptions[fileName],
              let remoteURL = URL(string: sub.urlString),
              isSupportedRemoteConfigURL(remoteURL)
        else {
            let stored = self.remoteConfigSubscriptions[fileName]?.urlString ?? fileName
            let reason = tr("log.config.remote.invalid_url", stored)
            self.appendLog(level: "error", message: tr("log.config.remote.update_item_failed", fileName, reason))
            self.setRemoteConfigMenuState(for: fileName, phase: .failed)
            return nil
        }

        let target = configDirectory.appendingPathComponent(fileName)
        let oldData = try? Data(contentsOf: target)
        let selection = self.configService.selectedConfig
        let epoch = self.configReadEpoch
        let checkAt = Date()
        do {
            let userAgent = await self.remoteSubscriptionUserAgent()
            let data = try await self.downloadRemoteConfigData(from: remoteURL, userAgent: userAgent)
            guard self.configReadEpoch == epoch, self.configService.selectedConfig == selection,
                  self.configService.configDirectory == configDirectory,
                  self.pendingRemoteConfigReplacements[fileName] == nil,
                  self.remoteConfigSubscriptions[fileName] == sub,
                  (try? Data(contentsOf: target)) == oldData
            else { throw ConfigApplicationError.stale }
            self.setRemoteConfigMenuState(for: fileName, phase: .validating)
            let changed = try await self.installDownloadedRemoteSubscription(data, at: target, subscription: sub)
            if self.remoteConfigSubscriptions[fileName] == sub {
                self.recordSubscriptionCheck(sub, for: fileName, at: checkAt)
            }
            if self.remoteConfigMenuState(for: fileName).phase == .validating {
                self.setRemoteConfigMenuState(
                    for: fileName, phase: self.previousApplicationPhase(for: previousPhase),
                    updatedAt: self.remoteConfigUpdatedAt(for: fileName))
            }
            return changed
        } catch ConfigApplicationError.stale {
            if self.configService.configDirectory == configDirectory, self.remoteConfigSubscriptions[fileName] == sub {
                self.setRemoteConfigMenuState(
                    for: fileName, phase: self.previousApplicationPhase(for: previousPhase),
                    updatedAt: self.remoteConfigUpdatedAt(for: fileName))
            }
            return false
        } catch {
            guard !Task.isCancelled, self.configService.configDirectory == configDirectory,
                  self.configService.selectedConfig == selection, self.remoteConfigSubscriptions[fileName] == sub
            else { return false }
            self.recordSubscriptionCheck(sub, for: fileName, at: checkAt)
            self.appendLog(
                level: "error",
                message: self.tr(
                    "log.config.remote.update_item_failed", fileName, self.configApplicationErrorMessage(error)))
            if self.remoteConfigMenuState(for: fileName).phase != .applyFailed {
                self.setRemoteConfigMenuState(for: fileName, phase: .failed)
            }
            return nil
        }
    }

    private func previousApplicationPhase(for phase: RemoteConfigRefreshPhase) -> RemoteConfigRefreshPhase {
        switch phase {
        case .applied, .partiallyApplied, .applyFailed: phase
        default: .idle
        }
    }

    @discardableResult
    func reloadRefreshedRemoteConfig(
        named name: String, candidate: URL? = nil, commit: (() throws -> Void)? = nil
    ) async -> ConfigApplicationOutcome {
        guard self.selectedConfigName == name else { return .skipped }
        let subscription = self.remoteConfigSubscriptions[name]
        let attempt = RemoteConfigRefreshPhase.applying(UUID())
        self.setRemoteConfigMenuState(for: name, phase: attempt, updatedAt: self.remoteConfigUpdatedAt(for: name))
        let outcome = await self.reloadConfig(candidate: candidate, commit: commit)
        guard self.remoteConfigMenuState(for: name).phase == attempt else { return outcome }
        let currentOutcome = self.remoteConfigSubscriptions[name] == subscription ? outcome : .skipped
        let phase: RemoteConfigRefreshPhase = switch currentOutcome {
        case .skipped: .idle
        case .applied: .applied
        case .partial: .partiallyApplied
        case .failed: .applyFailed
        }
        self.setRemoteConfigMenuState(for: name, phase: phase, updatedAt: self.remoteConfigUpdatedAt(for: name))
        return currentOutcome
    }

    @discardableResult
    func reloadConfig(candidate: URL? = nil, commit: (() throws -> Void)? = nil) async -> ConfigApplicationOutcome {
        guard !self.isRemoteTarget else { return .skipped }
        let target = self.configService.selectedConfig
        while self.isConfigMutationBusy {
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return .skipped }
        }
        guard !self.isRemoteTarget, self.isRuntimeRunning, self.configService.selectedConfig == target,
              let path = target?.path
        else { return .skipped }

        let oldInput = self.runtimeConfigInput
        let candidatePath = candidate?.path ?? path
        guard let yaml = RuntimeConfigInput.readYAML(at: candidatePath) else {
            self.configApplicationFailure = self.tr("app.config.apply.unverified")
            return .failed
        }
        let pendingReplacement = self.pendingRemoteConfigReplacements[URL(fileURLWithPath: path).lastPathComponent]
        let action = ConfigReloadAction.between(oldInput?.yaml, yaml)
        if (candidate == nil && pendingReplacement != nil) || action == .restart {
            return await self.restartCore(candidate: candidate, commit: commit)
        }

        self.runtimeConfigReloadCount += 1
        self.configReadEpoch = UUID()
        defer {
            self.configReadEpoch = UUID()
            self.runtimeConfigReloadCount -= 1
        }
        if let error = await self.configValidationFailureDetails(configPath: candidatePath) {
            self.configApplicationFailure = error
            return .failed
        }
        let oldFields = await self.loadedConfigFields(for: oldInput)
        do {
            let force = action == .listeners
            let status = self.processManager.status
            let controller = oldInput?.controller ?? self.controller
            let client = try self.clientOrThrow()
            try await client.requestNoResponse(.putConfigs(force: force, path: path, payload: yaml))
            try await self.acknowledgeLoadedConfig(at: path, yaml: yaml, status: status, controller: controller)
            if let commit {
                try self.requireConfigApplied()
                try commit()
            }
            let message = self.tr("log.action.success", self.tr("log.action_name.reload_config"))
            self.appendLog(level: "info", message: message)
            return self.configApplicationOutcome
        } catch {
            let failure = self.configApplicationErrorMessage(error)
            self.configApplicationFailure = failure
            if let oldInput {
                do {
                    try await self.restoreLoadedConfig(oldInput, at: path, matching: oldFields)
                    self.reportRestoredConfig(after: failure)
                } catch {
                    self.clearLoadedConfigState()
                    self.configApplicationFailure = self.tr("app.config.apply.recovery_failed", failure)
                }
            }
            self.appendLog(level: "error", message: self.configApplicationFailure ?? "")
            return .failed
        }
    }

    func ensureConfigDirectoryAvailable() -> URL? {
        if let configDirectory = configService.configDirectory {
            return configDirectory
        }

        do {
            try workingDirectoryManager.bootstrapDirectories()
            configService.setConfigDirectory(workingDirectoryManager.configDirectoryURL)
            self.refreshConfigStateAfterMutation()
            return configService.configDirectory
        } catch {
            appendLog(level: "error", message: tr("log.working_dir_init_failed", error.localizedDescription))
            return nil
        }
    }

    private func refreshConfigStateAfterMutation() {
        _ = configService.reloadConfigs()
        if self.syncSelectedConfigSelection(configService.selectedConfig) == nil {
            selectedConfigName = "-"
            defaults.removeObject(forKey: selectedConfigKey)
        }
        syncConfigDisplayState()
    }

    @discardableResult
    func syncSelectedConfigSelection(_ selected: URL?) -> String? {
        self.configDirectoryMonitor?.updateSelectedFile(selected)
        guard let selected else { return nil }
        selectedConfigName = selected.lastPathComponent
        defaults.set(selected.lastPathComponent, forKey: selectedConfigKey)
        return selected.path
    }

    func shouldAutoReloadCurrentConfig(updatedFileNames: Set<String>) -> Bool {
        guard !updatedFileNames.isEmpty else { return false }
        guard isRuntimeRunning else { return false }
        guard !isRemoteTarget else { return false }
        return updatedFileNames.contains(selectedConfigName)
    }

    @discardableResult
    func writeConfigData(_ data: Data, to targetURL: URL) throws -> Bool {
        try configService.writeConfigData(data, to: targetURL)
    }

    func confirmOverwriteConfig(named fileName: String) -> Bool {
        self.runModalAlert(
            style: .warning,
            message: tr("app.config.import.overwrite.title", fileName),
            informative: tr("app.config.import.overwrite.message"),
            buttons: [tr("ui.action.overwrite"), tr("ui.action.cancel")]) == .alertFirstButtonReturn
    }

    private func presentRemoteConfigImportResultAlert(success: Bool, message: String) {
        self.runModalAlert(
            style: success ? .informational : .warning,
            message: success
                ? tr("app.config.remote_import.alert.success.title")
                : tr("app.config.remote_import.alert.failure.title"),
            informative: message,
            buttons: [tr("ui.action.ok")])
    }

    private struct RemoteConfigImportInput {
        let urlString: String
        let fileName: String
        let autoUpdateEnabled: Bool
        let autoUpdateIntervalHours: Int
    }

    private func promptRemoteConfigImportInput() -> RemoteConfigImportInput? {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 142))

        let urlLabel = NSTextField(labelWithString: tr("ui.quick.remote.url_label"))
        urlLabel.font = .systemFont(ofSize: T.FontSize.callout, weight: .medium)
        urlLabel.frame = NSRect(x: 0, y: 124, width: 340, height: 16)

        let urlField = NSTextField(frame: NSRect(x: 0, y: 98, width: 340, height: 24))
        urlField.placeholderString = tr("ui.quick.remote.url_placeholder")

        let fileLabel = NSTextField(labelWithString: tr("ui.quick.remote.filename_label"))
        fileLabel.font = .systemFont(ofSize: T.FontSize.callout, weight: .medium)
        fileLabel.frame = NSRect(x: 0, y: 76, width: 340, height: 16)

        let fileField = NSTextField(frame: NSRect(x: 0, y: 50, width: 340, height: 24))
        fileField.placeholderString = tr("ui.quick.remote.filename_placeholder")

        let separator = NSBox(frame: NSRect(x: 0, y: 38, width: 340, height: 1))
        separator.boxType = .separator

        let autoUpdateCheckbox = NSButton(
            checkboxWithTitle: tr("ui.quick.remote.auto_update_label"),
            target: nil,
            action: nil)
        autoUpdateCheckbox.frame = NSRect(x: 0, y: 8, width: 140, height: 22)
        autoUpdateCheckbox.state = .on

        let intervalUnit = NSTextField(labelWithString: tr("ui.quick.remote.interval_unit"))
        intervalUnit.font = .systemFont(ofSize: T.FontSize.callout, weight: .regular)
        intervalUnit.textColor = .secondaryLabelColor
        intervalUnit.frame = NSRect(x: 306, y: 12, width: 34, height: 16)

        let intervalField = NSTextField(frame: NSRect(x: 252, y: 8, width: 50, height: 22))
        intervalField.stringValue = "\(RemoteConfigSubscription.defaultAutoUpdateIntervalHours)"
        intervalField.alignment = .center

        let eachLabel = NSTextField(labelWithString: tr("ui.quick.remote.interval_each"))
        eachLabel.font = .systemFont(ofSize: T.FontSize.callout, weight: .regular)
        eachLabel.textColor = .secondaryLabelColor
        eachLabel.frame = NSRect(x: 220, y: 12, width: 28, height: 16)

        container.addSubview(urlLabel)
        container.addSubview(urlField)
        container.addSubview(fileLabel)
        container.addSubview(fileField)
        container.addSubview(separator)
        container.addSubview(autoUpdateCheckbox)
        container.addSubview(eachLabel)
        container.addSubview(intervalField)
        container.addSubview(intervalUnit)

        let response = self.runModalAlert(
            style: .informational,
            message: tr("ui.quick.import_remote_config"),
            informative: tr("app.config.remote_import.prompt"),
            buttons: [tr("ui.action.import"), tr("ui.action.cancel")]) { $0.accessoryView = container }
        guard response == .alertFirstButtonReturn else { return nil }

        let autoUpdate = autoUpdateCheckbox.state == .on
        let intervalHours = max(
            RemoteConfigSubscription.minimumAutoUpdateIntervalHours,
            Int(intervalField.stringValue) ?? RemoteConfigSubscription.defaultAutoUpdateIntervalHours)

        return RemoteConfigImportInput(
            urlString: urlField.stringValue,
            fileName: fileField.stringValue,
            autoUpdateEnabled: autoUpdate,
            autoUpdateIntervalHours: intervalHours)
    }

    func normalizedConfigFileName(_ fileName: String, fallback: String? = nil) -> String? {
        configService.normalizedConfigFileName(fileName, fallback: fallback)
    }

    private func inferredRemoteConfigFileName(from remoteURL: URL) -> String {
        configService.inferredRemoteConfigFileName(from: remoteURL)
    }

    func isSupportedRemoteConfigURL(_ url: URL) -> Bool {
        configService.isSupportedRemoteConfigURL(url)
    }

    private func downloadRemoteConfigData(from remoteURL: URL, userAgent: String? = nil) async throws -> Data {
        try await configService.downloadRemoteConfigData(from: remoteURL, userAgent: userAgent)
    }

    private static let defaultMihomoVersionForUserAgent = "v1.19.27"

    private func remoteSubscriptionUserAgent() async -> String {
        let version = await resolvedMihomoVersionForSubscriptionUserAgent()
        return "clash.meta/\(version)"
    }

    private func resolvedMihomoVersionForSubscriptionUserAgent() async -> String {
        if let current = normalizedMihomoVersionForUserAgent(self.version) {
            return current
        }

        guard let client = try? clientOrThrow() else {
            return Self.defaultMihomoVersionForUserAgent
        }

        guard let fetched: VersionInfo = try? await client.request(.version) else {
            return Self.defaultMihomoVersionForUserAgent
        }

        let normalized = self.normalizedMihomoVersionForUserAgent(fetched.version) ?? Self
            .defaultMihomoVersionForUserAgent
        if normalized != Self.defaultMihomoVersionForUserAgent {
            self.version = normalized
        }
        return normalized
    }

    private func normalizedMihomoVersionForUserAgent(_ rawVersion: String) -> String? {
        let trimmed = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return nil }
        return trimmed
    }

    private func recordSubscriptionCheck(
        _ subscription: RemoteConfigSubscription, for fileName: String, at date: Date
    ) {
        self.remoteConfigSubscriptions[fileName] = subscription.markChecked(at: date)
        self.persistRemoteConfigSubscriptions()
        self.refreshRemoteConfigMenuStates()
    }

    private func upsertRemoteConfigSubscription(for fileName: String, subscription: RemoteConfigSubscription) {
        guard self.remoteConfigSubscriptions[fileName] != subscription else { return }
        remoteConfigSubscriptions[fileName] = subscription
        persistRemoteConfigSubscriptions()
        self.restartRemoteConfigBackgroundTasksIfNeeded()
        self.refreshConfigStateAfterMutation()
    }

    func removeRemoteConfigSubscription(for fileName: String) {
        guard remoteConfigSubscriptions[fileName] != nil else { return }
        remoteConfigSubscriptions.removeValue(forKey: fileName)
        persistRemoteConfigSubscriptions()
        self.restartRemoteConfigBackgroundTasksIfNeeded()
        self.refreshConfigStateAfterMutation()
    }

    private func remoteConfigUpdatedAt(for fileName: String) -> Date? {
        guard let configURL = self.configService.availableConfigs.first(where: { $0.lastPathComponent == fileName })
        else {
            return nil
        }
        return try? configURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func mergedRemoteConfigMenuState(
        for fileName: String,
        updatedAt: Date?,
        subscription: RemoteConfigSubscription) -> RemoteConfigMenuState
    {
        let current = self.remoteConfigMenuStates[fileName] ?? .idle
        let phase = current.phase.isInProgress || current.updatedAt == updatedAt ? current.phase : .idle
        return RemoteConfigMenuState(
            updatedAt: updatedAt,
            phase: phase,
            autoUpdateEnabled: subscription.autoUpdateEnabled,
            nextUpdateAt: subscription.nextUpdateAt())
    }

    private func setRemoteConfigMenuState(
        for fileName: String,
        phase: RemoteConfigRefreshPhase,
        updatedAt: Date? = nil)
    {
        let existing = self.remoteConfigMenuStates[fileName]
        let sub = self.remoteConfigSubscriptions[fileName]
        let resolvedUpdatedAt = updatedAt ?? existing?.updatedAt
        self.remoteConfigMenuStates[fileName] = RemoteConfigMenuState(
            updatedAt: resolvedUpdatedAt,
            phase: phase,
            autoUpdateEnabled: sub?.autoUpdateEnabled ?? false,
            nextUpdateAt: sub?.nextUpdateAt())
    }

    func startRemoteConfigAutoUpdateTaskIfNeeded() {
        guard remoteConfigAutoUpdateTask == nil || remoteConfigAutoUpdateTask?.isCancelled == true else { return }
        let hasAutoUpdate = remoteConfigSubscriptions.values.contains { $0.autoUpdateEnabled }
        guard hasAutoUpdate else { return }
        remoteConfigAutoUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.performDueRemoteConfigAutoUpdatesIfNeeded()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
            }
        }
    }

    func stopRemoteConfigAutoUpdateTask() {
        remoteConfigAutoUpdateTask?.cancel()
        remoteConfigAutoUpdateTask = nil
    }

    func restartRemoteConfigAutoUpdateTaskIfNeeded() {
        self.stopRemoteConfigAutoUpdateTask()
        self.startRemoteConfigAutoUpdateTaskIfNeeded()
    }

    func restartRemoteConfigBackgroundTasksIfNeeded() {
        self.restartRemoteConfigAutoUpdateTaskIfNeeded()
        self.stopRemoteConfigMenuRefreshTimer()
        self.startRemoteConfigMenuRefreshTimerIfNeeded()
    }

    func performDueRemoteConfigAutoUpdatesIfNeeded() async {
        let due = remoteConfigSubscriptions
            .compactMap { $0.value.isDue() ? $0.key : nil }
            .sorted()
        guard !due.isEmpty else { return }
        for fileName in due {
            guard !Task.isCancelled else { break }
            await self.refreshRemoteConfigFile(named: fileName)
        }
    }

    func startRemoteConfigMenuRefreshTimerIfNeeded() {
        guard remoteConfigMenuRefreshTask == nil || remoteConfigMenuRefreshTask?.isCancelled == true else { return }
        guard !remoteConfigSubscriptions.isEmpty else { return }
        remoteConfigMenuRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
                self?.refreshRemoteConfigMenuStates()
            }
        }
    }

    func stopRemoteConfigMenuRefreshTimer() {
        remoteConfigMenuRefreshTask?.cancel()
        remoteConfigMenuRefreshTask = nil
    }
}
