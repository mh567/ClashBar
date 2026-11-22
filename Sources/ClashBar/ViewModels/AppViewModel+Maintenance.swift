import AppKit
import Foundation

@MainActor
extension AppViewModel {
    func upgradeCore() async {
        guard !self.isCoreUpgradeInFlight else { return }

        self.coreUpgradeFeedbackClearTask?.cancel()
        self.coreUpgradeFeedbackClearTask = nil
        self.coreUpgradeState = .running

        do {
            let response: CoreUpgradeResponse = try await self.clientOrThrow().request(.upgradeCore)
            self.applyCoreUpgradeState(self.coreUpgradeState(from: response))
        } catch {
            self.applyCoreUpgradeState(self.coreUpgradeState(from: error))
        }
    }

    func upgradeGeo() async {
        guard !self.isGeoUpdateInFlight else { return }

        self.geoUpdateFeedbackClearTask?.cancel()
        self.geoUpdateFeedbackClearTask = nil
        self.geoUpdateState = .updating

        do {
            try await self.clientOrThrow().requestNoResponse(.upgradeGeo)
            self.applyGeoUpdateState(.succeeded)
        } catch {
            self.applyGeoUpdateState(.failed(message: self.geoUpdateFailureMessage(from: error)))
        }
    }

    func flushFakeIPCache() async {
        await runNoResponseAction(tr("log.action_name.flush_fakeip_cache")) {
            try await self.clientOrThrow().requestNoResponse(.flushFakeIPCache)
        }
    }

    func flushDNSCache() async {
        await runNoResponseAction(tr("log.action_name.flush_dns_cache")) {
            try await self.clientOrThrow().requestNoResponse(.flushDNSCache)
        }
    }

    var isCoreUpgradeInFlight: Bool {
        if case .running = self.coreUpgradeState {
            return true
        }
        return false
    }

    var isGeoUpdateInFlight: Bool {
        if case .updating = self.geoUpdateState {
            return true
        }
        return false
    }

    private func applyCoreUpgradeState(_ state: CoreUpgradeState) {
        self.coreUpgradeState = state

        switch state {
        case .idle, .running:
            return
        case .succeeded:
            self.appendLog(level: "info", message: tr("log.core_upgrade.updated"))
            Task { [weak self] in
                await self?.refreshCoreVersionAfterUpgradeIfPossible()
            }
        case let .alreadyLatest(version):
            if let version, !version.isEmpty {
                self.version = AppSemanticVersion.normalizedDisplayVersion(from: version)
                self.appendLog(level: "info", message: tr("log.core_upgrade.latest_version", self.version))
            } else {
                self.appendLog(level: "info", message: tr("log.core_upgrade.latest"))
            }
        case let .failed(message):
            self.appendLog(level: "error", message: tr("log.core_upgrade.failed", message))
        }

        self.scheduleCoreUpgradeFeedbackAutoClear()
    }

    private func applyGeoUpdateState(_ state: GeoUpdateState) {
        self.geoUpdateState = state

        switch state {
        case .idle, .updating:
            return
        case .succeeded:
            self.appendLog(level: "info", message: tr("log.geo_update.updated"))
        case let .failed(message):
            self.appendLog(level: "error", message: tr("log.geo_update.failed", message))
        }

        self.scheduleGeoUpdateFeedbackAutoClear()
    }

    private func scheduleCoreUpgradeFeedbackAutoClear() {
        self.coreUpgradeFeedbackClearTask?.cancel()
        self.coreUpgradeFeedbackClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }

