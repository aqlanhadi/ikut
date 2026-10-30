import Foundation

/// Every SF Symbol name the app uses, by meaning. Values are system symbol names; SymbolTests checks each exists and none repeat.
enum Symbol {
    // MARK: Controls and navigation
    static let close = "xmark"
    static let closeCircle = "xmark.circle.fill"
    static let back = "chevron.left"
    static let backTrailing = "chevron.backward"
    static let forward = "chevron.right"
    static let expandUp = "chevron.up"
    static let next = "arrow.right"
    static let tick = "checkmark"
    static let tickCircle = "checkmark.circle"
    static let share = "square.and.arrow.up"
    static let copy = "doc.on.doc"
    static let search = "magnifyingglass"
    static let add = "plus"
    static let remove = "minus"
    static let delete = "trash"
    static let retry = "arrow.clockwise"
    static let reorder = "line.3.horizontal"
    static let info = "info.circle"
    static let suggest = "sparkles"
    static let wholeTrip = "arrow.up.left.and.arrow.down.right"
    static let fitConvoy = "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
    static let turnRight = "arrow.turn.up.right"
    static let routeStart = "arrow.triangle.turn.up.right.diamond.fill"
    static let dot = "circle.fill"

    // MARK: Location, sharing and codes
    static let location = "location.fill"
    static let locationOff = "location.slash.fill"
    static let phoneOff = "iphone.gen3.slash"
    static let offline = "antenna.radiowaves.left.and.right.slash"
    static let qrCode = "qrcode"
    static let scanCode = "qrcode.viewfinder"
    static let pause = "pause.fill"
    static let play = "play.fill"
    static let paused = "pause.circle.fill"
    static let pauseAnytime = "pause.circle"
    static let convoyMembers = "person.2"
    static let removedFromTrip = "person.fill.xmark"
    static let leaveTrip = "rectangle.portrait.and.arrow.right"
    static let soundOn = "speaker.wave.2.fill"
    static let soundOff = "speaker.slash.fill"
    static let duringTrip = "clock"
    static let time = "clock.fill"
    static let steering = "steeringwheel"

    // MARK: Map, places and stops
    static let pin = "mappin"
    static let pinCircle = "mappin.circle.fill"
    static let pinAndRing = "mappin.and.ellipse"
    static let map = "map"
    static let mapFilled = "map.fill"
    static let finish = "flag.checkered"
    static let flag = "flag.fill"
    static let fuel = "fuelpump.fill"
    static let fuelPlain = "fuelpump"
    static let food = "fork.knife"
    static let rest = "cup.and.saucer.fill"
    static let toilet = "toilet.fill"
    static let sight = "mountain.2.fill"
    static let transit = "tram.fill"
    static let parking = "parkingsign"

    // MARK: Cars, hazards and messages
    static let car = "car.fill"
    static let cars = "car.2.fill"
    static let warning = "exclamationmark.triangle.fill"
    static let warningOutline = "exclamationmark.triangle"
    static let accident = "exclamationmark.octagon.fill"
    static let pothole = "circle.bottomhalf.filled"
    static let animal = "pawprint.fill"
    static let roadworks = "cone.fill"
    static let rain = "cloud.rain.fill"
    static let heavyRain = "cloud.heavyrain.fill"
    static let carTrouble = "wrench.and.screwdriver.fill"
    static let message = "text.bubble.fill"

    // MARK: Recap awards
    static let awardLead = "bolt.fill"
    static let awardReporter = "eye.fill"
    static let awardSweeper = "shield.fill"
    static let awardDefault = "star.fill"

    /// Every name above, for the test.
    static let all: [String] = [
        close,
        closeCircle,
        back,
        backTrailing,
        forward,
        expandUp,
        next,
        tick,
        tickCircle,
        share,
        copy,
        search,
        add,
        remove,
        delete,
        retry,
        reorder,
        info,
        suggest,
        wholeTrip,
        fitConvoy,
        turnRight,
        routeStart,
        dot,
        location,
        locationOff,
        phoneOff,
        offline,
        qrCode,
        scanCode,
        pause,
        play,
        paused,
        pauseAnytime,
        convoyMembers,
        removedFromTrip,
        leaveTrip,
        soundOn,
        soundOff,
        duringTrip,
        time,
        steering,
        pin,
        pinCircle,
        pinAndRing,
        map,
        mapFilled,
        finish,
        flag,
        fuel,
        fuelPlain,
        food,
        rest,
        toilet,
        sight,
        transit,
        parking,
        car,
        cars,
        warning,
        warningOutline,
        accident,
        pothole,
        animal,
        roadworks,
        rain,
        heavyRain,
        carTrouble,
        message,
        awardLead,
        awardReporter,
        awardSweeper,
        awardDefault,
    ]
}
