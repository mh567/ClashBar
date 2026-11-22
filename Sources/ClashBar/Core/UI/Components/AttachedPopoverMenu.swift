import AppKit
import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

struct AttachedPopoverMenu<Label: View, Content: View>: View {
    let width: CGFloat?
    let maxHeight: CGFloat?
    let expandAnchor: Bool
    let onWillPresent: (() -> Void)?
    let label: (_ isHovered: Bool) -> Label
    let content: (_ dismiss: @escaping () -> Void) -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isAnchorHovered = false
    @State private var isPopoverRequested = false
    @State private var shouldBuildPopoverContent = false

    init(
        width: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        expandAnchor: Bool = true,
        onWillPresent: (() -> Void)? = nil,
        @ViewBuilder label: @escaping (_ isHovered: Bool) -> Label,
        @ViewBuilder content: @escaping (_ dismiss: @escaping () -> Void) -> Content)
    {
        self.width = width
        self.maxHeight = maxHeight
        self.expandAnchor = expandAnchor
        self.onWillPresent = onWillPresent
        self.label = label
        self.content = content
    }

    var body: some View {
        Button(action: self.togglePopover) {
            self.anchorLabel
        }
        .buttonStyle(MenuBarInteractionStyle())
        .onHover { hovering in
            guard self.isEnabled else { return }
            self.isAnchorHovered = hovering
        }
        .task(id: self.isEnabled) {
            if !self.isEnabled { self.dismissPopover() }
        }
        .background(
            SideAttachedPopoverHost(
                anchorHovered: self.$isAnchorHovered,
                popoverRequested: self.$isPopoverRequested,
                width: self.width,
                maxHeight: self.maxHeight,
                onVisibilityChanged: { visible in
                    self.shouldBuildPopoverContent = visible
                },
                content: self.popoverContent))
    }

