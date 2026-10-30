// Accessibility identifiers the UI tests (ikutUITests) and the qa runners find controls by. The VALUES are a contract:
// change one only together with those tests and scripts. App code uses these constants, never the literals.
// `AXIDTests` checks every identifier the UI tests look up is a value here and that no two share a value.

enum AXID {
    enum AddStop {
        static let add = "addStop.add"
        static let back = "addStop.back"
        static let longer = "addStop.longer"
        static let none = "addStop.none"
        static let search = "addStop.search"
        static let shorter = "addStop.shorter"
        static let stay = "addStop.stay"
        static func rnr(_ number: Int) -> String { "addStop.rnr.\(number)" }
        static func kind(_ raw: String) -> String { "addStop.kind.\(raw)" }
    }
    enum Alerts {
        static let catchupPill = "catchup.pill"
        static let routeNotice = "route.notice"
        static let stopApproachPill = "stopapproach.pill"
    }
    enum Convoy {
        static let header = "convoy.header"
        static let report = "convoy.report"
        static let rowArrived = "convoy.row.arrived"
        static let separation = "convoy.separation"
        static let summary = "convoy.summary"
        static func row(_ id: String) -> String { "convoy.row.\(id)" }
        static func joiningRow(_ id: String) -> String { "joining.row.\(id)" }
    }
    enum Debug {
        static let designDrillViews = "designDrill.views"
        static let designLanguage = "designLanguage"
        static let settingsDesign = "settingsDesign"
        static let settingsName = "settingsName"
        static func sizes(_ name: String) -> String { "sizes.\(name)" }
        static func sizesCaption(_ name: String) -> String { "sizes.\(name).caption" }
        static func designDrill(_ raw: String) -> String { "designDrill.\(raw)" }
    }
    enum Home {
        static let join = "homeJoin"
        static let pickedLeft = "picked.left"
        static let whereTo = "homeWhereTo"
    }
    enum Join {
        static let back = "joinBack"
        static let carNameField = "joinCarNameField"
        static let codeField = "joinCodeField"
        static let confirm = "joinConfirm"
        static let continueStep = "joinContinue"
        static let error = "joinError"
        static let locationContinue = "joinLocationContinue"
        static let locationOff = "joinLocationOff"
        static let locationSkip = "joinLocationSkip"
        static let nameContinue = "joinNameContinue"
        static let scan = "joinScan"
        static let share = "joinShare"
        static let shareNote = "joinShareNote"
        static let step = "joinStep"
        static let tripCard = "joinTripCard"
    }
    enum Lobby {
        static let back = "lobby.back"
        static let copyCode = "lobby.copyCode"
        static let destination = "lobby.destination"
        static let endTrip = "lobby.endTrip"
        static let keepAwake = "lobby.keepAwake"
        static let leaveTrip = "lobby.leaveTrip"
        static let pause = "lobby.pause"
        static let rename = "lobby.rename"
        static let resume = "lobby.resume"
        static let share = "lobby.share"
        static let showQR = "lobby.showQR"
        static let subtitle = "lobby.subtitle"
        static let waiting = "lobbyWaiting"
        static let waitingForCars = "lobby.waitingForCars"
        static let wholeTrip = "lobby.wholeTrip"
        static func car(_ number: Int) -> String { "lobby.car.\(number)" }
    }
    enum Map {
        static let cameraTourCaption = "cameraTour.caption"
        static let error = "map.error"
        static let errorClose = "map.error.close"
        static let hazardMarker = "hazard.marker"
    }
    enum Name {
        static let error = "nameError"
        static let field = "nameField"
    }
    enum Recap {
        static let root = "recap"
    }
    enum Report {
        static let card = "report.card"
    }
    enum Sheet {
        static let close = "sheet.close"
    }
    enum Stop {
        static let addMessage = "stop.addMessage"
        static let arrival = "stop.arrival"
        static let arrivalCount = "stop.arrival.count"
        static let arrivalLeavingAt = "stop.arrival.leavingAt"
        static let arrivalSkipping = "stop.arrival.skipping"
        static let arrivalYou = "stop.arrival.you"
        static let back = "stop.back"
        static let badge = "stop.badge"
        static let button = "stop.button"
        static let card = "stop.card"
        static let cardClose = "stop.card.close"
        static let driving = "stop.driving"
        static let leave = "stop.leave"
        static let leaveCancel = "stop.leave.cancel"
        static let leaveConfirm = "stop.leave.confirm"
        static let leaveConfirmText = "stop.leave.confirm.text"
        static let leaveQueued = "stop.leave.queued"
        static let leaveRetry = "stop.leave.retry"
        static let leaveWaiting = "stop.leave.waiting"
        static let message = "stop.message"
        static let messageClear = "stop.messageClear"
        static let messageDone = "stop.messageDone"
        static let messageField = "stop.messageField"
        static let passenger = "stop.passenger"
        static let passengerCheck = "stop.passengerCheck"
        static let pill = "stop.pill"
        static let pillAsked = "stop.pill.asked"
        static let pillButton = "stop.pill.button"
        static let pillConfirm = "stop.pill.confirm"
        static let pillText = "stop.pill.text"
        static let placesCredit = "stop.places.credit"
        static let send = "stop.send"
        static let skip = "stop.skip"
        static let skipAll = "stop.skipAll"
        static let skipAllCancel = "stop.skipAll.cancel"
        static let skipAllConfirm = "stop.skipAll.confirm"
        static let skipAllConfirmText = "stop.skipAll.confirm.text"
        static let skipAllOthers = "stop.skipAll.others"
        static let skipAllQueued = "stop.skipAll.queued"
        static let skipAllRetry = "stop.skipAll.retry"
        static let skipQueued = "stop.skip.queued"
        static let skipRetry = "stop.skip.retry"
        static let skipUndo = "stop.skip.undo"
        static func place(_ id: String) -> String { "stop.place.\(id)" }
        static func voter(_ id: String) -> String { "stop.voter.\(id)" }
        static func reason(_ type: String) -> String { "stop.reason.\(type)" }
        static func ok(_ suffix: String) -> String { "stop.ok\(suffix)" }
        static func stopped(_ suffix: String) -> String { "stop.stopped\(suffix)" }
        static func cancel(_ suffix: String) -> String { "stop.cancel\(suffix)" }
        static func request(_ suffix: String) -> String { "stop.request\(suffix)" }
    }
    enum Stops {
        static let add = "stops.add"
        static let retry = "stops.retry"
        static let suggest = "stops.suggest"
    }
    enum Suggest {
        static let add = "suggest.add"
        static let after = "suggest.after"
        static let earlier = "suggest.earlier"
        static let later = "suggest.later"
        static let note = "suggest.note"
    }
    enum Trip {
        static let createError = "createTripError"
        static let destinationField = "destinationField"
        static let drivingSheet = "driving.sheet"
        static let journeyBehind = "trip.journey.behind"
        static let mapPickLabel = "mapPick.label"
        static let newTripNameField = "newTripNameField"
        static let pillErrorDot = "trip.pill.errorDot"
        static let pillStatus = "trip.pill.status"
        static let pulledUp = "trip.pulledUp"
        static let renameNameField = "renameNameField"
        static let renameTripField = "renameTripField"
        static func stat(_ caption: String) -> String { "stat.\(caption)" }
    }
    enum Welcome {
        static let join = "welcomeJoin"
    }

