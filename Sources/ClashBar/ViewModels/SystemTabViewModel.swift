import Foundation

enum SystemFeedbackKind {
    case error
    case warning
    case success
}

struct SystemFeedbackState: Equatable {
    let message: String
    let kind: SystemFeedbackKind
    let symbol: String
}

/// The core-settings action row is a filled card, so it must only exist when it would
/// contain something. A lone override is not enough: its own status chip reverts it, and
/// Restore All needs at least two, so the card would render as an empty strip.
enum CoreSettingsActionsVisibility {
    static func shouldShow(
        isApplying: Bool,
        isCommitting: Bool,
        pendingCount: Int,
        overrideCount: Int,
        hasError: Bool,
        isRestoring: Bool) -> Bool
    {
        isApplying || isCommitting || pendingCount > 0 || hasError || isRestoring || overrideCount > 1
    }
}

@MainActor
enum SystemTabViewModel {
    static func maintenanceActionEnabled(session: AppViewModel) -> Bool {
        session.isRemoteTarget || session.processManager.isRunning || session.statusText.lowercased() == "running"
    }

    static func feedbackState(session: AppViewModel) -> SystemFeedbackState? {
        if let error = session.settingsErrorMessage.trimmedNonEmpty {
            return SystemFeedbackState(
                message: error,
                kind: .error,
                symbol: "exclamationmark.triangle.fill")
        }

        if let launchError = session.launchAtLoginErrorMessage.trimmedNonEmpty {
            return SystemFeedbackState(
                message: launchError,
                kind: .warning,
                symbol: "exclamationmark.circle.fill")
        }

        if let saved = session.settingsSavedMessage.trimmedNonEmpty {
            return SystemFeedbackState(
                message: saved,
                kind: .success,
                symbol: "checkmark.circle.fill")
        }

        return nil
    }
}
