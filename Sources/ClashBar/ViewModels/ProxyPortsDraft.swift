import Foundation

/// Pure port-draft rules shared by the settings UI and its tests.
///
/// Kept free of `AppViewModel` state so the auto-save decision (which fields may
/// be written without showing a validation error, and whether an edited draft
/// still differs from what was applied) can be exercised directly.
enum ProxyPortsDraft {
    static let portRange = 0...65535

    static func parsedPort(_ raw: String) -> Int? {
        guard let value = Int(raw.trimmed), self.portRange.contains(value) else { return nil }
        return value
    }

    /// Auto-save is silent, so it only runs when every field parses. A half-typed
    /// value must not surface "port out of range" while the user is editing.
    static func isAutoSavable(_ fields: [SettingsPortField]) -> Bool {
        fields.allSatisfy { self.parsedPort($0.value) != nil }
    }

    static func baselineValue(forKey key: String, in snapshot: EditableSettingsSnapshot) -> String {
        switch key {
        case "port": snapshot.port
        case "socks-port": snapshot.socksPort
        case "mixed-port": snapshot.mixedPort
        case "redir-port": snapshot.redirPort
        case "tproxy-port": snapshot.tproxyPort
        default: ""
        }
    }

    /// Used to stop the auto-save retry loop: reconciliation writes applied ports
    /// back into the UI, which re-triggers `onChange`. Once the draft matches the
    /// applied snapshot there is nothing left to save.
    static func differs(_ fields: [SettingsPortField], from snapshot: EditableSettingsSnapshot?) -> Bool {
        guard let snapshot else { return true }
        return fields.contains {
            $0.value.trimmed != self.baselineValue(forKey: $0.key, in: snapshot).trimmed
        }
    }
}
