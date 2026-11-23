import AppKit

enum CoreFailurePresentation: Equatable {
    case modal
    case banner
    case none
}

@MainActor
extension AppViewModel {
    private static var modalAlertWindowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    }

    func prepareModalWindowPresentation() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func configureModalWindow(_ window: NSWindow) {
        window.level = Self.modalAlertWindowLevel
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    @discardableResult
    func runModalAlert(
        style: NSAlert.Style,
        message: String,
        informative: String,
        buttons: [String],
        configure: ((NSAlert) -> Void)? = nil) -> NSApplication.ModalResponse
    {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = informative
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        configure?(alert)
        self.prepareModalWindowPresentation()
        self.configureModalWindow(alert.window)

        let watchdog = DispatchWorkItem { [weak self, weak alert] in
            guard let self else { return }
            self.appendLog(level: NetworkLogSeverity.error.rawValue, message: self.tr("log.alert.modal_timeout"))
            alert?.window.orderOut(nil)
            NSApplication.shared.abortModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: watchdog)
        defer { watchdog.cancel() }
        return alert.runModal()
    }

    func presentBackgroundBanner(_ banner: StatusItemBanner) {
        self.statusItemBanner = banner
    }

    func presentNetworkBanner(_ kind: NetworkBannerKind) {
        switch kind {
        case .corePausedByNetworkLoss:
            self.presentBackgroundBanner(StatusItemBanner(
                symbolName: "wifi.slash",
                title: self.tr("ui.banner.network.core_paused.title"),
                primaryDetail: self.tr("ui.banner.network.core_paused.detail"),
                secondaryDetail: nil))
        case .coreResumedAfterNetworkRecovery:
            self.presentBackgroundBanner(StatusItemBanner(
                symbolName: "wifi",
                title: self.tr("ui.banner.network.core_resumed.title"),
                primaryDetail: self.tr("ui.banner.network.core_resumed.detail"),
                secondaryDetail: nil))
        case let .coreAutoStartFailed(message, quietRetryInterval):
            self.presentBackgroundBanner(StatusItemBanner(
                symbolName: "exclamationmark.triangle.fill",
                title: self.tr("ui.banner.network.core_start_failed.title"),
                primaryDetail: message.isEmpty
                    ? self.tr("ui.banner.network.core_start_failed.detail")
                    : message,
                secondaryDetail: self.tr(
                    "ui.banner.network.core_gave_up.detail",
                    String(Int(quietRetryInterval)))))
        }
    }
}

@MainActor
extension AppViewModel {
    func showRuntimeConfigPreview() async {
        guard !self.isRemoteTarget else { return }

        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return }
        scrollView.hasHorizontalScroller = false
        textView.isEditable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = self.tr("ui.quick.runtime_config.loading")

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        panel.title = self.tr("ui.quick.runtime_config.title")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.moveToActiveSpace)
        panel.contentView = scrollView
        panel.initialFirstResponder = textView
        self.runtimeConfigPreviewPanel?.close()
        self.runtimeConfigPreviewPanel = panel
        self.prepareModalWindowPresentation()
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        guard self.processManager.isRunning else {
            textView.string = self.tr("ui.quick.runtime_config.stopped")
            return
        }
        guard !self.isConfigMutationBusy,
              let input = self.runtimeConfigInput, let yaml = input.yaml, input.status == self.processManager.status
        else {
            textView.string = self.tr("ui.quick.runtime_config.unavailable")
            return
        }
        let epoch = self.configReadEpoch
        let details: RuntimeConfigYAML.Details
        do {
            let liveSettings = try await self.clientOrThrow().runtimeConfigPreview()
            details = try await RuntimeConfigYAML.inspect(
                yaml: yaml, settings: liveSettings, controller: input.controller)
        } catch {
            textView.string = self.tr("ui.quick.runtime_config.failed")
            return
        }
        guard !self.isRemoteTarget, !self.isConfigMutationBusy,
              self.configReadEpoch == epoch, input == self.runtimeConfigInput,
              input.status == self.processManager.status
        else {
            textView.string = self.tr("ui.quick.runtime_config.unavailable")
            return
        }
        var lines: [String] = []
        if let version = input.version {
            lines.append(self.tr("ui.quick.runtime_config.version", String(version.prefix(12))))
        }
        lines.append(self.tr("ui.quick.runtime_config.launch_source", "external-controller"))
        if !input.overrides.isEmpty {
            let fields = input.overrides.keys.sorted().joined(separator: ", ")
            lines.append(self.tr("ui.quick.runtime_config.override_source", fields))
        }
        if !details.declaredOnly.isEmpty {
            lines.append(self.tr("ui.quick.runtime_config.yaml_source", details.declaredOnly.joined(separator: ", ")))
        }
        if !details.runtimeFields.isEmpty {
            let fields = details.runtimeFields.joined(separator: ", ")
            lines.append(self.tr("ui.quick.runtime_config.runtime_source", fields))
        }
        for (key, value) in details.declarationDifferences.sorted(by: { $0.key < $1.key }) {
            lines.append(self.tr("ui.quick.runtime_config.declaration_difference", key, String(reflecting: value)))
        }
        if !details.geoAliasConflicts.isEmpty {
            let fields = details.geoAliasConflicts.joined(separator: ", ")
            lines.append(self.tr("ui.quick.runtime_config.geo_alias_conflict", fields))
        }
        if !self.configApplicationIssues.isEmpty {
            lines.append(self.tr("app.config.apply.partial", self.configApplicationIssues.joined(separator: ", ")))
        }
        textView.string = lines
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { "# " + $0 }.joined(separator: "\n") + "\n\n" + details.yaml
    }
}

