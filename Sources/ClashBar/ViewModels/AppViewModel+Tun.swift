import Foundation

enum TunModeError: LocalizedError {
    case runtimeStateMismatch(expected: Bool)

    var errorDescription: String? {
        switch self {
        case let .runtimeStateMismatch(expected):
            "TUN runtime state mismatch. expected=\(expected)"
        }
    }
}

@MainActor
extension AppViewModel {
    func toggleTunMode(_ enabled: Bool) async {
        guard !self.isConfigMutationBusy else { return }
        let overrideID = self.activeConfigOverrideID

        self.isTunSyncing = true
        self.configReadEpoch = UUID()
        defer {
            self.configReadEpoch = UUID()
            self.isTunSyncing = false
        }

        do {
            if enabled, !self.isRemoteTarget {
                try await self.ensureTunPermissions(requestIfMissing: true)
            }

            guard self.isRemoteTarget || self.isRuntimeRunning else { return }
            try await self.patchTunConfig(enable: enabled)

            let config = try await fetchRuntimeConfigSnapshot()
            let actualState = config.tunEnabled ?? false
            isTunEnabled = actualState
            persistEditableSettingsSnapshot()

            if config.tunEnabled == enabled {
                self.recordConfigOverrides(["tun.enable": .bool(enabled)], for: overrideID)
                appendLog(
                    level: "info",
                    message: tr("log.tun.toggled", enabled ? tr("log.tun.enabled") : tr("log.tun.disabled")))
            } else {
                appendLog(
                    level: "error",
                    message: tr("log.tun.toggle_failed", tr("app.tun.error.runtime_state_mismatch")))
            }
        } catch {
            appendLog(level: "error", message: tr("log.tun.toggle_failed", self.tunErrorMessage(error)))
            await self.refreshTunStatusFromRuntimeConfig()
        }
    }

    static let mipsStackMinimumCoreVersion = "1.19.31"

    var isMipsStackSupported: Bool {
        guard let current = AppSemanticVersion(self.version),
              let minimum = AppSemanticVersion(Self.mipsStackMinimumCoreVersion)
        else {
            return false
        }
        return current >= minimum
    }

    func selectTunStack(_ stack: String) async {
        guard !self.isConfigMutationBusy else { return }
        let overrideID = self.activeConfigOverrideID

        if stack.caseInsensitiveCompare("mips") == .orderedSame, !self.isMipsStackSupported {
            let detail = tr("app.tun.mips_requires_upgrade", Self.mipsStackMinimumCoreVersion)
            self.statusItemBanner = StatusItemBanner(
                symbolName: "exclamationmark.triangle.fill",
                title: tr("ui.quick.tun_mode"),
                primaryDetail: detail,
                secondaryDetail: nil)
            appendLog(level: "warning", message: detail)
            return
        }

        self.isTunSyncing = true
        self.configReadEpoch = UUID()
        defer {
            self.configReadEpoch = UUID()
            self.isTunSyncing = false
        }

        do {
            guard self.isRemoteTarget || self.isRuntimeRunning else { return }
            let baseline = try await self.fetchRuntimeConfigSnapshot()
            guard let enabled = baseline.tunEnabled else { throw ConfigApplicationError.unverified }
            if enabled, !self.isRemoteTarget {
                try await self.ensureTunPermissions(requestIfMissing: true)
            }
            try await self.patchTunConfig(enable: enabled, stack: stack)

            let config = try await self.fetchRuntimeConfigSnapshot()
            if config.tunEnabled == enabled, config.tun?.stack?.caseInsensitiveCompare(stack) == .orderedSame {
                self.recordConfigOverrides(["tun.stack": .string(stack)], for: overrideID)
                appendLog(level: "info", message: tr("log.tun.stack_changed", stack))
            } else {
                appendLog(
                    level: "error",
                    message: tr("log.tun.toggle_failed", tr("app.tun.error.runtime_state_mismatch")))
            }
        } catch {
            appendLog(level: "error", message: tr("log.tun.toggle_failed", self.tunErrorMessage(error)))
            await self.refreshTunStatusFromRuntimeConfig()
        }
    }

