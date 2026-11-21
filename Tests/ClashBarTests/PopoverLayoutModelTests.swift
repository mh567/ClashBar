import XCTest
@testable import ClashBar

/// Panel height is shared across tabs. A list tab must take the full available
/// height instead of inheriting whatever the previous tab asked for.
@MainActor
final class PopoverLayoutModelTests: XCTestCase {
    private func makeModel() -> PopoverLayoutModel {
        PopoverLayoutModel(maxPanelHeight: 640, preferredPanelHeight: 320, minPanelHeight: 280)
    }

    func testRequestingTheMaximumResolvesToTheMaximum() {
        let model = self.makeModel()
        XCTAssertEqual(model.resolvedPanelHeight, 320)

        model.requestPanelHeight(model.maxPanelHeight)

        XCTAssertEqual(model.resolvedPanelHeight, 640)
    }

    func testRequestBelowMinimumClampsToMinimum() {
        let model = self.makeModel()
        model.requestPanelHeight(120)

        XCTAssertEqual(model.resolvedPanelHeight, 280)
    }

    func testMaximumNeverExceedsTheCap() {
        let model = self.makeModel()
        model.requestPanelHeight(2000)

        XCTAssertEqual(model.resolvedPanelHeight, 640)
    }
}
