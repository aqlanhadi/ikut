import ActivityKit
import SwiftUI
import WidgetKit

/// The convoy on the Lock Screen, in the Dynamic Island and on the `.small` card (CarPlay, Apple Watch), drawn as
/// LiveActivity.dc.html shows. It only draws: the app picks the state (`ConvoyActivityLogic`) and the words come from
/// `ActivityWords`. Nothing is drawn on the 126 x 37 pt camera cutout.
struct ConvoyLiveActivity: Widget {
    var body: some WidgetConfiguration { Self.configuration }

    static var configuration: some WidgetConfiguration {
        ActivityConfiguration(for: ConvoyActivityAttributes.self) { context in
            ActivityRoot(context: context)
                .activityBackgroundTint(ActivityPalette.card)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let words = ActivityWords(state, display: ConvoyActivityPresentation.display(state, isStale: context.isStale), now: Date())
            let trailing = ConvoyActivityPresentation.trailing(state, now: Date())
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { ActivityBadge(words: words, size: ActivitySize.expandedBadge) }
                DynamicIslandExpandedRegion(.trailing) { ExpandedValue(words: words, trailing: trailing) }
                DynamicIslandExpandedRegion(.bottom) { ExpandedBottom(state: state, words: words, stale: context.isStale) }
            } compactLeading: {
                HStack(spacing: 4) {
                    if words.isAlert {
                        ActivityGlyph(words: words, size: ActivitySize.alertGlyph)
                    } else {
                        IkutMark(size: ActivitySize.mark)
                        ActivityGlyph(words: words, size: ActivitySize.compactGlyph)
                    }
                }
            } compactTrailing: {
                CompactValue(trailing: trailing, tint: words.bigTint ?? words.tint, greyed: context.isStale)
            } minimal: {
                if words.isAlert {
                    ActivityGlyph(words: words, size: ActivitySize.minimalAlertGlyph)
                } else {
                    IkutMark(size: ActivitySize.minimalMark)
                }
            }
        }
    }
}

/// The same activity, also offered to the `.small` family (CarPlay Dashboard, Apple Watch Smart Stack), iOS 18 and later.
@available(iOS 18.0, *)
struct ConvoyLiveActivityWithSmall: Widget {
    var body: some WidgetConfiguration { ConvoyLiveActivity.configuration.supplementalActivityFamilies([.small]) }
}

/// The Lock Screen card, or the small card where the system asks for the `.small` family (iOS 18).
private struct ActivityRoot: View {
    let context: ActivityViewContext<ConvoyActivityAttributes>

    var body: some View {
        if #available(iOS 18.0, *) {
            FamilyRoot(context: context)
        } else {
            LockCard(context: context)
        }
    }
}

@available(iOS 18.0, *)
private struct FamilyRoot: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<ConvoyActivityAttributes>

    var body: some View {
        switch family {
        case .small: SmallCard(context: context)
        default: LockCard(context: context)
        }
    }
}

// MARK: Lock Screen

private struct LockCard: View {
    let context: ActivityViewContext<ConvoyActivityAttributes>

    var body: some View {
        let state = context.state
        let words = ActivityWords(state, display: ConvoyActivityPresentation.display(state, isStale: context.isStale), now: Date())
        VStack(alignment: .leading, spacing: ActivitySize.gap) {
            HStack(spacing: ActivitySize.gap) {
                ActivityBadge(words: words)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: words.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let subtitle = words.subtitle {
                        Text(verbatim: subtitle).font(.footnote).foregroundStyle(ActivityPalette.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let big = words.big { BigValue(text: big, caption: words.caption, tint: words.bigTint, size: 26) }
            }
            if words.showsTrack { ActivityTrack(state: state, dimmed: context.isStale) }
            if let line = words.line {
                Text(verbatim: line).font(.subheadline)
                    .foregroundStyle(words.lineIsWarning ? ActivityPalette.yellow : ActivityPalette.line).lineLimit(2)
            }
            if let request = words.request { RequestRow(request: request, size: 14) }
            if let leave = words.leave { LeaveRow(text: leave.text, size: 14) }
        }
        .padding(ActivitySize.cardInsets)
        .foregroundStyle(.white)
        .frame(maxHeight: 160)
    }
}

private struct BigValue: View {
    let text: String
    let caption: String?
    var tint: Color?
    let size: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: text).font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint ?? .white).lineLimit(1).minimumScaleFactor(0.7)
            if let caption {
                Text(verbatim: caption).font(.caption2).foregroundStyle(ActivityPalette.secondary).lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: 150, alignment: .trailing)
    }
}

