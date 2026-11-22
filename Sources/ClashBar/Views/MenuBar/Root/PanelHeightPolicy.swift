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
        /// Unbounded list: asks for `rows` rows of `rowHeight`.
        case list(rows: Int, rowHeight: CGFloat)
    }

    /// Line box of a `MenuBarLayoutTokens.FontSize.caption` (10pt) monospaced line:
    /// ascender - descender is 11.78pt, rounded up.
    static let captionLineHeight: CGFloat = 12

    /// Row heights come from the row views themselves. A single shared constant
    /// only fits Rules, whose rows are `.frame(height: T.rowHeight)`.
    enum ListRowHeight {
        /// `RulesTabView.rulesRow`: `.frame(height: T.rowHeight)`.
        static let rules: CGFloat = MenuBarLayoutTokens.rowHeight

        /// `ConnectionsTabView.connectionRow`: three `ConnectionsLayout.rowLineHeight`
        /// (16pt) lines, two `T.space2` stack gaps and `T.space2` vertical padding.
        static let connections = PanelHeightPolicy.stackedRowHeight(
            lines: 3,
            lineHeight: 16,
            spacing: MenuBarLayoutTokens.space2,
            verticalPadding: MenuBarLayoutTokens.space2)

        /// `LogsTabView.logEntryRow` with its `.padding(.vertical, T.space4)`: the caption
        /// label line plus a message wrapping to two lines at panel width, separated by
        /// `T.space2` stack gaps. The optional `[detail]` line is not counted; messages
        /// carry it only sometimes.
        static let logs = PanelHeightPolicy.stackedRowHeight(
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
        case .rules: .list(rows: 9, rowHeight: ListRowHeight.rules)
        case .connections: .list(rows: 9, rowHeight: ListRowHeight.connections)
        case .logs: .list(rows: 11, rowHeight: ListRowHeight.logs)
        }
    }

    /// True when the tab measures itself instead of asking for a row budget.
    static func measuresOwnHeight(_ tab: RootTab) -> Bool {
        self.contentKind(for: tab) == .measured
    }

    /// Rows a list tab asks for, or `nil` for tabs that measure themselves.
    static func rowBudget(for tab: RootTab) -> (rows: Int, rowHeight: CGFloat)? {
        guard case let .list(rows, rowHeight) = self.contentKind(for: tab) else { return nil }
        return (rows, rowHeight)
    }

    /// Height the tab asks the scroll area to have: its measured height for a
    /// measured tab, `rows * rowHeight` for a list tab.
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
        case let .list(rows, rowHeight):
            rowHeight * CGFloat(rows)
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
