#if DEBUG
import SwiftUI

/// D81: every migrated `ikutButton` call site, built the way the screen builds it, with its laid-out height printed
/// under it (and written as JSON to `IKUT_COMPARE_DUMP` when set). Launch states `button-sizes` (default text size),
/// `button-sizes-ax` (accessibility text size). Each block is a surface: filled on a plain screen, glass on glass.
struct ButtonSizesDemo: View {
    var large = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                block("Plain screen (filled)", surface: .plain) {
                    row("welcome.getStarted") { Button {} label: { Text("Get started").frame(maxWidth: .infinity) }.ikutButton(.primary, size: .main) }
                    row("welcome.join") { Button {} label: { Label("Join with a code", systemImage: "qrcode").frame(maxWidth: .infinity) }.ikutButton(.link) }
                    row("mapPick.use") { Button {} label: { Text("Use this place").frame(maxWidth: .infinity) }.ikutButton(.primary, size: .main) }
                    row("recapPage.share") { Button {} label: { Label("Share recap", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.ikutButton(.primary, size: .main) }
                    row("recapPage.done") { Button {} label: { Text("Done").frame(maxWidth: .infinity) }.ikutButton(.link) }
                    row("secondary") { Button {} label: { Text("Secondary").frame(maxWidth: .infinity) }.ikutButton(.secondary) }
                }
                block("Glass sheet", surface: .glass) {
                    row("lobby.copy") { Button {} label: { Label("Copy", systemImage: "doc.on.doc").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity) }.ikutButton(.link) }
                    row("lobby.qr") { Button {} label: { Label("QR code", systemImage: "qrcode").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity) }.ikutButton(.link) }
                    row("addStop.add") { Button {} label: { Text("Add Petronas Gopeng").font(.headline).frame(maxWidth: .infinity) }.ikutButton(.primary) }
                    row("suggest.notNow") { Button {} label: { Text("Not now").frame(maxWidth: .infinity) }.ikutButton(.secondary) }
                    row("suggest.add") { Button {} label: { Text("Add").frame(maxWidth: .infinity) }.ikutButton(.primary) }
                    row("recapSheet.share") { Button {} label: { Label("Share recap", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.ikutButton(.primary) }
                    row("recapSheet.done") { Button {} label: { Text("Done").frame(maxWidth: .infinity) }.ikutButton(.link) }
                    ForEach(["primary", "secondary", "positive", "ghost", "destructive"], id: \.self) { name in
                        row("stopCard.\(name)") {
                            StopActionButton(title: name.capitalized, style: Self.style(name), id: "sizes.\(name)", action: {})
                        }
                    }
                }
            }
            .padding(Spacing.l)
        }
        .background(Color.ikutScreen)
        .dynamicTypeSize(large ? .accessibility3 : .large)
    }

    private static func style(_ name: String) -> StopActionButton.Style {
        switch name {
        case "primary": .primary
        case "secondary": .secondary
        case "positive": .positive
        case "ghost": .ghost
        default: .destructive
        }
    }

    private func block<C: View>(_ title: String, surface: IkutSurface, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(Spacing.m)
        .background {
            if surface == .glass {
                LinearGradient(colors: [.green.opacity(0.5), .blue.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else { Color.ikutScreen }
        }
        .buttonSurface(surface)
    }

    private func row<C: View>(_ name: String, @ViewBuilder _ button: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            button().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { Heights.shared.set(name, $0) }
            Text(name).font(.caption2.monospaced()).foregroundStyle(.secondary).accessibilityIdentifier("sizes.\(name).caption")
        }
    }
}

@MainActor private final class Heights {
    static let shared = Heights()
    private var values: [String: CGFloat] = [:]

    func set(_ name: String, _ height: CGFloat) {
        values[name] = height
        guard let path = ProcessInfo.processInfo.environment["IKUT_COMPARE_DUMP"] else { return }
        let rounded = values.mapValues { ($0 * 10).rounded() / 10 }
        if let data = try? JSONSerialization.data(withJSONObject: rounded, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
