import XCTest
@testable import ClashBar

final class ProxyPortsDraftTests: XCTestCase {
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
}
