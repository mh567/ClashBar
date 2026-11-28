import Foundation

@MainActor
extension AppViewModel {
    func ensureLogFileExists() {
        self.flushPendingMihomoLogsIfNeeded()
        clashbarLogStore?.ensureLogFileExists()
        mihomoLogStore?.ensureLogFileExists()
    }

    func clearAllLogs() {
        mihomoLogFlushTask?.cancel()
        mihomoLogFlushTask = nil
        pendingMihomoLogs.removeAll(keepingCapacity: true)
        errorLogs.removeAll(keepingCapacity: false)
        clashbarLogStore?.clear()
        mihomoLogStore?.clear()
    }

    func appendLog(level: String, message: String) {
        self.appendLog(source: .clashbar, level: level, message: message)
    }

    func appendMihomoLog(level: String, message: String) {
        self.appendLog(source: .mihomo, level: level, message: message)
    }

    func logNetworkEvent(_ event: NetworkLogEvent) {
        switch event {
        case let .offlineConfirmed(seconds):
            self.appendLog(
                level: NetworkLogSeverity.info.rawValue,
                message: self.tr("log.network.offline_debounce", String(Int(seconds))))
        case let .onlineConfirmed(seconds):
            self.appendLog(
                level: NetworkLogSeverity.info.rawValue,
                message: self.tr("log.network.online_debounce", String(Int(seconds))))
        case let .autoStartRetry(attempt, delay, message):
            self.appendLog(
                level: NetworkLogSeverity.error.rawValue,
                message: self.tr(
                    "log.network.auto_start_retry", String(attempt), String(Int(delay)), message))
        case let .autoStartGaveUp(interval):
            self.appendLog(
                level: NetworkLogSeverity.error.rawValue,
                message: self.tr("log.network.auto_start_gave_up", String(Int(interval))))
        case let .autoStartBlocked(message):
            self.appendLog(
                level: NetworkLogSeverity.error.rawValue,
                message: self.tr("log.network.auto_start_blocked", message))
        case .userStartWhileOffline:
            self.appendLog(
                level: NetworkLogSeverity.warning.rawValue,
                message: self.tr("log.network.user_start_offline"))
        case .suppressedTransition:
            self.appendLog(
                level: NetworkLogSeverity.info.rawValue,
                message: self.tr("log.network.suppressed"))
        }
    }

    func appendLog(source: AppLogSource, level: String, message: String) {
        guard !message.isEmpty else { return }

        let entry = AppErrorLogEntry(source: source, level: level, message: message)
        if source == .mihomo {
            self.enqueueBufferedMihomoLog(entry)
            return
        }

        self.appendLogEntries([entry])
        self.persistLogEntriesToFile([entry])
    }

    func flushPendingMihomoLogsIfNeeded() {
        mihomoLogFlushTask?.cancel()
        mihomoLogFlushTask = nil

        guard !pendingMihomoLogs.isEmpty else { return }
        let entries = pendingMihomoLogs
        pendingMihomoLogs.removeAll(keepingCapacity: true)
        pendingMihomoLogs.reserveCapacity(maxBufferedMihomoLogEntries)
        self.appendLogEntries(entries)
        self.persistLogEntriesToFile(entries)
    }

    func trimInMemoryLogsForCurrentVisibility() {
        self.flushPendingMihomoLogsIfNeeded()
        let maxEntries = isPanelPresented ? maxInMemoryLogEntries : hiddenPanelMaxInMemoryLogEntries
        guard errorLogs.count > maxEntries else { return }
        errorLogs.removeLast(errorLogs.count - maxEntries)
    }

    func tr(_ key: String) -> String {
        L10n.t(key, language: uiLanguage)
    }

    func tr(_ key: String, _ args: CVarArg...) -> String {
        L10n.t(key, language: uiLanguage, args: args)
    }

    private func enqueueBufferedMihomoLog(_ entry: AppErrorLogEntry) {
        pendingMihomoLogs.append(entry)

        if pendingMihomoLogs.count >= maxBufferedMihomoLogEntries {
            self.flushPendingMihomoLogsIfNeeded()
            return
        }

        guard mihomoLogFlushTask == nil else { return }
        mihomoLogFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.mihomoLogFlushIntervalNanoseconds ?? 150_000_000)
            } catch {
                return
            }

            self?.flushPendingMihomoLogsIfNeeded()
        }
    }

    private func appendLogEntries(_ entries: [AppErrorLogEntry]) {
        guard !entries.isEmpty else { return }

        let maxEntries = isPanelPresented ? maxInMemoryLogEntries : hiddenPanelMaxInMemoryLogEntries
        let combined = entries.reversed() + errorLogs
        errorLogs = Array(combined.prefix(maxEntries))
    }

    private func persistLogEntriesToFile(_ entries: [AppErrorLogEntry]) {
        guard !entries.isEmpty else { return }

        let clashbarEntries = entries.filter { $0.source == .clashbar }
        if !clashbarEntries.isEmpty {
            clashbarLogStore?.append(entries: clashbarEntries)
        }

        let mihomoEntries = entries.filter { $0.source == .mihomo }
        if !mihomoEntries.isEmpty {
            mihomoLogStore?.append(entries: mihomoEntries)
        }
    }
}
