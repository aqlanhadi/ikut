import SwiftUI

/// The floating glass panel at the bottom of the map: "3 in Convoy", spread and ETA, one row per
/// car with its gap, a Joining section, then Report and Stop. Tap or drag the grabber to collapse
/// it to the header and the buttons.
///
/// A custom overlay rather than a `.sheet`: a sheet that is always up would stop the map from
/// presenting the report sheet, and the mock's inset glass card is what this matches.
struct ConvoyPanel: View {
    var model: TripMapModel
    @Binding var expanded: Bool
    var canReport: Bool
    var onReport: () -> Void
    var onStop: () -> Void

    @State private var listHeight: CGFloat = 0

    private var convoy: ConvoyModel { model.convoy }
    private let maxListHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            if expanded {
                list
            }
            buttons
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(.snappy, value: expanded)
    }

    // MARK: Pieces

    private var grabber: some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .gesture(
                DragGesture(minimumDistance: 12).onEnded { drag in
                    if drag.translation.height > 20 { expanded = false }
                    if drag.translation.height < -20 { expanded = true }
                })
            .accessibilityElement()
            .accessibilityLabel(expanded ? "Collapse convoy list" : "Expand convoy list")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { expanded.toggle() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(convoy.title)
                .font(.title2.bold())
            if !convoy.subtitle.isEmpty {
                Text(convoy.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if convoy.convoy.isEmpty && convoy.joining.isEmpty {
                Text("Waiting for cars to share their location")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var list: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    })
        }
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
        .frame(height: min(max(listHeight, 0), maxListHeight))
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let warning = model.separationWarning {
                separation(warning)
            }
            ForEach(Array(convoy.convoyRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 46) }
                ConvoyRowView(row: row)
            }
            if !convoy.joiningRows.isEmpty {
                Text("Joining")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(convoy.joiningRows) { row in
                    JoiningRowView(row: row)
                }
            }
        }
    }

    private func separation(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(MapPalette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(MapPalette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 6)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: onReport) {
                Label("Report", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(MapPalette.accent.opacity(canReport ? 1 : 0.4), in: Capsule())
            }
            .disabled(!canReport)
            Button(action: onStop) {
                Label {
                    Text("Stop")
                } icon: {
                    Image(systemName: "minus.octagon.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .font(.headline)
                .frame(width: 130, height: 50)
                .foregroundStyle(.primary)
                .background(Color(.systemGray5).opacity(0.7), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Rows

private struct RowBadge: View {
    var number: Int?
    var colorHex: String
    var dashed = false

    var body: some View {
        let color = Color(mapHex: colorHex)
        Text(number.map(String.init) ?? "·")
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .foregroundStyle(dashed ? color : .white)
            .frame(width: 30, height: 30)
            .background(dashed ? Color.white : color, in: Circle())
            .overlay {
                if dashed {
                    Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 2.5, dash: [4, 3]))
                }
            }
            .accessibilityHidden(true)
    }
}

struct ConvoyRowView: View {
    var row: ConvoyRowText

    var body: some View {
        HStack(spacing: 12) {
            RowBadge(number: row.number, colorHex: row.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).font(.body).lineLimit(1)
                Text(row.subtitle)
                    .font(.footnote)
                    .foregroundStyle(row.subtitleIsWarning ? MapPalette.staleChipText : Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(row.trailingPrimary)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.isSeparated ? MapPalette.warning : Color.primary)
                Text(row.trailingSecondary)
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
        .frame(minHeight: 54)
        .padding(.horizontal, 4)
        .opacity(row.isStale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

struct JoiningRowView: View {
    var row: JoiningRowText

    var body: some View {
        HStack(spacing: 12) {
            RowBadge(number: row.number, colorHex: row.color, dashed: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).font(.body).lineLimit(1)
                Text(row.subtitle)
                    .font(.footnote)
                    .foregroundStyle(row.subtitleIsWarning ? MapPalette.staleChipText : Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(row.trailingPrimary).font(.body.weight(.semibold)).monospacedDigit()
                Text(row.trailingSecondary).font(.footnote).foregroundStyle(Color(.secondaryLabel))
            }
        }
        .frame(minHeight: 54)
        .padding(.horizontal, 4)
        .opacity(row.isStale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