private struct RequestRow: View {
    let request: (text: String, detail: String)
    let size: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.fuel).foregroundStyle(ActivityPalette.positive)
            Text(verbatim: request.text).fontWeight(.semibold).lineLimit(1)
            Text(verbatim: "· \(request.detail)").foregroundStyle(ActivityPalette.secondary).lineLimit(1)
        }
        .font(.system(size: size))
    }
}

private struct LeaveRow: View {
    let text: String
    let size: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Symbol.paused)
            Text(verbatim: text).lineLimit(1)
        }
        .font(.system(size: size)).foregroundStyle(ActivityPalette.secondary)
    }
}

// MARK: Dynamic Island

private struct CompactValue: View {
    let trailing: ConvoyActivityPresentation.Trailing
    let tint: Color
    let greyed: Bool

    var body: some View {
        let colour = greyed ? ActivityPalette.grey : tint
        switch trailing {
        case .nothing: EmptyView()
        case .cars: Image(systemName: Symbol.cars).foregroundStyle(ActivityPalette.secondary)
        case .tick: Image(systemName: Symbol.tick).font(.system(size: 16, weight: .bold)).foregroundStyle(colour)
        case .cross: Image(systemName: Symbol.close).font(.system(size: 16, weight: .bold)).foregroundStyle(ActivityPalette.secondary)
        case .value(let text, let prefix):
            HStack(spacing: 3) {
                switch prefix {
                case .none: EmptyView()
                case .ring: Circle().strokeBorder(.white, lineWidth: 2).frame(width: 9, height: 9)
                case .flag: Image(systemName: Symbol.flag).font(.system(size: 11, weight: .bold))
                case .tick: Image(systemName: Symbol.tick).font(.system(size: 11, weight: .heavy))
                }
                Text(verbatim: text).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(colour).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
}

/// The top row beside the cutout: the one value the compact island shows, with its label under it.
private struct ExpandedValue: View {
    let words: ActivityWords
    let trailing: ConvoyActivityPresentation.Trailing

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let big = words.big {
                Text(verbatim: big).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(words.bigTint ?? .white).lineLimit(1).minimumScaleFactor(0.7)
            } else if case .value(let text, _) = trailing {
                Text(verbatim: text).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(words.bigTint ?? .white)
            } else if case .cars = trailing {
                Image(systemName: Symbol.cars).font(.system(size: 22, weight: .semibold)).foregroundStyle(ActivityPalette.secondary)
            } else if case .tick = trailing {
                Image(systemName: Symbol.tick).font(.system(size: 22, weight: .bold)).foregroundStyle(words.tint)
            } else if case .cross = trailing {
                Image(systemName: Symbol.close).font(.system(size: 22, weight: .bold)).foregroundStyle(ActivityPalette.secondary)
            }
            if let caption = words.caption, words.big != nil || trailing != .nothing {
                Text(verbatim: caption).font(.caption2).foregroundStyle(ActivityPalette.secondary).lineLimit(1)
            }
        }
    }
}

/// Under the cutout, full width, 160 pt at most: the title, the track and one line only (the stop or request line when
/// there is one; the gap line on the last leg), as drawn.
private struct ExpandedBottom: View {
    let state: ConvoyActivityAttributes.ContentState
    let words: ActivityWords
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: words.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let subtitle = words.subtitle, words.showsTrack == false || (words.request == nil) && state.stopName == nil {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(ActivityPalette.secondary).lineLimit(1)
                }
            }
            if words.showsTrack { ActivityTrack(state: state, dimmed: stale) }
            if let request = words.request {
                RequestRow(request: request, size: 13)
            } else if let leave = words.leave {
                LeaveRow(text: leave.text, size: 13)
            } else if let line = oneLine {
                Text(verbatim: line).font(.footnote)
                    .foregroundStyle(words.lineIsWarning ? ActivityPalette.yellow : ActivityPalette.line).lineLimit(1)
            }
        }
        .frame(maxHeight: 160 - 37)
    }

    /// The gap line is dropped while a next stop is the big value (it stays on the Lock Screen); a stale state says so.
    private var oneLine: String? {
        if words.lineIsWarning { return words.line }
        if state.kind == .inConvoy && state.stopName != nil { return nil }
        return words.line
    }
}

// MARK: .small (CarPlay Dashboard, Apple Watch Smart Stack)

private struct SmallCard: View {
    let context: ActivityViewContext<ConvoyActivityAttributes>

    var body: some View {
        let state = context.state
        let words = ActivityWords(state, display: ConvoyActivityPresentation.display(state, isStale: context.isStale), now: Date())
        VStack(alignment: .leading) {
            HStack(spacing: 6) {
                ActivityGlyph(words: words, size: 16)
                Text(verbatim: words.small.title).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: words.small.line).font(.caption).foregroundStyle(ActivityPalette.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let big = words.small.big {
                    Text(verbatim: big).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(words.bigTint ?? .white)
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