    var anchorLabel: some View {
        let isActive = self.isAnchorHovered || self.isPopoverRequested
        return Group {
            if self.expandAnchor {
                self.label(isActive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                self.label(isActive)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    var popoverContent: some View {
        if self.shouldBuildPopoverContent {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    self.content {
                        self.dismissPopover()
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(width: self.width, alignment: .leading)
            .frame(maxHeight: self.maxHeight)
            .padding(T.space8)
            .background {
                AppMaterialSurface(
                    cornerRadius: T.panelCornerRadius,
                    fallbackStyle: .material(.regularMaterial),
                    stroke: self.nativeSeparator.opacity(0.46),
                    lineWidth: T.stroke)
            }
            .shadow(
                color: self.nativeShadow.opacity(T.Shadow.standard.opacity),
                radius: T.Shadow.standard.radius,
                x: T.Shadow.standard.x,
                y: T.Shadow.standard.y)
        }
    }

    private func requestOpen() {
        self.onWillPresent?()
        self.shouldBuildPopoverContent = true
        self.isPopoverRequested = true
    }

    private func togglePopover() {
        guard self.isEnabled else { return }
        if self.isPopoverRequested {
            self.dismissPopover()
        } else {
            self.requestOpen()
        }
    }

    private func dismissPopover() {
        self.shouldBuildPopoverContent = false
        self.isPopoverRequested = false
    }
}

struct AttachedPopoverMenuItem: View {
    enum SelectionIndicatorPlacement {
        case leading
        case trailing
    }

    let title: String
    var subtitle: String?
    var leadingSymbol: String?
    var leadingTint: Color = .secondary
    var trailingStatusText: String?
    var trailingStatusTextColor: Color?
    var showLeadingDot: Bool = false
    var selected: Bool = false
    var selectionIndicatorPlacement: SelectionIndicatorPlacement = .leading
    var destructive: Bool = false
    var isLoading: Bool = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var isHighlighted: Bool {
        self.isEnabled && self.isHovered
    }

    var body: some View {
        Button {
            self.action()
        } label: {
            HStack(spacing: T.space6) {
                if self.showLeadingDot {
                    Circle()
                        .fill(self.leadingTint)
                        .frame(width: 8, height: 8)
                        .frame(width: 12, alignment: .center)
                } else if let leadingSymbol {
                    ZStack {
                        Image(systemName: leadingSymbol)
                            .font(.app(size: T.FontSize.caption, weight: .semibold))
                            .foregroundStyle(self.leadingTint)
                            .opacity(self.isLoading ? 0 : 1)

                        ProgressView()
                            .controlSize(.mini)
                            .opacity(self.isLoading ? 1 : 0)
                    }
                    .frame(width: 12, alignment: .center)
                } else if self.selectionIndicatorPlacement == .leading {
                    Image(systemName: "checkmark")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .opacity(self.selected ? 1 : 0)
                        .frame(width: 12, alignment: .center)
                } else {
                    Color.clear
                        .frame(width: 12, height: 12)
                }
                VStack(alignment: .leading, spacing: T.space1) {
                    Text(self.title)
                        .font(.app(size: T.FontSize.body, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.app(size: T.FontSize.caption, weight: .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(self.isHighlighted ? self.nativeSelectedMenuText
                                .opacity(0.9) : self.nativeSecondaryLabel)
                    }
                }
                Spacer(minLength: 0)
                if let trailingStatusText = self.trailingStatusText?.trimmedNonEmpty {
                    Text(trailingStatusText)
                        .font(.app(size: T.FontSize.caption, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(self.trailingStatusForeground)
                }
                if self.selected, self.selectionIndicatorPlacement == .trailing {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(self.trailingSelectionForeground)
                }
            }
            .foregroundStyle(self.itemForeground)
            .padding(.horizontal, T.space6)
            .padding(.vertical, T.space2)
            .background(
                RoundedRectangle(cornerRadius: T.cornerRadius, style: .continuous)
                    .fill(self.itemBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { self.isHovered = $0 }
    }

    private var itemForeground: Color {
        if self.isHighlighted {
            return self.nativeSelectedMenuText
        }
        return self.destructive ? .red : self.nativePrimaryLabel
    }

    private var itemBackground: Color {
        self.isHighlighted ? self.nativeHoverFill : .clear
    }

    private var trailingSelectionForeground: Color {
        if self.isHighlighted {
            return self.nativeSelectedMenuText
        }
        return self.nativeAccent
    }

    private var trailingStatusForeground: Color {
        if self.isHighlighted {
            return self.nativeSelectedMenuText.opacity(0.96)
        }
        return self.trailingStatusTextColor ?? self.nativeSecondaryLabel
    }
}

struct AttachedPopoverMenuDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, T.space2)
    }
}

@MainActor
private protocol SideAttachedPopoverManaging: AnyObject {
    func deactivateAndClose()
}

@MainActor
private enum SideAttachedPopoverRegistry {
    static var activeCoordinator: (any SideAttachedPopoverManaging)?
}

@MainActor
private struct SideAttachedPopoverHost<Content: View>: NSViewRepresentable {
    @Binding var anchorHovered: Bool
    @Binding var popoverRequested: Bool
    let width: CGFloat?
    let maxHeight: CGFloat?
    let onVisibilityChanged: ((Bool) -> Void)?
    let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(
            anchorHovered: self.$anchorHovered,
            popoverRequested: self.$popoverRequested,
            onVisibilityChanged: self.onVisibilityChanged,
            content: self.content)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorHovered = self.$anchorHovered
        context.coordinator.popoverRequested = self.$popoverRequested
        context.coordinator.width = self.width
        context.coordinator.maxHeight = self.maxHeight
        context.coordinator.onVisibilityChanged = self.onVisibilityChanged
        context.coordinator.hostingController.rootView = self.content
        context.coordinator.sync(anchorView: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.closeNow()
    }

    @MainActor
    final class Coordinator: NSObject, SideAttachedPopoverManaging {
        var anchorHovered: Binding<Bool>
        var popoverRequested: Binding<Bool>
        var width: CGFloat?
        var maxHeight: CGFloat?
        var onVisibilityChanged: ((Bool) -> Void)?

        let panel: SideAttachedMenuPanel
        let hostingController: NSHostingController<Content>

        private weak var anchorView: NSView?
        private weak var hostWindow: NSWindow?
        private var clickMonitor: Any?
        private var resignActiveObserver: NSObjectProtocol?
        /// The side this popover settled on. Non-nil means `showOrUpdate` already placed it
        /// once, so later layout passes keep that side instead of re-deciding.
        private var pinnedSide: PanelAttachmentSide?
        private let edgeOverlap: CGFloat = 1
        private var reportedVisible = false

        init(
            anchorHovered: Binding<Bool>,
            popoverRequested: Binding<Bool>,
            onVisibilityChanged: ((Bool) -> Void)?,
            content: Content)
        {
            self.anchorHovered = anchorHovered
            self.popoverRequested = popoverRequested
            self.onVisibilityChanged = onVisibilityChanged
            self.hostingController = NSHostingController(rootView: content)
            self.panel = SideAttachedMenuPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true)

            super.init()

            self.panel.isReleasedWhenClosed = false
            self.panel.isOpaque = false
            self.panel.backgroundColor = .clear
            self.panel.hasShadow = true
            self.panel.hidesOnDeactivate = true
            self.panel.level = .statusBar
            self.panel.collectionBehavior = [.transient, .moveToActiveSpace, .ignoresCycle]
            self.panel.contentViewController = self.hostingController
            self.panel.acceptsMouseMovedEvents = true
        }

        func sync(anchorView: NSView) {
            self.anchorView = anchorView
            self.hostWindow = anchorView.window

            if self.popoverRequested.wrappedValue {
                self.showOrUpdate()
            } else {
                self.closeNow()
            }
        }

        private func showOrUpdate() {
            guard
                let anchorView,
                let hostWindow
            else { return }

            self.panel.appearance = hostWindow.effectiveAppearance
            self.hostingController.view.appearance = hostWindow.effectiveAppearance

            // `fittingSize` is only meaningful once the view has laid out. Reading it first
            // returns the hosting view's placeholder size, so the panel would be placed at a
            // guess and then visibly resize on the next pass.
            self.forceLayout()

            let fitting = self.hostingController.view.fittingSize
            guard let anchorContext = PanelAnchorContext.resolve(for: anchorView) else { return }
            guard let placement = anchorContext.sideAttachedPlacement(
                SideAttachedPlacementOptions(
                    contentSize: fitting,
                    preferredWidth: self.width,
                    maximumHeight: self.maxHeight,
                    screenPadding: 6,
                    edgeOverlap: self.edgeOverlap,
                    pinnedSide: self.pinnedSide))
            else {
                return
            }

            if let attachmentSide = placement.attachmentSide {
                self.pinnedSide = attachmentSide
            }

            self.panel.setFrame(placement.frame, display: true)
            self.ensureExclusiveVisibility()

            if !self.panel.isVisible {
                self.panel.orderFront(nil)
            }
            ScrollIndicatorPolicy.suppressRecursively(in: self.panel.contentView)
            self.reportVisibility(true)
            self.startClickMonitorIfNeeded()
        }

        /// Lays the hosted content out so `fittingSize` reflects the real content instead of
        /// the placeholder rect the hosting view starts with.
        private func forceLayout() {
            let view = self.hostingController.view
            view.layoutSubtreeIfNeeded()
        }

        func closeNow() {
            self.pinnedSide = nil
            self.stopClickMonitor()
            if self.panel.isVisible {
                self.panel.orderOut(nil)
            }
            self.reportVisibility(false)
            if SideAttachedPopoverRegistry.activeCoordinator === self {
                SideAttachedPopoverRegistry.activeCoordinator = nil
            }
        }

        private func reportVisibility(_ visible: Bool) {
            guard self.reportedVisible != visible else { return }
            self.reportedVisible = visible
            guard let onVisibilityChanged else { return }
            DispatchQueue.main.async {
                onVisibilityChanged(visible)
            }
        }

        private func ensureExclusiveVisibility() {
            if let active = SideAttachedPopoverRegistry.activeCoordinator, active !== self {
                active.deactivateAndClose()
            }
            SideAttachedPopoverRegistry.activeCoordinator = self
        }

        func deactivateAndClose() {
            self.anchorHovered.wrappedValue = false
            self.popoverRequested.wrappedValue = false
            self.closeNow()
        }

        private func startClickMonitorIfNeeded() {
            guard self.clickMonitor == nil else { return }
            self.clickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown])
            { [weak self] event in
                self?.closeIfClickIsOutsidePopover(event)
                return event
            }

            self.resignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main)
            { [weak self] _ in
                Task { @MainActor in
                    self?.deactivateAndClose()
                }
            }
        }

        private func stopClickMonitor() {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
            if let resignActiveObserver {
                NotificationCenter.default.removeObserver(resignActiveObserver)
                self.resignActiveObserver = nil
            }
        }

        private func closeIfClickIsOutsidePopover(_ event: NSEvent) {
            guard self.panel.isVisible else { return }

            if event.window === self.panel {
                let location = event.locationInWindow
                guard let bounds = self.panel.contentView?.bounds, bounds.contains(location) else {
                    self.deactivateAndClose()
                    return
                }
                return
            }

            guard !self.isClickInsideAnchor(event) else { return }
            self.deactivateAndClose()
        }

        private func isClickInsideAnchor(_ event: NSEvent) -> Bool {
            guard let anchorView, let hostWindow = anchorView.window, event.window === hostWindow else {
                return false
            }
            let locationInAnchor = anchorView.convert(event.locationInWindow, from: nil)
            return anchorView.bounds.contains(locationInAnchor)
        }
    }
}

@MainActor
private final class SideAttachedMenuPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
