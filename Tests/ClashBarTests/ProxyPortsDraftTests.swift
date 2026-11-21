import XCTest
@testable import ClashBar

final class ProxyPortsDraftTests: XCTestCase {
    private func fields(
        port: String = "0",
        socks: String = "0",
        mixed: String = "7890",
        redir: String = "0",
        tproxy: String = "0") -> [SettingsPortField]
    {
        [
            SettingsPortField(key: "port", value: port),
            SettingsPortField(key: "socks-port", value: socks),
            SettingsPortField(key: "mixed-port", value: mixed),
            SettingsPortField(key: "redir-port", value: redir),
            SettingsPortField(key: "tproxy-port", value: tproxy),
        ]
    }

    private func snapshot(
        port: String = "0",
        socks: String = "0",
        mixed: String = "7890",
        redir: String = "0",
        tproxy: String = "0") -> EditableSettingsSnapshot
    {
        EditableSettingsSnapshot(
            mode: .rule,
            allowLan: false,
            ipv6: false,
            tcpConcurrent: false,
            tunEnabled: false,
            logLevel: ConfigLogLevel.info.rawValue,
            port: port,
            socksPort: socks,
            mixedPort: mixed,
            redirPort: redir,
            tproxyPort: tproxy)
    }

    func testParsesPortsWithinRange() {
        XCTAssertEqual(ProxyPortsDraft.parsedPort("7890"), 7890)
        XCTAssertEqual(ProxyPortsDraft.parsedPort(" 7890 "), 7890)
        XCTAssertEqual(ProxyPortsDraft.parsedPort("0"), 0)
        XCTAssertEqual(ProxyPortsDraft.parsedPort("65535"), 65535)
    }

    func testRejectsPortsOutsideRangeOrUnparsable() {
        XCTAssertNil(ProxyPortsDraft.parsedPort("65536"))
        XCTAssertNil(ProxyPortsDraft.parsedPort("-1"))
        XCTAssertNil(ProxyPortsDraft.parsedPort(""))
        XCTAssertNil(ProxyPortsDraft.parsedPort("abc"))
    }

    func testAutoSavableRequiresEveryFieldToParse() {
        XCTAssertTrue(ProxyPortsDraft.isAutoSavable(self.fields()))
        XCTAssertFalse(ProxyPortsDraft.isAutoSavable(self.fields(mixed: "")))
        XCTAssertFalse(ProxyPortsDraft.isAutoSavable(self.fields(port: "70000")))
    }

    /// Regression: an empty field mid-edit must not be treated as an out-of-range
    /// value, otherwise every keystroke surfaced a validation error.
    func testAutoSavableSkipsWhileFieldIsBeingCleared() {
        XCTAssertFalse(ProxyPortsDraft.isAutoSavable(self.fields(mixed: "")))
        XCTAssertTrue(ProxyPortsDraft.isAutoSavable(self.fields(mixed: "7")))
    }

    func testDiffersWhenFieldEdited() {
        XCTAssertFalse(ProxyPortsDraft.differs(self.fields(), from: self.snapshot()))
        XCTAssertTrue(ProxyPortsDraft.differs(self.fields(mixed: "7891"), from: self.snapshot()))
    }

    func testDiffersIgnoresSurroundingWhitespace() {
        XCTAssertFalse(ProxyPortsDraft.differs(self.fields(mixed: " 7890 "), from: self.snapshot()))
    }

    /// Stops the auto-save retry loop: reconciliation writes applied ports back
    /// into the UI, so with no snapshot we must assume a change is pending.
    func testDiffersWithoutSnapshotAssumesPendingChange() {
        XCTAssertTrue(ProxyPortsDraft.differs(self.fields(), from: nil))
    }

    /// Focus-and-return on an untouched field must not report a change, otherwise
    /// the click alone records a manual override of that port.
    func testChangedFieldsIsEmptyWhenNothingWasEdited() {
        XCTAssertTrue(ProxyPortsDraft.changedFields(self.fields(), from: self.snapshot()).isEmpty)
        XCTAssertTrue(
            ProxyPortsDraft.changedFields(self.fields(mixed: " 7890 "), from: self.snapshot()).isEmpty)
    }

    func testChangedFieldsReportsOnlyEditedKeys() {
        let fields = self.fields(socks: "1080", mixed: "7891")
        XCTAssertEqual(ProxyPortsDraft.changedFields(fields, from: self.snapshot()), ["mixed-port", "socks-port"])
    }

    func testChangedFieldsWithoutSnapshotTreatsAllAsEdited() {
        XCTAssertEqual(
            ProxyPortsDraft.changedFields(self.fields(), from: nil).count,
            self.fields().count)
    }

    /// A cleared field counts as an edit, so the save path must decide separately
    /// whether it can be written. Dropping it as "unchanged" would silently ignore
    /// the user's intent to reset the port.
    func testClearedFieldCountsAsEditedButIsNotAutoSavable() {
        let fields = self.fields(socks: "1080", mixed: "")
        XCTAssertEqual(ProxyPortsDraft.changedFields(fields, from: self.snapshot()), ["mixed-port", "socks-port"])

        let edited = fields.filter { $0.key == "mixed-port" || $0.key == "socks-port" }
        XCTAssertFalse(ProxyPortsDraft.isAutoSavable(edited))
    }

    /// Only the edited subset gates the save: a field still holding its applied
    /// value must not block writing a real change elsewhere.
    func testUntouchedFieldsDoNotBlockAutoSave() {
        let snapshot = self.snapshot()
        let fields = self.fields(mixed: "7891")
        let changed = ProxyPortsDraft.changedFields(fields, from: snapshot)
        let edited = fields.filter { changed.contains($0.key) }

        XCTAssertEqual(edited.map(\.key), ["mixed-port"])
        XCTAssertTrue(ProxyPortsDraft.isAutoSavable(edited))
    }
}