            guard let self else { return }
            guard !self.isCoreUpgradeInFlight else { return }
            self.coreUpgradeState = .idle
        }
    }

    private func scheduleGeoUpdateFeedbackAutoClear() {
        self.geoUpdateFeedbackClearTask?.cancel()
        self.geoUpdateFeedbackClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }

            guard let self else { return }
            guard !self.isGeoUpdateInFlight else { return }
            self.geoUpdateState = .idle
        }
    }

    private func refreshCoreVersionAfterUpgradeIfPossible() async {
        do {
            try await Task.sleep(nanoseconds: 750_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }

        do {
            let versionInfo: VersionInfo = try await self.clientOrThrow().request(.version)
            guard !Task.isCancelled else { return }
            self.version = versionInfo.version
        } catch {}
    }

    private func coreUpgradeState(from response: CoreUpgradeResponse) -> CoreUpgradeState {
        if let status = response.status?.trimmedNonEmpty,
           status.caseInsensitiveCompare("ok") == .orderedSame
        {
            return .succeeded
        }

        if let message = response.message?.trimmedNonEmpty {
            return self.coreUpgradeState(fromMessage: message)
        }

        return .failed(message: tr("ui.common.unknown"))
    }

    private func coreUpgradeState(from error: Error) -> CoreUpgradeState {
        if let apiError = error as? APIError,
           case let .statusCode(_, responseBody) = apiError
        {
            if let data = responseBody.data(using: .utf8),
               let response = try? JSONDecoder().decode(CoreUpgradeResponse.self, from: data)
            {
                let state = self.coreUpgradeState(from: response)
                if case let .failed(message) = state, message == tr("ui.common.unknown") {
                    return self.coreUpgradeState(fromMessage: responseBody)
                }
                return state
            }

            return self.coreUpgradeState(fromMessage: responseBody)
        }

        return self.coreUpgradeState(fromMessage: error.localizedDescription)
    }

    private func geoUpdateFailureMessage(from error: Error) -> String {
        let raw: String = if let apiError = error as? APIError,
                             case let .statusCode(_, responseBody) = apiError
        {
            responseBody
        } else {
            error.localizedDescription
        }

        let trimmed = raw.trimmed
        return trimmed.isEmpty ? tr("ui.common.unknown") : trimmed
    }

    private func coreUpgradeState(fromMessage message: String) -> CoreUpgradeState {
        let trimmedMessage = message.trimmed
        guard !trimmedMessage.isEmpty else {
            return .failed(message: tr("ui.common.unknown"))
        }

        if self.isAlreadyLatestCoreUpgradeMessage(trimmedMessage) {
            return .alreadyLatest(version: self.latestVersion(in: trimmedMessage))
        }

        return .failed(message: trimmedMessage)
    }

    private func isAlreadyLatestCoreUpgradeMessage(_ message: String) -> Bool {
        message.range(
            of: "already using latest version",
            options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func latestVersion(in message: String) -> String? {
        let pattern = #"v?\d+(?:\.\d+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.matches(in: message, range: range).last,
              let swiftRange = Range(match.range, in: message)
        else {
            return nil
        }

        let raw = String(message[swiftRange])
        return AppSemanticVersion.normalizedDisplayVersion(from: raw)
    }
}

extension AppViewModel {
    var currentAppVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let short, !short.isEmpty {
            return short
        }
        if let build, !build.isEmpty {
            return build
        }
        return "0.0.1"
    }

    var availableAppUpdate: AppReleaseInfo? {
        guard let latestAppReleaseInfo else { return nil }
        guard !latestAppReleaseInfo.isDraft, !latestAppReleaseInfo.isPrerelease else { return nil }
        guard AppSemanticVersion.isNewerRelease(
            tagName: latestAppReleaseInfo.tagName,
            than: self.currentAppVersionText)
        else {
            return nil
        }
        return latestAppReleaseInfo
    }

    var appReleaseIndexURL: URL? {
        AppReleaseSource.releasesPageURL
    }

    func installAvailableAppUpdate() async -> String? {
        guard !self.isInstallingAppUpdate, let update = self.availableAppUpdate else { return nil }

        self.isInstallingAppUpdate = true
        self.appUpdateInstallPhase = .downloading(progress: 0)
        do {
            try await AppUpdateInstaller.install(
                update,
                bundlesCore: self.bundlesMihomoCore)
            { [weak self] phase in
                Task { @MainActor in
                    self?.appUpdateInstallPhase = phase
                }
            }
        } catch AppUpdateInstaller.Failure.incompatibleAsset {
            self.finishAppUpdateInstall()
            return "ui.footer.app_update.no_asset"
        } catch AppUpdateInstaller.Failure.nonWritableInstallation {
            self.finishAppUpdateInstall()
            return "ui.footer.app_update.install_location"
        } catch {
            // The sheet shows one generic message for every failure, so the step and the
            // underlying reason only survive if they are logged here.
            let reason: String = if case let .staged(stage, underlying) = error as? AppUpdateInstaller.Failure {
                "\(stage.rawValue): \(underlying)"
            } else {
                AppUpdateInstaller.describe(error)
            }
            self.appendLog(level: "error", message: self.tr("log.app_update.install_failed", reason))
            self.finishAppUpdateInstall()
            return "ui.footer.app_update.install_failed"
        }

        self.appUpdateInstallPhase = .relaunching
        // The relaunch helper has already swapped the bundle and is waiting for
        // this process to exit, so this quit must not be blocked by the
        // in-flight install guard.
        self.isInstallingAppUpdate = false
        await self.quitApp()
        self.appUpdateInstallPhase = nil
        return nil
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard self.isInstallingAppUpdate else { return .terminateNow }

        self.runModalAlert(
            style: .warning,
            message: tr("app.update.quit_blocked.title"),
            informative: tr("app.update.quit_blocked.message"),
            buttons: [tr("ui.action.ok")])
        return .terminateCancel
    }

    func consumeAppUpdateRelaunchOutcomeIfNeeded() {
        guard let outcome = AppUpdateInstaller.consumeRelaunchOutcome() else { return }

        switch outcome.result {
        case .succeeded:
            return
        case .rolledBack:
            self.removeFailedUpdateBundleIfNeeded()
            self.appendLog(
                level: "error",
                message: tr(
                    "log.app_update.relaunch_rolled_back",
                    outcome.installedVersion,
                    outcome.previousVersion))
            self.runModalAlert(
                style: .critical,
                message: tr("app.update.relaunch_failed.title"),
                informative: tr(
                    "app.update.relaunch_failed.message.rolled_back",
                    outcome.installedVersion,
                    outcome.previousVersion),
                buttons: [tr("ui.action.ok")])
        case .openFailed:
            self.removeFailedUpdateBundleIfNeeded()
            self.appendLog(
                level: "error",
                message: tr("log.app_update.relaunch_open_failed", outcome.installedVersion))
            self.runModalAlert(
                style: .critical,
                message: tr("app.update.relaunch_failed.title"),
                informative: tr("app.update.relaunch_failed.message.open", outcome.installedVersion),
                buttons: [tr("ui.action.ok")])
        case .timedOut:
            self.appendLog(
                level: "error",
                message: tr("log.app_update.relaunch_timeout", outcome.installedVersion))
            self.runModalAlert(
                style: .warning,
                message: tr("app.update.relaunch_failed.title"),
                informative: tr("app.update.relaunch_failed.message.timeout", outcome.installedVersion),
                buttons: [tr("ui.action.ok")])
        }
    }

    private func finishAppUpdateInstall() {
        self.isInstallingAppUpdate = false
        self.appUpdateInstallPhase = nil
    }

    private func removeFailedUpdateBundleIfNeeded() {
        let leftover = Bundle.main.bundleURL.path + ".failed-update"
        guard FileManager.default.fileExists(atPath: leftover) else { return }
        try? FileManager.default.removeItem(atPath: leftover)
    }

    @discardableResult
    func refreshLatestAppRelease() async -> Bool? {
        guard !self.isLatestAppReleaseCheckInFlight else { return nil }

        self.isLatestAppReleaseCheckInFlight = true
        defer {
            self.isLatestAppReleaseCheckInFlight = false
        }

        do {
            let release = try await AppReleaseService.fetchLatestRelease(
                currentVersion: self.currentAppVersionText,
                architecture: AppUpdateInstaller.architecture,
                bundlesCore: self.bundlesMihomoCore)
            guard !Task.isCancelled else { return nil }
            if self.latestAppReleaseInfo != release {
                self.latestAppReleaseInfo = release
            }
            return true
        } catch {
            return Task.isCancelled ? nil : false
        }
    }
}
