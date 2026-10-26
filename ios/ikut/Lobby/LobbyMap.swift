import CoreLocation
import MapKit
import SwiftUI

/// The sizes, detents and cover rule of the lobby's sheet, pure so they can be tested. Like Home's (`HomeSheet`),
/// the sheet is Apple's own, always up, with the map behind it touchable at the medium height: medium shows the top
/// of the content and the cars (canvas B4), tall the rest (B5).
enum LobbySheet {
    /// The medium detent's height at the default text size (B4's 470 pt).
    static let compactHeight: CGFloat = 470
    static let indicatorRoom = BottomSheet.indicatorRoom
    static let detentExtra = BottomSheet.detentExtra

    /// `scaled` is `compactHeight` scaled with the text size, capped so the tall detent stays well above it.
    static func compact(scaled: CGFloat) -> CGFloat {
        min(max(scaled, compactHeight), compactHeight * 1.4)
    }

    /// The map's bottom safe area: from the screen's bottom edge to the top of the medium sheet, so MapKit's logo and
    /// Legal ride above it and stay put when the sheet is pulled up.
    static func legalInset(compact: CGFloat) -> CGFloat { max(0, compact) + detentExtra }

    static func medium(_ compact: CGFloat) -> PresentationDetent { .height(compact) }
    static let tall = PresentationDetent.large
    static func detents(compact: CGFloat) -> Set<PresentationDetent> { [medium(compact), tall] }
    static func detent(expanded: Bool, compact: CGFloat) -> PresentationDetent { expanded ? tall : medium(compact) }
    static func isExpanded(_ detent: PresentationDetent) -> Bool { BottomSheet.isTall(detent, tall: tall) }

    /// What is pushed or presented from the lobby: the sheet steps aside for each and comes back when they are gone.
    struct Cover: Equatable {
        var tripMap = false
        var changeDestination = false
        var suggestStops = false
        var renaming = false
        var alwaysExplainer = false
        var confirmLeave = false
        var confirmEnd = false
    }

    /// Whether the sheet is away: anything above is up, or the lobby itself is not on screen (popped).
    static func isCovered(_ cover: Cover, lobbyOnScreen: Bool) -> Bool {
        !lobbyOnScreen || cover.tripMap || cover.changeDestination || cover.suggestStops
            || cover.renaming || cover.alwaysExplainer || cover.confirmLeave || cover.confirmEnd
    }
}

/// One mark on the lobby's map.
struct LobbyPin: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A planned stop, numbered as in the stop list (the meeting point doesn't take a number).
        case stop(number: Int)
        case meeting
        case destination
        /// A participant's own join point (D26): theirs only.
        case join
        /// An R&R offered by Add a stop, numbered as its row; the chosen one is highlighted (B6).
        case candidate(number: Int, selected: Bool)
    }
    var id: String
    var kind: Kind
    var name: String
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var isSelectedCandidate: Bool { if case .candidate(_, true) = kind { true } else { false } }
}

/// Where the lobby's camera is asked to go.
enum LobbyMapTarget: Equatable {
    case wholeTrip
    case stop(String)
}

/// A camera request; `serial` makes asking for the same target twice a new request.
struct LobbyMapCommand: Equatable {
    var target: LobbyMapTarget = .wholeTrip
    var serial = 0
    func asking(_ next: LobbyMapTarget) -> LobbyMapCommand { LobbyMapCommand(target: next, serial: serial + 1) }
}

enum LobbyMapLogic {
    /// The pins the map draws: the planned stops in list order (the meeting point as its own pin, the others
    /// numbered 1, 2, … skipping it), the destination, and for a participant their own join point. The organiser has
    /// no join pin, and another car's start or join point is never drawn (#361, D26): there is no way to ask for one.
    static func pins(stops: [StopDraft], destinationName: String?, destination: CLLocationCoordinate2D?,
                     isOrganizer: Bool, ownJoin: CLLocationCoordinate2D?) -> [LobbyPin] {
        var result: [LobbyPin] = []
        var number = 0
        for stop in stops {
            if stop.isMeeting {
                result.append(LobbyPin(id: stop.id, kind: .meeting, name: stop.name,
                                       latitude: stop.latitude, longitude: stop.longitude))
            } else {
                number += 1
                result.append(LobbyPin(id: stop.id, kind: .stop(number: number), name: stop.name,
                                       latitude: stop.latitude, longitude: stop.longitude))
            }
        }
        if let destination {
            result.append(LobbyPin(id: "destination", kind: .destination, name: destinationName ?? "",
                                   latitude: destination.latitude, longitude: destination.longitude))
        }
        if !isOrganizer, let ownJoin {
            result.append(LobbyPin(id: "join", kind: .join, name: "", latitude: ownJoin.latitude, longitude: ownJoin.longitude))
        }
        return result
    }

