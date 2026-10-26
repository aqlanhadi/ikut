import SwiftUI

/// The frame of every card sheet (Decision #84, D45): the stop cards and Report. A header with a close button, a body that is as tall as
/// its content up to `maxBodyHeight` and scrolls past it, and the actions fixed at the bottom.
struct CardSheetFrame<Content: View, Actions: View>: View {
    /// How tall the card body grows before it scrolls.
    static var maxBodyHeight: CGFloat { 220 }

    var title: String
    var subtitle: String?
    /// The body scrolls past this height (default `maxBodyHeight`).
    var bodyCap: CGFloat = CardSheetFrame.maxBodyHeight
    /// The close button's accessibility identifier, and the container's.
    var closeIdentifier = "stop.card.close"
    var containerIdentifier = "stop.card"
    var onClose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    @State private var contentHeight: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.inPanelSheet) private var inSheet
    /// How far the actions hang down into the sheet's bottom safe area (`PanelSheet.barLift`).
    @Environment(\.cardActionLift) private var lift
    private var hasActions: Bool { Actions.self != EmptyView.self }

    /// A little taller at accessibility sizes, where a row is tall: the last row is not left half cut.
    private var cap: CGFloat { typeSize.isAccessibilitySize ? bodyCap + 40 : bodyCap }

    private func body(of content: Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.gap) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            SheetHeader(
                title: title, subtitle: subtitle, subtitleFont: .subheadline,
                // 16 pt from the top and trailing edges: the 38 pt corner minus the button's 22 pt radius.
                closeOffset: CGSize(width: Spacing.xs, height: -Spacing.xs), closeIdentifier: closeIdentifier, closeOnGlass: true,
                onClose: onClose
            )
            // The header keeps all its lines; when room is short the body gives way, not the title.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            // As tall as the content; past the cap the body scrolls. Nothing else fills the space.
            let natural = body(of: content)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            if contentHeight > cap {
                ScrollView { natural.padding(.bottom, GlassSurface.active ? 14 : 24) }
                    .frame(maxHeight: cap)
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                    // The last rows fade out above the actions instead of being cut.
                    .mask(
                        VStack(spacing: 0) {
                            Color.black
                            // Shorter and not quite clear on glass, so a half-shown row stays readable.
                            LinearGradient(
                                colors: [.black, GlassSurface.active ? .black.opacity(0.4) : .clear],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: GlassSurface.active ? 14 : 24)
                        })
            } else {
                natural
            }
            if hasActions { VStack(spacing: Spacing.xs) { actions } }
        }
        // 20 pt on every edge: 16 would put the title inside the 38 pt corner curve. The same surface as the
        // convoy panel. No grabber and no swipe down to close: the body scrolls, so a swipe is for
        // scrolling; the close button is the way out.
        .padding(.horizontal, Spacing.block)
        .padding(.top, Spacing.block)
        // With actions, the buttons hang into the bottom safe area like the convoy sheet's bar, so the gap under
        // them equals the gap beside them (`block`); without a safe area they keep the plain padding.
        .padding(.bottom, hasActions && lift > 0 ? -lift : Spacing.block)
        .glassSurface(if: !inSheet)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerIdentifier)
    }
}

extension CardSheetFrame where Actions == EmptyView {
    init(
        title: String, subtitle: String? = nil, bodyCap: CGFloat = CardSheetFrame.maxBodyHeight,
        closeIdentifier: String = "stop.card.close", containerIdentifier: String = "stop.card",
        onClose: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, subtitle: subtitle, bodyCap: bodyCap, closeIdentifier: closeIdentifier,
            containerIdentifier: containerIdentifier, onClose: onClose, content: content, actions: { EmptyView() })
    }
}

