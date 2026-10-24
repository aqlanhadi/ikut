import Foundation

/// What the convoy panel's header says about the viewer's own trip (D26): where they start, and, while their car
/// is still joining, where and how far. Pure words; the panel looks up the town names.
enum ConvoyHeader {
    struct Text: Equatable {
        /// The big start town.
        var from: String
        /// Replaces "Left 12:11" while the car is joining; nil in the convoy.
        var joinLine: String?
        /// The joining part of the VoiceOver label: "joining near Rawang, 14 km away"; nil in the convoy.
        var spokenJoin: String?
    }

    /// The start town: the viewer's own (the car's route has one), "Your start" while nothing is known, else the
    /// main route's start (a car on the main route leaves from there).
    static func from(car: Car?, ownStartTown: String?, mainStartTown: String?) -> String {
        if let route = car?.route, !route.isEmpty { return ownStartTown ?? "Your start" }
        if car != nil, car?.mergeOffset == nil { return "Your start" }
        return mainStartTown ?? "Start"
    }

    /// The joining line for a car that is joining; nil once it is in the convoy, on the main route, or unknown.
    /// `amount` is nil without an estimate, and the line then stops at the place.
    static func joining(
        _ join: OwnWayJoin?, place: String?, destination: String, amount: ConvoyFormat.JoinAmount?
    ) -> (line: String, spoken: String)? {
        switch join {
        case .merges:
            let name = place.map { "Joining near \($0)" } ?? "Joining the convoy"
            guard let amount else { return (name, name.lowercasedFirst) }
            return ("\(name) · \(amount.text)", "\(name.lowercasedFirst), \(amount.spoken) away")
        case .meetsAtDestination:
            let name = "Meets the convoy in \(destination)"
            guard let amount else { return (name, name.lowercasedFirst) }
            return ("\(name) · \(amount.text)", "\(name.lowercasedFirst), \(amount.spoken) away")
        case .startsWithConvoy, .onRoute, nil:
            return nil
        }
    }

    static func text(
        car: Car?, joinEntry: JoiningEntry?, join: OwnWayJoin?, ownStartTown: String?, mainStartTown: String?,
        joinPlace: String?, destination: String, amount: ConvoyFormat.JoinAmount?
    ) -> Text {
        let from = from(car: car, ownStartTown: ownStartTown, mainStartTown: mainStartTown)
        // Only a car that is still joining says so; once it is in the convoy "Left 12:11" returns.
        guard joinEntry != nil, let j = joining(join, place: joinPlace, destination: destination, amount: amount) else {
            return Text(from: from, joinLine: nil, spokenJoin: nil)
        }
        return Text(from: from, joinLine: j.line, spokenJoin: j.spoken)
    }

    /// Starts with "3 in convoy" (UI tests read it).
    static func label(title: String, text: Text, destination: String, arrive: String?) -> String {
        var parts = [title, "from \(text.from)"]
        if let spoken = text.spokenJoin { parts.append(spoken) }
        // "meets the convoy in Ipoh, 160 km away" already names the destination.
        if !(text.spokenJoin?.hasPrefix("meets the convoy in") ?? false) { parts.append("to \(destination)") }
        if let arrive { parts.append("arrive \(arrive)") }
        // "from Shah Alam to Ipoh" reads as one phrase when nothing sits between.
        return parts.enumerated().reduce(into: "") { out, item in
            let (i, part) = item
            if i == 0 { out = part } else if part.hasPrefix("to "), text.spokenJoin == nil { out += " \(part)" } else { out += ", \(part)" }
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
