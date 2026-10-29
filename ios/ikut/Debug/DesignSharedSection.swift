import SwiftUI

/// The "Shared" half of Settings > Design: what `UI/` provides, rendered from sample values and labelled with its
/// code name (D72).
struct DesignSharedSection: View {
    private let colors: [(String, Color)] = [
        ("ikutAccent", .ikutAccent), ("ikutPositive", .ikutPositive), ("ikutWarning", .ikutWarning),
        ("ikutScreen", .ikutScreen), ("ikutCard", .ikutCard), ("surfaceTileFill", .surfaceTileFill),
        ("surfaceSecondary", .surfaceSecondary), ("surfaceAccent", .surfaceAccent),
    ]
    private let spacing: [(String, CGFloat)] = [
        ("xxs", Spacing.xxs), ("xs", Spacing.xs), ("s", Spacing.s),
        ("m", Spacing.m), ("l", Spacing.l), ("xl", Spacing.xl),
    ]
    private let radii: [(String, CGFloat)] = [
        ("icon", Radius.icon), ("inner", Radius.inner), ("card", Radius.card),
    ]
    private let fonts: [(String, Font)] = [
        (".largeTitle", .largeTitle), (".title", .title), (".title2", .title2), (".title2.bold()", .title2.bold()),
        (".title3", .title3), (".headline", .headline), (".body", .body), (".callout", .callout),
        (".subheadline", .subheadline), (".footnote", .footnote), (".caption", .caption),
    ]
    /// In `UI/` but needing a live model, a map or a URL, so only listed.
    private let listed = [
        "BottomSheet", "CameraFlight", "CameraView", "CardSheetFrame", "RoundGlassShareLink", "RouteEnds", "SheetSearchField",
        "SheetTopRow", "StatGrid", "TripExitMenu",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader("Shared", top: Spacing.s)
            InlineNote("What UI/ provides, drawn live.")
            group("Color.ikut*") {
                ForEach(colors, id: \.0) { name, color in
                    HStack(spacing: Spacing.m) {
                        RoundedRectangle(cornerRadius: Radius.icon, style: .continuous).fill(color)
                            .overlay(RoundedRectangle(cornerRadius: Radius.icon, style: .continuous).strokeBorder(.quaternary))
                            .frame(width: 44, height: 44)
                        name.code
                    }
                }
            }
            group("Spacing") {
                ForEach(spacing, id: \.0) { name, value in
                    HStack(spacing: Spacing.m) {
                        Rectangle().fill(Color.ikutAccent).frame(width: value, height: 10)
                        "Spacing.\(name) = \(value.formatted())".code
                    }
                }
            }
            group("Radius") {
                ForEach(radii, id: \.0) { name, value in
                    HStack(spacing: Spacing.m) {
                        RoundedRectangle(cornerRadius: value, style: .continuous).fill(Color.ikutAccent.opacity(0.25))
                            .overlay(RoundedRectangle(cornerRadius: value, style: .continuous).strokeBorder(Color.ikutAccent))
                            .frame(width: 64, height: 64)
                        "Radius.\(name) = \(value.formatted())".code
                    }
                }
            }
            group("Type styles in use") {
                ForEach(fonts, id: \.0) { name, font in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Aa Meet at the petrol station").font(font).lineLimit(1)
                        name.code.foregroundStyle(.secondary)
                    }
                }
            }
            group("IkutButtonRole (ikutButton)") {
                ForEach(["primary", "secondary", "link"], id: \.self) { role in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        "\(role)".code
                        button(role, glass: false)
                        if role != "link" { "\(role), buttonSurface(.glass)".code; button(role, glass: true) }
                    }
                }
            }
            surfaces
            parts
            icons
            group("In UI/ but needs a live model, so not drawn") {
                Text(listed.joined(separator: ", ")).font(.footnote.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func button(_ role: String, glass: Bool) -> some View {
        let label = Text("Start trip").frame(maxWidth: .infinity)
        Group {
            switch role {
            case "primary": Button { } label: { label }.ikutButton(.primary)
            case "secondary": Button { } label: { label }.ikutButton(.secondary)
            default: Button { } label: { label }.ikutButton(.link)
            }
        }
        .buttonSurface(glass ? .glass : .plain)
    }

    private var surfaces: some View {
        group("Surfaces") {
            "ikutCard()".code
            Text("A card").frame(maxWidth: .infinity, minHeight: 52).ikutCard()
            "ikutTile()".code
            Text("A tile").frame(maxWidth: .infinity, minHeight: 52).ikutTile()
            "ikutSurface(fill, radius:)".code
            Text("Accent at 15%").frame(maxWidth: .infinity, minHeight: 52).ikutSurface(Color.ikutAccent.opacity(0.15), radius: Radius.inner)
            "surfaceTile()".code
            Text("A tile on glass").frame(maxWidth: .infinity, minHeight: 52).surfaceTile()
                .padding(Spacing.s).background(LinearGradient(colors: [.green, .blue], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: Radius.inner))
        }
    }

    private var parts: some View {
        group("Headers, rows and notes") {
            "CardHeader".code
            CardHeader("Ready") { ProgressView(value: 0.75).frame(width: 60); Text("3 of 4 ready") }
            "SheetHeader".code
            SheetHeader(title: "Report", subtitle: "The cars behind you get an alert.") {}
            "InlineNote (hint, alert)".code
            InlineNote("Everyone in the trip sees this name.")
            InlineNote("Couldn’t reach the server.", systemImage: "exclamationmark.triangle.fill", tone: .alert)
            "EmptyRow, RowDivider".code
            VStack(spacing: 0) { EmptyRow("No cars yet"); RowDivider(); EmptyRow("Nothing else") }.ikutCard()
            "StatCaption, Chip, DashedDivider".code
            HStack(spacing: Spacing.m) {
                StatCaption("Distance")
                Chip(text: "On the move", tone: .positive, lead: .dot(), fill: .material)
                DashedDivider().frame(height: 30)
            }
            "SheetSearchButton".code
            SheetSearchButton(placeholder: "Where to?") {}
        }
    }

    private var icons: some View {
        group("Icons and round buttons") {
            "IconTile".code
            HStack(spacing: Spacing.s) {
                IconTile(symbol: "mappin", color: .red, size: .small, font: .footnote.weight(.bold))
                IconTile(symbol: "steeringwheel", color: .ikutAccent, size: .small)
                IconTile(symbol: "fuelpump.fill", color: .orange, size: .regular, radius: Radius.icon)
            }
            "CarBadge".code
            HStack(spacing: Spacing.s) {
                CarBadge(number: 1, colorHex: "#2563EB"); CarBadge(number: 2, colorHex: "#D9480F")
                CarBadge(symbol: "plus", colorHex: "#8E8E93")
            }
            "RoundGlassIconButton".code
            HStack(spacing: Spacing.s) {
                RoundGlassIconButton(systemImage: "location.fill", label: "Centre") {}
                RoundGlassIconButton(text: "A", label: "Your name") {}
            }
            "SheetCloseButton, MapCloseButton".code
            HStack(spacing: Spacing.xl) {
                SheetCloseButton {}
                MapCloseButton {}.padding(Spacing.s).background(LinearGradient(colors: [.green, .blue], startPoint: .top, endPoint: .bottom))
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title)
            VStack(alignment: .leading, spacing: Spacing.m) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.l)
                .ikutCard()
        }
    }
}

private extension String {
    /// A code name, in monospace.
    var code: Text { Text(self).font(.footnote.monospaced()) }
}