    /// The fraction of the map's height kept clear at the top: the status bar (`safeTop`, the map's own top safe area:
    /// the lobby has no navigation bar, its header is in the sheet), the round "show the whole trip" button that hangs
    /// under it, and room for the destination flag, which stands about `flagRoom` above its coordinate, so the flag
    /// lands clear of both. The sheet needs none at the bottom: the map's bottom safe area (`LobbySheet.legalInset`)
    /// already sits above the medium sheet, and MapKit fits inside it (`bottomPadding`). Before the map is measured a
    /// typical status bar and phone height stand in.
    static func topFraction(mapHeight: CGFloat, safeTop: CGFloat, bottomPadding: CGFloat = 0) -> Double {
        let bar = (safeTop > 0 ? safeTop : typicalBar) + buttonBand
        // MapKit fits a region inside the map's safe area, so the fractions are of the part above the bottom padding.
        let measured = mapHeight - bottomPadding
        let viewport = measured > 2 * (bar + flagRoom) ? measured : 874 - bottomPadding
        return Double((bar + flagRoom) / viewport)
    }

    /// The status bar before it is measured.
    static let typicalBar: CGFloat = 62
    /// Under the status bar: the gap above the round map button, the button (56 pt) and a margin below it.
    static let buttonBand: CGFloat = Spacing.xs + 56 + Spacing.s
    /// The destination flag: its pin and name above the coordinate, with a margin.
    static let flagRoom: CGFloat = 50
    /// Degrees of latitude shown when the camera flies to one stop.
    static let stopSpan = 0.12

    /// Where the camera goes for `target`: a close view of the stop (nil for a stop that isn't there any more), or the
    /// whole route with its pins, in the part of the map above the sheet. Nil when there is nothing to show yet.
    static func region(for target: LobbyMapTarget, route: [CLLocationCoordinate2D], pins: [LobbyPin],
                       bottomObscured: Double, topObscured: Double) -> MKCoordinateRegion? {
        switch target {
        case .stop(let id):
            guard let pin = pins.first(where: { $0.id == id }) else { return nil }
            return PickedTripLogic.focus(on: pin.coordinate, span: stopSpan,
                                         bottomObscured: bottomObscured, topObscured: topObscured)
        case .wholeTrip:
            let points = route + pins.filter { $0.kind != .join }.map(\.coordinate)
            guard let first = points.first else { return nil }
            let end = pins.first { $0.kind == .destination }?.coordinate ?? points.last ?? first
            let line = PastTripRoute(
                id: "lobby", name: "", destinationName: "", destinationLatitude: end.latitude,
                destinationLongitude: end.longitude, points: points.map { [$0.latitude, $0.longitude] })
            return PastTripsMapLogic.region(fitting: [line], bottomObscured: bottomObscured, topObscured: topObscured)
        }
    }

    /// Whether a new route (it arrived, or a stop changed it) or a new map height refits the whole trip: not once
    /// the person has moved the camera, nor while it is on a stop they asked for.
    static func shouldRefit(positionedByUser: Bool, onStop: Bool) -> Bool { !positionedByUser && !onStop }
}

