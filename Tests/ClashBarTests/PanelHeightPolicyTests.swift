import CoreGraphics
import XCTest
@testable import ClashBar

final class PanelHeightPolicyTests: XCTestCase {
    private var listTabs: [RootTab] { [.rules, .connections, .logs] }
    private var measuredTabs: [RootTab] { [.proxy, .system] }

    /// The whole point of the shared budget: switching between list tabs must not
    /// resize the panel, so every list tab requests the same height.
    func testEveryListTabRequestsTheSameHeight() {
        let heights = self.listTabs.map { tab in
            PanelHeightPolicy.requestedHeight(for: tab, measuredHeight: 0, usableHeight: 4000)
        }
        XCTAssertEqual(Set(heights).count, 1, "list tabs must not resize the panel when switching")
        XCTAssertEqual(heights.first, PanelHeightPolicy.ListHeight.budget)
    }

    func testBudgetShowsAtLeastNineConnectionRows() {
        XCTAssertGreaterThanOrEqual(
            PanelHeightPolicy.visibleRowCount(for: .connections), 9,
            "the budget is sized from the tallest per-row list, so it must still show nine of them")
        XCTAssertGreaterThan(
            PanelHeightPolicy.visibleRowCount(for: .rules),
            PanelHeightPolicy.visibleRowCount(for: .connections),
            "shorter rows mean more of them fit in the same budget")
    }

    func testConnectionsRowHeightComesFromItsThreeLines() {
        let expected =
            (16 * 3)
                + (MenuBarLayoutTokens.space2 * 2)
                + (MenuBarLayoutTokens.space2 * 2)
        XCTAssertEqual(PanelHeightPolicy.ListHeight.connectionsRow, expected)
        XCTAssertGreaterThan(
            PanelHeightPolicy.ListHeight.connectionsRow, MenuBarLayoutTokens.rowHeight,
            "connections rows stack three lines and are taller than a rules row")
    }

    func testLogsRowHeightCoversAWrappedMessage() {
        let expected =
            (PanelHeightPolicy.captionLineHeight * 3)
                + (MenuBarLayoutTokens.space2 * 2)
                + (MenuBarLayoutTokens.space4 * 2)
        XCTAssertEqual(PanelHeightPolicy.ListHeight.logsRow, expected)
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
        XCTAssertEqual(display, budget, "a tall screen is bounded by the budget, not the screen")
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
            XCTAssertEqual(PanelHeightPolicy.contentKind(for: tab), .list)
            XCTAssertGreaterThan(PanelHeightPolicy.visibleRowCount(for: tab), 0)
        }
        for tab in self.measuredTabs {
            XCTAssertTrue(PanelHeightPolicy.measuresOwnHeight(tab))
            XCTAssertEqual(PanelHeightPolicy.contentKind(for: tab), .measured)
            XCTAssertEqual(PanelHeightPolicy.visibleRowCount(for: tab), 0)
        }
    }
}