    /// Every fixed identifier above (the dynamic ones are functions), for the tests.
    static let all: [String] = [
        AddStop.add,
        AddStop.back,
        AddStop.longer,
        AddStop.none,
        AddStop.search,
        AddStop.shorter,
        AddStop.stay,
        Alerts.catchupPill,
        Alerts.routeNotice,
        Alerts.stopApproachPill,
        Convoy.header,
        Convoy.report,
        Convoy.rowArrived,
        Convoy.separation,
        Convoy.summary,
        Debug.designDrillViews,
        Debug.designLanguage,
        Debug.settingsDesign,
        Debug.settingsName,
        Home.join,
        Home.pickedLeft,
        Home.whereTo,
        Join.back,
        Join.carNameField,
        Join.codeField,
        Join.confirm,
        Join.continueStep,
        Join.error,
        Join.locationContinue,
        Join.locationOff,
        Join.locationSkip,
        Join.nameContinue,
        Join.scan,
        Join.share,
        Join.shareNote,
        Join.step,
        Join.tripCard,
        Lobby.back,
        Lobby.copyCode,
        Lobby.destination,
        Lobby.endTrip,
        Lobby.keepAwake,
        Lobby.leaveTrip,
        Lobby.pause,
        Lobby.rename,
        Lobby.resume,
        Lobby.share,
        Lobby.showQR,
        Lobby.subtitle,
        Lobby.waiting,
        Lobby.waitingForCars,
        Lobby.wholeTrip,
        Map.cameraTourCaption,
        Map.error,
        Map.errorClose,
        Map.hazardMarker,
        Name.error,
        Name.field,
        Recap.root,
        Report.card,
        Sheet.close,
        Stop.addMessage,
        Stop.arrival,
        Stop.arrivalCount,
        Stop.arrivalLeavingAt,
        Stop.arrivalSkipping,
        Stop.arrivalYou,
        Stop.back,
        Stop.badge,
        Stop.button,
        Stop.card,
        Stop.cardClose,
        Stop.driving,
        Stop.leave,
        Stop.leaveCancel,
        Stop.leaveConfirm,
        Stop.leaveConfirmText,
        Stop.leaveQueued,
        Stop.leaveRetry,
        Stop.leaveWaiting,
        Stop.message,
        Stop.messageClear,
        Stop.messageDone,
        Stop.messageField,
        Stop.passenger,
        Stop.passengerCheck,
        Stop.pill,
        Stop.pillAsked,
        Stop.pillButton,
        Stop.pillConfirm,
        Stop.pillText,
        Stop.placesCredit,
        Stop.send,
        Stop.skip,
        Stop.skipAll,
        Stop.skipAllCancel,
        Stop.skipAllConfirm,
        Stop.skipAllConfirmText,
        Stop.skipAllOthers,
        Stop.skipAllQueued,
        Stop.skipAllRetry,
        Stop.skipQueued,
        Stop.skipRetry,
        Stop.skipUndo,
        Stops.add,
        Stops.retry,
        Stops.suggest,
        Suggest.add,
        Suggest.after,
        Suggest.earlier,
        Suggest.later,
        Suggest.note,
        Trip.createError,
        Trip.destinationField,
        Trip.drivingSheet,
        Trip.journeyBehind,
        Trip.mapPickLabel,
        Trip.newTripNameField,
        Trip.pillErrorDot,
        Trip.pillStatus,
        Trip.pulledUp,
        Trip.renameNameField,
        Trip.renameTripField,
        Welcome.join,
    ]

    /// The dynamic identifiers with an empty suffix (what the UI tests look up for the single-request card).
    static let suffixless: [String] = [Stop.ok(""), Stop.stopped(""), Stop.cancel(""), Stop.request("")]

    /// Prefixes of the per-row identifiers (the car, row, place or reason is appended).
    static let dynamicPrefixes: [String] = [
        "stat.", "lobby.car.", "convoy.row.", "joining.row.", "addStop.rnr.", "addStop.kind.", "stop.place.", "stop.voter.",
        "stop.reason.", "stop.request.", "stop.ok.", "stop.stopped.", "stop.cancel.", "sizes.", "designDrill.",
    ]
}
