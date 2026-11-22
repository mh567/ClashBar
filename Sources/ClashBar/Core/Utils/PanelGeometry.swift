import AppKit

enum PanelAttachmentSide: Equatable {
    case left
    case right
}

struct PanelPlacement: Equatable {
    let frame: CGRect
    let lockedOriginX: CGFloat?
    let attachmentSide: PanelAttachmentSide?
}

struct MenuBarDropdownPlacementOptions {
    let horizontalPadding: CGFloat
    let verticalSpacing: CGFloat
    let screenPadding: CGFloat
    let lockedOriginX: CGFloat?
    let preserveHorizontalPosition: Bool
}

struct SideAttachedPlacementOptions {
    let contentSize: CGSize
    /// Narrowest the panel may get, so short content still reads as a panel rather than a
    /// sliver. Content narrower than this is centred inside it.
    let minimumWidth: CGFloat?
    /// Widest the panel may get, so a long node name cannot stretch it across the screen.
    /// `nil` means the room on the chosen side is the only bound.
    let maximumWidth: CGFloat?
    let maximumHeight: CGFloat?
    let screenPadding: CGFloat
    let edgeOverlap: CGFloat
    /// Side this popover already settled on, so a later layout pass keeps it.
    let pinnedSide: PanelAttachmentSide?
}

struct PanelAnchorContext {
    let visibleFrame: CGRect
    let anchorFrameOnScreen: CGRect
    let hostWindowFrame: CGRect?

    @MainActor
    static func resolve(for anchorView: NSView?) -> PanelAnchorContext? {
        guard
            let anchorView,
            let hostWindow = anchorView.window
        else {
            return nil
        }

        let screen = hostWindow.screen ?? NSScreen.main
        guard let screen else { return nil }

        let anchorFrameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrameOnScreen = hostWindow.convertToScreen(anchorFrameInWindow)

        return PanelAnchorContext(
            visibleFrame: screen.visibleFrame,
            anchorFrameOnScreen: anchorFrameOnScreen,
            hostWindowFrame: hostWindow.frame)
    }

    var statusBarBottomY: CGFloat {
        self.visibleFrame.maxY
    }

    func maximumHeightBelowMenuBar(screenPadding: CGFloat, verticalSpacing: CGFloat) -> CGFloat {
        let availableHeightBelowStatusBar = self.statusBarBottomY - self.visibleFrame.minY - screenPadding -
            verticalSpacing
        let visibleHeight = self.visibleFrame.height - screenPadding

        return max(1, min(availableHeightBelowStatusBar, visibleHeight).rounded(.down))
    }

    func menuBarDropdownPlacement(
        panelSize: CGSize,
        options: MenuBarDropdownPlacementOptions)
        -> PanelPlacement
    {
        let minX = self.visibleFrame.minX + options.horizontalPadding
        let maxX = self.visibleFrame.maxX - options.horizontalPadding - panelSize.width

        let centeredX = self.anchorFrameOnScreen.midX - panelSize.width / 2
        let stableX = options.preserveHorizontalPosition ? (options.lockedOriginX ?? centeredX) : centeredX
        let clampedX = min(max(stableX, minX), maxX)

        let anchorTopY = self.statusBarBottomY - options.verticalSpacing
        let minY = self.visibleFrame.minY + options.screenPadding
        let clampedY = max(minY, anchorTopY - panelSize.height)

        return PanelPlacement(
            frame: CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: panelSize),
            lockedOriginX: clampedX,
            attachmentSide: nil)
    }

    func sideAttachedPlacement(_ options: SideAttachedPlacementOptions) -> PanelPlacement? {
        guard let hostWindowFrame else { return nil }

        let screenPadding = options.screenPadding
        let edgeOverlap = options.edgeOverlap
        let pinnedSide = options.pinnedSide

        let contentWidth = options.contentSize.width
        let widestAllowed = options.maximumWidth ?? self.visibleFrame.width - (screenPadding * 2)
        // The panel follows its content, bounded on both sides: wide enough to read, narrow
        // enough that one long row cannot stretch it across the screen.
        let wantedWidth = max(
            options.minimumWidth ?? 1,
            min(contentWidth, widestAllowed))
        let panelWidth = min(max(1, wantedWidth), self.visibleFrame.width - (screenPadding * 2))

        let preferredHeight: CGFloat = if let maximumHeight = options.maximumHeight {
            min(options.contentSize.height, maximumHeight + (screenPadding * 2))
        } else {
            options.contentSize.height
        }
        let panelHeight = min(max(40, preferredHeight), self.visibleFrame.height - (screenPadding * 2))

        let rightAvailable = max(0, self.visibleFrame.maxX - hostWindowFrame.maxX)
        let leftAvailable = max(0, hostWindowFrame.minX - self.visibleFrame.minX)

        // The popover is placed once with a provisional size and again after its content
        // lays out. Deciding the side from the current size each time can pick one side
        // first and the other second, which reads as the panel appearing on the left and
        // then jumping across. A side, once chosen, is pinned for that popover.
        //
        // The pin is dropped only when its side has no room left at all (the screen or the
        // host window moved away), because there is nothing to show there. Dropping it
        // whenever the provisional width does not fit would be the very jump the pin exists
        // to prevent: the panel is capped to the room anyway, so it fits by construction.
        let preferredSide = self.preferredSide(
            panelWidth: panelWidth, rightAvailable: rightAvailable, leftAvailable: leftAvailable)
        let attachmentSide: PanelAttachmentSide = if let pinnedSide,
            self.room(for: pinnedSide, right: rightAvailable, left: leftAvailable) > 0
        {
            pinnedSide
        } else {
            preferredSide
        }

        let sideAvailable = attachmentSide == .right ? rightAvailable : leftAvailable

        // Cap by the room on that side minus the padding, so the origin below lands inside the
        // padded area on its own. That removes the need for a horizontal clamp, and with it
        // the clamp's width-dependence that used to slide an open panel.
        let widthCap = max(1, sideAvailable - screenPadding + edgeOverlap)
        let panelSize = CGSize(width: min(panelWidth, widthCap), height: panelHeight)

        // Each side hangs off the host's own edge, so neither origin depends on the panel's
        // width. That is what keeps an open popover still while its content grows.
        let originX: CGFloat = switch attachmentSide {
        case .right:
            hostWindowFrame.maxX - edgeOverlap
        case .left:
            hostWindowFrame.minX - panelSize.width + edgeOverlap
        }

        let desiredY = self.anchorFrameOnScreen.midY - panelSize.height / 2
        let minY = self.visibleFrame.minY + screenPadding
        let maxY = self.visibleFrame.maxY - screenPadding - panelSize.height
        let clampedY = max(minY, min(desiredY, maxY))

        return PanelPlacement(
            frame: CGRect(origin: CGPoint(x: originX, y: clampedY), size: panelSize),
            lockedOriginX: nil,
            attachmentSide: attachmentSide)
    }

    private func room(
        for side: PanelAttachmentSide, right: CGFloat, left: CGFloat) -> CGFloat
    {
        side == .right ? right : left
    }

    /// The side that fits the panel, preferring the one with more room when neither does.
    /// "Fits" is checked against the panel's own width so a wide panel does not get pinned
    /// to a side too narrow for it.
    private func preferredSide(
        panelWidth: CGFloat, rightAvailable: CGFloat, leftAvailable: CGFloat)
        -> PanelAttachmentSide
    {
        if rightAvailable >= panelWidth {
            .right
        } else if leftAvailable >= panelWidth {
            .left
        } else {
            rightAvailable >= leftAvailable ? .right : .left
        }
    }
}
