import SwiftUI

extension MenuBarRootView {
    private var hasMeasuredFixedSections: Bool {
        topHeaderHeight > 0 && modeAndTabSectionHeight > 0 && footerBarHeight > 0
    }

    private var hasResolvedCurrentTabLayout: Bool {
        guard self.hasMeasuredFixedSections else { return false }
        guard PanelHeightPolicy.measuresOwnHeight(self.rootViewModel.currentTab) else { return true }
        return self.currentTabContentHeight > 0
    }

    private var fixedSectionHeight: CGFloat {
        topHeaderHeight + modeAndTabSectionHeight + footerBarHeight
    }

    private var fallbackTabScrollAreaHeight: CGFloat {
        max(0, popoverLayoutModel.resolvedPanelHeight - self.fixedSectionHeight)
    }

    private var availableTabScrollAreaHeight: CGFloat {
        max(0, popoverLayoutModel.maxPanelHeight - self.fixedSectionHeight)
    }

    /// Measured tabs report their own height; list tabs ask for a row budget.
    /// `PanelHeightPolicy` owns the screen clamp, so this value is used as-is.
    private var requestedTabScrollAreaHeight: CGFloat {
        PanelHeightPolicy.requestedHeight(
            for: self.rootViewModel.currentTab,
            measuredHeight: self.currentTabContentHeight,
            usableHeight: self.availableTabScrollAreaHeight)
    }

    var tabScrollAreaHeight: CGFloat {
        guard self.hasResolvedCurrentTabLayout else { return self.fallbackTabScrollAreaHeight }
        return self.requestedTabScrollAreaHeight
    }

    var resolvedPanelHeight: CGFloat {
        guard self.hasResolvedCurrentTabLayout else { return popoverLayoutModel.resolvedPanelHeight }
        return self.fixedSectionHeight + self.tabScrollAreaHeight
    }

    /// Re-requests height after a tab switch. Lists have no measured height, so the
    /// panel would otherwise keep whatever the previous tab asked for.
    func applyPanelHeightForCurrentTab() {
        self.publishPreferredPanelHeight()
    }

    enum SectionHeightTarget {
        case header
        case modeAndTab
        case footer
    }

    func updateSectionHeight(_ measured: CGFloat, target: SectionHeightTarget) {
        let normalized = max(0, measured)

        switch target {
        case .header:
            if abs(topHeaderHeight - normalized) > 0.5 {
                topHeaderHeight = normalized
            }
        case .modeAndTab:
            if abs(modeAndTabSectionHeight - normalized) > 0.5 {
                modeAndTabSectionHeight = normalized
            }
        case .footer:
            if abs(footerBarHeight - normalized) > 0.5 {
                footerBarHeight = normalized
            }
        }

        // The three sections report independently, so the value measured right now is
        // passed through instead of being read back from state.
        self.publishRowBudgetHeight(measuring: target, as: normalized)
    }

    func updateCurrentTabContentHeight(_ measured: CGFloat, for tab: RootTab) {
        guard tab == self.rootViewModel.currentTab else { return }

        let normalized = max(0, measured)
        guard abs(self.currentTabContentHeight - normalized) > 0.5 else { return }

        self.currentTabContentHeight = normalized
    }

    func publishPreferredPanelHeight() {
        guard self.hasResolvedCurrentTabLayout else { return }
        popoverLayoutModel.requestPanelHeight(self.resolvedPanelHeight.rounded(.up))
    }

    /// A list tab's height follows from the fixed sections plus the policy's row
    /// budget, so publish it as soon as the last fixed section is measured. Without
    /// this the first expand of a list tab sits at `PopoverLayoutModel`'s default and
    /// then jumps. `requestPanelHeight` ignores an unchanged value, so publishing on
    /// every measurement cannot oscillate between two heights.
    private func publishRowBudgetHeight(measuring target: SectionHeightTarget, as measured: CGFloat) {
        guard !PanelHeightPolicy.measuresOwnHeight(self.rootViewModel.currentTab) else { return }

        let header = target == .header ? measured : self.topHeaderHeight
        let modeAndTab = target == .modeAndTab ? measured : self.modeAndTabSectionHeight
        let footer = target == .footer ? measured : self.footerBarHeight
        guard header > 0, modeAndTab > 0, footer > 0 else { return }

        // A non-positive usable height means the fixed sections already fill the
        // screen; the policy collapses that to its floor and the layout model caps it.
        let fixed = header + modeAndTab + footer
        let scrollAreaHeight = PanelHeightPolicy.requestedHeight(
            for: self.rootViewModel.currentTab,
            measuredHeight: 0,
            usableHeight: popoverLayoutModel.maxPanelHeight - fixed)
        popoverLayoutModel.requestPanelHeight((fixed + scrollAreaHeight).rounded(.up))
    }
}
