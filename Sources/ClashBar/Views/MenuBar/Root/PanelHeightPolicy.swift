import CoreGraphics

/// Decides how tall the panel content is for each tab.
///
/// Tabs split into two kinds. Settings-like tabs measure their own content and ask
/// for exactly that. List tabs cannot measure themselves (their content is
/// unbounded), so they ask for a row budget instead of swallowing the screen.
///
/// Both kinds are clamped to the usable height for the current screen, which is
/// why the same build behaves sensibly on a 13" laptop and a 27" display: the
/// budget is a preference, the screen is the bound.
enum PanelHeightPolicy {
    /// The single place that classifies a tab, so the layout and the tests never
    /// re-derive the distinction.
    enum ContentKind: Equatable {
        /// The tab reports its own height; the panel asks for exactly that.
        case measured
        /// Unbounded list. Every list tab shares `ListHeight.budget`, so switching
        /// between them never resizes the panel.
        case list
    }

    /// Line box of a `MenuBarLayoutTokens.FontSize.caption` (10pt) monospaced line:
    /// ascender - descender is 11.78pt, rounded up.
    static let captionLineHeight: CGFloat = 12

    /// One height for every list tab. Per-tab row counts used to give Rules 288pt and
    /// Connections 504pt, so the panel resized on every switch and Rules looked
    /// cramped next to Connections. The budget is sized from the tallest row so the
    /// densest list still gets its rows, and the shorter-row lists simply show more.
    enum ListHeight {
        /// `ConnectionsTabView.connectionRow`: three `ConnectionsLayout.rowLineHeight`
        /// (16pt) lines, two `T.space2` stack gaps and `T.space2` vertical padding.
        static let connectionsRow = PanelHeightPolicy.stackedRowHeight(
            lines: 3,
            lineHeight: 16,
            spacing: MenuBarLayoutTokens.space2,
            verticalPadding: MenuBarLayoutTokens.space2)

        /// Nine connection rows: the tallest per-row list, so it sets the budget.
        static let budget = ListHeight.connectionsRow * 9

        /// `RulesTabView.rulesRow`: `.frame(height: T.rowHeight)`, so the budget shows
        /// roughly sixteen of them.
        static let rulesRow = MenuBarLayoutTokens.rowHeight

        /// `LogsTabView.logEntryRow` with its `.padding(.vertical, T.space4)`: the caption
        /// label line plus a message wrapping to two lines at panel width, separated by
        /// `T.space2` stack gaps. The optional `[detail]` line is not counted; messages
        /// carry it only sometimes.
        static let logsRow = PanelHeightPolicy.stackedRowHeight(
            lines: 3,
            lineHeight: PanelHeightPolicy.captionLineHeight,
            spacing: MenuBarLayoutTokens.space2,
            verticalPadding: MenuBarLayoutTokens.space4)
    }

    /// Height of `lines` lines of `lineHeight` separated by `spacing`, with
    /// `verticalPadding` above and below.
    static func stackedRowHeight(
        lines: Int,
        lineHeight: CGFloat,
        spacing: CGFloat,
        verticalPadding: CGFloat) -> CGFloat
    {
        let lineCount = CGFloat(max(lines, 0))
        let gapCount = CGFloat(max(lines - 1, 0))
        return (lineHeight * lineCount) + (spacing * gapCount) + (verticalPadding * 2)
    }

    static func contentKind(for tab: RootTab) -> ContentKind {
        switch tab {
        case .proxy, .system: .measured
        case .rules, .connections, .logs: .list
        }
    }

    /// True when the tab measures itself instead of asking for a row budget.
    static func measuresOwnHeight(_ tab: RootTab) -> Bool {
        self.contentKind(for: tab) == .measured
    }

    /// Rows a list tab shows inside the shared budget. Derived from the same
    /// classification the layout uses, so there is no second row-height switch.
    static func visibleRowCount(for tab: RootTab) -> Int {
        guard case .list = self.contentKind(for: tab) else { return 0 }
        return Int((ListHeight.budget / self.rowHeight(for: tab)).rounded(.down))
    }

    /// Per-row height of a list tab. Only meaningful for `ContentKind.list`.
    private static func rowHeight(for tab: RootTab) -> CGFloat {
        switch tab {
        case .rules: ListHeight.rulesRow
        case .connections: ListHeight.connectionsRow
        case .logs: ListHeight.logsRow
        case .proxy, .system: 0
        }
    }

    /// Height the tab asks the scroll area to have: its measured height for a
    /// measured tab, the shared list budget for a list tab.
    ///
    /// For list tabs this is a budget, not a measurement, so that phrase is avoided
    /// in the name. This is also the only place the request is clamped to the
    /// usable height and floored at 1; callers pass their raw numbers through.
    static func requestedHeight(
        for tab: RootTab,
        measuredHeight: CGFloat,
        usableHeight: CGFloat) -> CGFloat
    {
        let requested: CGFloat = switch self.contentKind(for: tab) {
        case .measured:
            measuredHeight
        case .list:
            ListHeight.budget
        }
        return self.clamp(requested, usableHeight: usableHeight)
    }

    /// Keeps a requested height inside what the screen can actually show.
    ///
    /// The only clamp in the layout path: callers hand over their raw request and the
    /// usable height, and get back a value that is never below 1 and never above the
    /// screen. `usableHeight <= 0` means nothing fits (the fixed sections already fill
    /// the screen), which collapses to the 1pt floor.
    static func clamp(_ requested: CGFloat, usableHeight: CGFloat) -> CGFloat {
        guard usableHeight > 0 else { return 1 }
        return max(1, min(requested, usableHeight))
    }
}