@MainActor
extension AppViewModel {
    func presentCoreFailureAlert(
        title: String,
        message: String,
        dedupeKey: String,
        style: NSAlert.Style = .warning,
        presentation: CoreFailurePresentation = .modal)
    {
        let now = Date()
        if self.lastCoreFailureAlertKey == dedupeKey,
           let lastAt = self.lastCoreFailureAlertAt,
           now.timeIntervalSince(lastAt) < self.coreFailureAlertThrottleInterval
        {
            return
        }

        self.lastCoreFailureAlertKey = dedupeKey
        self.lastCoreFailureAlertAt = now

        switch presentation {
        case .modal:
            self.runModalAlert(
                style: style,
                message: title,
                informative: message,
                buttons: [tr("ui.action.ok")])
        case .banner:
            self.presentBackgroundBanner(StatusItemBanner(
                symbolName: "exclamationmark.triangle.fill",
                title: title,
                primaryDetail: message,
                secondaryDetail: nil))
        case .none:
            break
        }
    }

    func presentConfigValidationFailedAlert(fileName: String, details: String) {
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)

        var informativeParts = [tr("app.config.validation_failed.message", fileName)]
        if Self.validationFailureLooksGeoRelated(trimmedDetails) {
            informativeParts.append(tr("app.config.validation_failed.hint.geo"))
        }
        informativeParts.append(tr("app.config.validation_failed.hint.common"))

        let response = self.runModalAlert(
            style: .critical,
            message: tr("app.config.validation_failed.title"),
            informative: informativeParts.joined(separator: "\n\n"),
            buttons: [tr("ui.action.ok"), tr("ui.action.copy_details")])
        { alert in
            alert.setScrollableDetails(trimmedDetails.isEmpty ? self.tr("ui.common.unknown") : trimmedDetails)
        }

        if response == .alertSecondButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(trimmedDetails, forType: .string)
        }
    }

    private static func validationFailureLooksGeoRelated(_ details: String) -> Bool {
        let lower = details.lowercased()
        let needles = [
            "geoip", "geosite", "mmdb", "geox-url", "geodata",
            "country.mmdb", "geosite.dat", "geoip.dat", ".metadb", "geolite", "asn",
        ]
        return needles.contains { lower.contains($0) }
    }

    func presentInitialNoCoreSetupGuideIfNeeded() {
        guard self.shouldPresentInitialNoCoreSetupGuide() else { return }
        guard !didPresentInitialNoCoreSetupGuide else { return }

        didPresentInitialNoCoreSetupGuide = true
        defaults.set(true, forKey: initialNoCoreSetupGuideShownKey)

        let response = self.runModalAlert(
            style: .informational,
            message: tr("app.core.setup_required.title"),
            informative: tr("app.core.setup_required.message", workingDirectoryManager.coreDirectoryURL.path),
            buttons: [tr("ui.action.open_core_directory"), tr("ui.action.ok")])
        if response == .alertFirstButtonReturn {
            self.showCoreDirectoryInFinder()
        }
    }

    func shouldPresentInitialNoCoreSetupGuide() -> Bool {
        guard self.shouldDeferAutoStartForMissingManagedCore() else { return false }
        guard !defaults.bool(forKey: initialNoCoreSetupGuideShownKey) else { return false }
        return true
    }
}