    func tunErrorMessage(_ error: Error) -> String {
        if let permissionError = error as? TunPermissionServiceError {
            switch permissionError {
            case .coreBinaryNotFound, .coreBinaryNotExecutable:
                return tr("app.tun.error.binary_not_found", workingDirectoryManager.coreDirectoryURL.path)
            case .permissionMissing:
                return tr("app.tun.error.permission_missing")
            case .authorizationCancelled:
                return tr("app.tun.error.authorization_cancelled")
            case let .authorizationFailed(message):
                return tr("app.tun.error.authorization_failed", message)
            case .permissionVerificationFailed:
                return tr("app.tun.error.permission_verify_failed")
            }
        }

        if let tunModeError = error as? TunModeError {
            switch tunModeError {
            case .runtimeStateMismatch:
                return tr("app.tun.error.runtime_state_mismatch")
            }
        }

        if let apiError = error as? APIError,
           case .statusCode = apiError
        {
            return tr("app.tun.error.patch_failed", apiError.localizedDescription)
        }

        return error.localizedDescription
    }

    func resolvedMihomoBinaryPath() -> String? {
        let current = mihomoBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current == "-" {
            return nil
        }
        return current
    }

    /// Resolves the core binary without blocking the main actor.
    /// Resolution may copy or decompress bundled assets on first launch.
    func resolvedMihomoBinaryPathAsync() async -> String? {
        if let managedProcess = self.processManager as? MihomoProcessManager {
            return await managedProcess.detectedBinaryPathAsync()
        }
        return self.processManager.detectedBinaryPath ?? self.resolvedMihomoBinaryPath()
    }

    func ensureTunPermissions(requestIfMissing: Bool) async throws {
        guard let binaryPath = await self.resolvedMihomoBinaryPathAsync() else {
            throw TunPermissionServiceError.coreBinaryNotFound
        }

        do {
            try self.tunPermissionService.validateCurrentPermissions(binaryPath: binaryPath)
        } catch TunPermissionServiceError.permissionMissing {
            guard requestIfMissing else {
                throw TunPermissionServiceError.permissionMissing
            }
            appendLog(level: "info", message: tr("log.tun.permission_requesting"))
            try await self.tunPermissionService.grantPermissions(binaryPath: binaryPath)
            appendLog(level: "info", message: tr("log.tun.permission_granted"))
        }
    }

    func applyTunRuntimeChange(enabled: Bool) async throws {
        guard self.isRemoteTarget || self.isRuntimeRunning else { return }
        try await self.patchTunConfig(enable: enabled)
        try await self.verifyTunRuntimeState(expectedEnabled: enabled)
    }

    func verifyTunRuntimeState(expectedEnabled: Bool) async throws {
        let config = try await fetchRuntimeConfigSnapshot()
        let actual = config.tunEnabled ?? false
        if actual != expectedEnabled {
            throw TunModeError.runtimeStateMismatch(expected: expectedEnabled)
        }
    }

    func patchTunConfig(enable: Bool, stack: String? = nil) async throws {
        let client = try clientOrThrow()
        var tunBody: [String: JSONValue] = ["enable": .bool(enable)]

        if let stack {
            tunBody["stack"] = .string(stack)
        }

        try await client.requestNoResponse(.patchConfigs(body: ["tun": .object(tunBody)]))
    }

    func refreshTunStatusFromRuntimeConfig() async {
        do {
            let config = try await fetchRuntimeConfigSnapshot()
            if let tunEnabled = config.tunEnabled, isTunEnabled != tunEnabled {
                isTunEnabled = tunEnabled
                persistEditableSettingsSnapshot()
            }
        } catch {}
    }
}
