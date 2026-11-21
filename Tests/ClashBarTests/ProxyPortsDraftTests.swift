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
}
