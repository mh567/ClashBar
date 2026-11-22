import CoreGraphics
import XCTest
@testable import ClashBar

/// A side-attached panel must not move once it is open.
///
/// The popover is placed once with a provisional `fittingSize` and again after its content
/// lays out. Between those passes it can grow, so anything width-dependent in the placement
/// makes an open panel slide or flip. These cases pin both symptoms, on both sides.
final class PanelPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let padding: CGFloat = 6
    private let overlap: CGFloat = 1

    private func context(hostX: CGFloat, hostWidth: CGFloat = 360) -> PanelAnchorContext {
        let host = CGRect(x: hostX, y: 100, width: hostWidth, height: 700)
        return PanelAnchorContext(
            visibleFrame: self.visible,
            anchorFrameOnScreen: CGRect(x: host.midX - 20, y: 400, width: 40, height: 20),
            hostWindowFrame: host)
    }

    private func place(
        _ context: PanelAnchorContext,
        width: CGFloat,
        pinnedSide: PanelAttachmentSide?,
        minimumWidth: CGFloat? = nil,
        maximumWidth: CGFloat? = nil
    ) throws -> PanelPlacement {
        try XCTUnwrap(context.sideAttachedPlacement(
            SideAttachedPlacementOptions(
                contentSize: CGSize(width: width, height: 160),
                minimumWidth: minimumWidth,
                maximumWidth: maximumWidth,
                maximumHeight: nil,
                screenPadding: self.padding,
                edgeOverlap: self.overlap,
                pinnedSide: pinnedSide)))
    }

    /// The reported symptom: the provisional pass fits on the right, the laid-out pass does
    /// not, so without a pin the panel moves to the other side.
    func testUnpinnedPlacementCanFlipSidesBetweenLayoutPasses() throws {
        let context = self.context(hostX: 1268)
        let provisional = try self.place(context, width: 200, pinnedSide: nil)
        let laidOut = try self.place(context, width: 320, pinnedSide: nil)

        XCTAssertEqual(provisional.attachmentSide, .right)
        XCTAssertEqual(laidOut.attachmentSide, .left, "unpinned, the second pass chooses the other side")
    }

    /// Growing content must not move an open panel.
    ///
    /// A panel grows away from the host, so the edge glued to the host is what has to stay
    /// put: its left edge for a right-attached panel, its right edge for a left-attached one.
    /// The opposite edge naturally travels as the panel widens; that is growth, not a jump.
    func testPanelKeepsItsAnchoredEdgeWhileItsContentGrows() throws {
        // 1268 leaves 292pt on the right; 1500 leaves only 60pt, so the left is the side
        // that fits. Picking a host where both sides fit would test nothing about the left.
        let cases: [(name: String, hostX: CGFloat, side: PanelAttachmentSide)] = [
            ("host whose right side fits", 1268, .right),
            ("host whose only fitting side is the left", 1500, .left),
        ]
        for (name, hostX, side) in cases {
            let context = self.context(hostX: hostX)
            let pinned = try self.place(context, width: 200, pinnedSide: nil)
            XCTAssertEqual(pinned.attachmentSide, side, "\(name): unexpected side")

            for width in [200.0, 280.0, 320.0] {
                let grown = try self.place(context, width: width, pinnedSide: pinned.attachmentSide)
                XCTAssertEqual(
                    grown.attachmentSide, pinned.attachmentSide,
                    "\(name): the panel flipped sides when its content grew to \(width)")
                switch side {
                case .right:
                    XCTAssertEqual(
                        grown.frame.minX, pinned.frame.minX,
                        "\(name): the anchored left edge moved at width \(width)")
                case .left:
                    XCTAssertEqual(
                        grown.frame.maxX, pinned.frame.maxX,
                        "\(name): the anchored right edge moved at width \(width)")
                }
            }
        }
    }

    /// The placement is idempotent once the side is known: running it again with the same
    /// inputs must produce the same frame, or the panel would move on every layout pass.
    func testRepeatedPlacementIsIdempotent() throws {
        let context = self.context(hostX: 1268)
        let first = try self.place(context, width: 240, pinnedSide: nil)
        let second = try self.place(context, width: 240, pinnedSide: first.attachmentSide)
        let third = try self.place(context, width: 240, pinnedSide: second.attachmentSide)

        XCTAssertEqual(second.frame, first.frame)
        XCTAssertEqual(third.frame, first.frame)
    }

    /// The panel follows its content between the bounds: narrow content is lifted to the
    /// minimum, wide content is capped at the maximum, and anything between is used as-is.
    func testWidthFollowsContentWithinItsBounds() throws {
        let context = self.context(hostX: 260)

        let short = try self.place(context, width: 120, pinnedSide: nil, minimumWidth: 200, maximumWidth: 360)
        XCTAssertEqual(short.frame.width, 200, "content narrower than the minimum is lifted to it")

        let medium = try self.place(context, width: 280, pinnedSide: nil, minimumWidth: 200, maximumWidth: 360)
        XCTAssertEqual(medium.frame.width, 280, "content between the bounds is used as-is")

        let long = try self.place(context, width: 520, pinnedSide: nil, minimumWidth: 200, maximumWidth: 360)
        XCTAssertEqual(long.frame.width, 360, "content wider than the maximum is capped at it")
    }

    /// Two passes that measure the content slightly differently must still agree once the
    /// content sits inside the bounds, which is what keeps the panel from resizing on open.
    func testWidthIsStableForContentInsideTheBounds() throws {
        let context = self.context(hostX: 260)
        let first = try self.place(context, width: 280, pinnedSide: nil, minimumWidth: 200, maximumWidth: 360)
        let second = try self.place(
            context, width: 286, pinnedSide: first.attachmentSide, minimumWidth: 200, maximumWidth: 360)

        XCTAssertEqual(first.attachmentSide, second.attachmentSide)
        XCTAssertNotEqual(
            second.frame.width, first.frame.width,
            "content-driven width does change with the content; only the side must stay put")
    }

    /// The panel stays inside the padded area, so dropping the horizontal clamp did not let
    /// it hang off the screen.
    func testPanelStaysInsideThePaddedArea() throws {
        for hostX in [-200.0, 100.0, 800.0, 1600.0, 1900.0] {
            let context = self.context(hostX: hostX)
            let placement = try self.place(context, width: 900, pinnedSide: nil)
            let frame = placement.frame

            XCTAssertGreaterThanOrEqual(
                frame.minX, self.visible.minX + self.padding,
                "hostX \(hostX): the panel extends past the left padding")
            XCTAssertLessThanOrEqual(
                frame.maxX, self.visible.maxX - self.padding,
                "hostX \(hostX): the panel extends past the right padding")
            XCTAssertGreaterThan(frame.width, 1, "hostX \(hostX): the panel collapsed to a sliver")
        }
    }

    /// A pin must not survive into a layout where that side no longer fits.
    func testPinFallsBackWhenItsSideNoLongerHasRoom() throws {
        // A host flush to the right edge leaves no room on the right.
        let context = self.context(hostX: 1920 - 360)
        let placement = try self.place(context, width: 240, pinnedSide: .right)

        XCTAssertEqual(
            placement.attachmentSide, .left,
            "a pinned side that cannot fit the panel must give way instead of crushing it")
        XCTAssertGreaterThan(placement.frame.width, 1)
    }
}