/// The full-screen map behind the lobby's sheet: the route, the planned stops, the destination and your own position.
struct LobbyMapView: View {
    var route: [CLLocationCoordinate2D]
    var pins: [LobbyPin]
    /// A participant's own way in, in their car's colour.
    var ownRoute: [CLLocationCoordinate2D] = []
    var ownColorHex: String = "#0A7CFF"
    var sheetCompact: CGFloat
    /// A tap on a candidate R&R's pin (its id).
    var onCandidateTap: (String) -> Void = { _ in }
    @Binding var command: LobbyMapCommand

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera: MapCameraPosition = .automatic
    @State private var mapHeight: CGFloat = 0
    /// The map's top safe area: the status bar (the lobby has no navigation bar).
    @State private var safeTop: CGFloat = 0
    @State private var onStop = false
    @State private var fitted = false

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            if route.count > 1 {
                MapPolyline(coordinates: route)
                    .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: route)
                    .stroke(Color.ikutAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if ownRoute.count > 1 {
                MapPolyline(coordinates: ownRoute)
                    .stroke(Color.car(hex: ownColorHex), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            // The chosen R&R is drawn last, so it is on top.
            ForEach(pins.sorted { !$0.isSelectedCandidate && $1.isSelectedCandidate }) { pin in
                Annotation("", coordinate: pin.coordinate, anchor: .bottom) {
                    LobbyPinView(pin: pin, colorHex: ownColorHex)
                        .onTapGesture { if case .candidate = pin.kind { onCandidateTap(pin.id) } }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        // The logo and Legal ride above the medium sheet from the first frame, and stay when it is pulled up.
        .safeAreaPadding(.bottom, LobbySheet.legalInset(compact: sheetCompact))
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            guard height != mapHeight else { return }
            mapHeight = height
            refitIfOurs(animated: false)
        }
        .onChange(of: route.count, initial: true) { _, _ in refitIfOurs(animated: fitted) }
        .onChange(of: pins) { _, _ in refitIfOurs(animated: fitted) }
        .onChange(of: command) { _, new in go(new.target, animated: true) }
        .overlay(alignment: .topTrailing) {
            Button { command = command.asking(.wholeTrip) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .roundGlass()
            .padding(.trailing, Spacing.m)
            .padding(.top, safeTop + Spacing.xs)
            .accessibilityLabel("Show the whole trip")
            .accessibilityIdentifier("lobby.wholeTrip")
        }
        // Measured here, outside the map's ignoresSafeArea (inside it the insets read zero): the top safe area is the
        // status bar, as the layout has it.
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { top in
            guard top != safeTop else { return }
            safeTop = top
            refitIfOurs(animated: false)
        }
    }

    private func refitIfOurs(animated: Bool) {
        guard LobbyMapLogic.shouldRefit(positionedByUser: camera.positionedByUser, onStop: onStop) else { return }
        go(.wholeTrip, animated: animated)
    }

    private func go(_ target: LobbyMapTarget, animated: Bool) {
        guard let region = LobbyMapLogic.region(for: target, route: route, pins: pins, bottomObscured: 0,
                                                topObscured: LobbyMapLogic.topFraction(mapHeight: mapHeight, safeTop: safeTop,
                                                                          bottomPadding: LobbySheet.legalInset(compact: sheetCompact))) else { return }
        onStop = target != .wholeTrip
        fitted = true
        let position = MapCameraPosition.region(region)
        if animated, let motion = Motion.camera(reduceMotion: reduceMotion) {
            withAnimation(motion) { camera = position }
        } else {
            camera = position
        }
    }
}

/// A teardrop pin as in the canvas: numbered for a stop, a symbol for the meeting point, a flag for the destination,
/// a dot in the car's colour for a participant's own join point; the name under it.
struct LobbyPinView: View {
    var pin: LobbyPin
    var colorHex: String

    private var fill: Color {
        switch pin.kind {
        case .stop: Color.ikutAccent
        case .meeting: PlannedStopKind.meet.tint
        case .destination: Color(red: 0.11, green: 0.11, blue: 0.12)
        case .join: Color.car(hex: colorHex)
        // Grey until chosen, then the accent and a little larger with a halo, as in B6.
        case .candidate(_, let selected): selected ? Color.ikutAccent : Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }

    /// The pin's side: the chosen R&R is 36 pt, every other 28.
    private var side: CGFloat { pin.isSelectedCandidate ? 36 : 28 }

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 3, bottomTrailingRadius: 14, topTrailingRadius: 14,
                               style: .continuous)
            .fill(fill)
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 3, bottomTrailingRadius: 14,
                                            topTrailingRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 2.5))
            .frame(width: side, height: side)
            .background { if pin.isSelectedCandidate { Circle().fill(Color.ikutAccent.opacity(0.2)).frame(width: side + 16, height: side + 16) } }
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .rotationEffect(.degrees(-45))
            .overlay { glyph }
            .overlay(alignment: .top) {
                if !pin.name.isEmpty, pin.kind != .join, labelled {
                    Text(pin.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.12))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()
                        .offset(y: 32)
                }
            }
            // The tip, not the middle, sits on the coordinate.
            .offset(y: -6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    /// Every pin carries its name except a candidate R&R that isn't chosen (the numbers say which it is).
    private var labelled: Bool {
        if case .candidate(_, let selected) = pin.kind { return selected }
        return true
    }

    @ViewBuilder private var glyph: some View {
        switch pin.kind {
        case .stop(let number), .candidate(let number, _):
            Text("\(number)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
        case .meeting:
            Image(systemName: PlannedStopKind.meet.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
        case .destination:
            Image(systemName: "flag.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
        case .join:
            Circle().fill(.white).frame(width: 8, height: 8)
        }
    }

    private var label: String {
        switch pin.kind {
        case .stop(let number): "Stop \(number), \(pin.name)"
        case .meeting: "Meeting point, \(pin.name)"
        case .destination: "Destination, \(pin.name)"
        case .join: "Where you join"
        case .candidate(let number, let selected): "R&R \(number), \(pin.name)\(selected ? ", chosen" : "")"
        }
    }
}
