import CoreGraphics
import XCTest
@testable import ClashBar

final class PanelHeightPolicyTests: XCTestCase {
    private var listTabs: [RootTab] { [.rules, .connections, .logs] }
    private var measuredTabs: [RootTab] { [.proxy, .system] }

    func testListBudgetUsesEachTabsOwnRowHeight() {
        let expected: [RootTab: CGFloat] = [
            .rules: MenuBarLayoutTokens.rowHeight * 9,
            .connections: PanelHeightPolicy.ListRowHeight.connections * 9,
            .logs: PanelHeightPolicy.ListRowHeight.logs * 11,
        ]

        for (tab, budget) in expected {
            let height = PanelHeightPolicy.requestedHeight(
                for: tab, measuredHeight: 0, usableHeight: 4000)
            XCTAssertEqual(
                height, budget,
                "\(tab) must budget its own row height, not a shared constant")
        }
    }

    func testConnectionsRowHeightComesFromItsThreeLines() {
        let expected =
            (16 * 3)
                + (MenuBarLayoutTokens.space2 * 2)
                + (MenuBarLayoutTokens.space2 * 2)
        XCTAssertEqual(PanelHeightPolicy.ListRowHeight.connections, expected)
        XCTAssertGreaterThan(
            PanelHeightPolicy.ListRowHeight.connections, MenuBarLayoutTokens.rowHeight,
            "connections rows stack three lines and are taller than a rules row")
    }

    func testLogsRowHeightCoversAWrappedMessage() {
        let expected =
            (PanelHeightPolicy.captionLineHeight * 3)
                + (MenuBarLayoutTokens.space2 * 2)
                + (MenuBarLayoutTokens.space4 * 2)
        XCTAssertEqual(PanelHeightPolicy.ListRowHeight.logs, expected)
        XCTAssertEqual(PanelHeightPolicy.captionLineHeight, 12, "10pt monospaced line box")
    }

    func testStackedRowHeightAddsLinesGapsAndPadding() {
        XCTAssertEqual(
            PanelHeightPolicy.stackedRowHeight(
                lines: 3, lineHeight: 10, spacing: 2, verticalPadding: 4),
            10 * 3 + 2 * 2 + 4 * 2)
        XCTAssertEqual(
            PanelHeightPolicy.stackedRowHeight(
                lines: 0, lineHeight: 10, spacing: 2, verticalPadding: 4),
            8, "no lines leaves only the padding")
    }

    func testMeasuredTabsUseTheirOwnHeight() {
        for tab in self.measuredTabs {
            let height = PanelHeightPolicy.requestedHeight(
                for: tab, measuredHeight: 512, usableHeight: 4000)
            XCTAssertEqual(height, 512)
        }
    }

    func testListTabsIgnoreAMeasuredHeight() {
        for tab in self.listTabs {
            let withContent = PanelHeightPolicy.requestedHeight(
                for: tab, measuredHeight: 5000, usableHeight: 4000)
            let withoutContent = PanelHeightPolicy.requestedHeight(
                for: tab, measuredHeight: 0, usableHeight: 4000)
            XCTAssertEqual(withContent, withoutContent, "a list has no measured height to honour")
        }
    }

    func testRequestedHeightIsClampedExactlyOnce() {
        for tab in self.listTabs {
            let budget = PanelHeightPolicy.requestedHeight(
                for: tab, measuredHeight: 0, usableHeight: 4000)
            let usable = budget / 2

            let onShortScreen = PanelHeightPolicy.requestedHeight(
                for: tab, measuredHeight: 0, usableHeight: usable)
            XCTAssertEqual(onShortScreen, usable, "the policy clamp is the only bound")
            XCTAssertEqual(
                onShortScreen,
                PanelHeightPolicy.clamp(budget, usableHeight: usable),
                "requestedHeight must agree with the single clamp")
        }
    }

    func testShortScreenBoundsTheResultAndTallScreenKeepsTheBudget() {
        let budget = PanelHeightPolicy.requestedHeight(for: .rules, measuredHeight: 0, usableHeight: 4000)
        let tinyScreen = PanelHeightPolicy.requestedHeight(for: .rules, measuredHeight: 0, usableHeight: 200)
        let display = PanelHeightPolicy.requestedHeight(for: .rules, measuredHeight: 0, usableHeight: 1400)

        XCTAssertEqual(tinyScreen, 200, "a short screen bounds the list")
        XCTAssertEqual(display, budget, "a tall screen is bounded by the row budget, not the screen")
        XCTAssertLessThan(display, 1400, "a list must not fill a large display")
    }

    func testClampNeverReturnsZeroOrNegative() {
        XCTAssertEqual(PanelHeightPolicy.clamp(0, usableHeight: 300), 1)
        XCTAssertEqual(PanelHeightPolicy.clamp(-50, usableHeight: 300), 1)
        XCTAssertEqual(PanelHeightPolicy.clamp(120, usableHeight: 0), 1, "no usable height collapses to the floor")
        XCTAssertEqual(PanelHeightPolicy.clamp(120, usableHeight: 300), 120)
    }

    func testClassificationIsTheSingleSourceOfTruth() {
        for tab in self.listTabs {
            XCTAssertFalse(PanelHeightPolicy.measuresOwnHeight(tab))
            guard let budget = PanelHeightPolicy.rowBudget(for: tab) else {
                return XCTFail("\(tab) must be classified as a list")
            }
            XCTAssertGreaterThan(budget.rows, 0)
            XCTAssertGreaterThan(budget.rowHeight, 0)
        }
        for tab in self.measuredTabs {
            XCTAssertTrue(PanelHeightPolicy.measuresOwnHeight(tab))
            XCTAssertEqual(PanelHeightPolicy.contentKind(for: tab), .measured)
        }
    }
}
