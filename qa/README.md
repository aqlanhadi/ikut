# qa: simulated multi-car drives

Repeatable drives that push the whole data flow (rules, callables, positions, events, stops, the convoy panel,
approach alerts) before a real drive. Everything runs against the Firebase emulators (project `ikut-b1083`);
start them first (`cd firebase && firebase emulators:start`). Node 20+.

```sh
cd qa && npm install
node convoy-sim.mjs                  # 4 simulated cars, real time, prints TRIP CODE: XXXXXX, PASS/FAIL per check
node convoy-sim.mjs --speed 2        # 2x (the signal-drop check needs <= 2.5x, see below)
node run-ui.mjs --speed 1            # everything, with the app on simulator C0A40D2A (iPhone 17) as the fifth car
```

`run-ui.mjs` boots the simulator, grants location, starts `convoy-sim.mjs --wait-app`, runs
`ConvoyScenarioUITests` (`ios/ikutUITests`) with `TEST_RUNNER_IKUT_JOIN_CODE`, and feeds
`gpx/car5-app.gpx` to the simulator with `xcrun simctl location start`. Options: `--speed N`, `--skip-build`,
`--udid`, `--derived-data` (default `/tmp/ikut-dd-q1`, seed it from another derived-data folder's `SourcePackages`).
Screenshots land in `qa/screens/`, logs in `$TMPDIR/ikut-qa/`.

To join by hand instead: `node convoy-sim.mjs --wait-app`, join with the printed code from any simulator or phone, and
feed it the track with `xcrun simctl location <udid> start --speed=27.4 ...` (see `run-ui.mjs`).
`node convoy-sim.mjs --help` lists the other flags.

## Drive one trip by hand

`node drive-trip.mjs [CODE]` plays a trip's main route on the simulator (the newest active trip in the emulators if no code
is given), so you can create a trip in the app, tap Start Trip and watch yourself drive to the destination. `--kmh 100`,
`--speed 20` (time multiplier), `--from 30` (start 30 km along). Set the simulator's location first
(`xcrun simctl location C0A40D2A-0607-4B95-A1BE-F8C9190D81C1 set 3.139,101.687`), since Where to? builds the route from it.

On a real iPhone: `node drive-trip.mjs CODE --gpx trip.gpx` writes a timed GPX. Run the app from Xcode on the phone, then
Debug > Simulate Location > Add GPX File to Workspace... and pick it. For a production trip, pass the route with
`--route <encoded polyline>` instead of a code.

`ConvoyScenarioUITests`' sibling `CreateTripUITests` walks name, New Trip, Where to?, lobby and Start Trip;
`TEST_RUNNER_IKUT_HOLD_SECONDS=420` leaves it on the map for a drive.

## Two-phone convoy

```sh
node run-convoy2.mjs                 # builds, then about 4-5 minutes of test; RESULT: PASS / FAIL
node run-convoy2.mjs --skip-build    # reuse /tmp/ikut-dd-convoy2
node run-convoy2.mjs --ask-location  # phone B starts without location permission and answers the system prompt
```

Two real app instances plus two scripted cars. Phone A (organizer, car 1) is the shared iPhone 17 (`C0A40D2A`), phone B
(car 2) a second simulator, `ikut-convoy-2` (iPhone 17 Pro, iOS 27.0, created on first use if missing). The script boots
both, grants location, parks them at the start of the E1 just south of Bidor, builds once, then runs
`ConvoyOrganizerUITests` on A and `ConvoyJoinerUITests` on B (`ios/ikutUITests/TwoPhoneConvoyUITests.swift`) at the same
time. Cars 3 (Hafiz) and 4 (Daniel) are Firebase clients in the script: joinTrip, the app's position pipeline, a hazard
report and stop votes. The three take turns through marker files in `$TMPDIR/ikut-qa/convoy2-sync` (`a.code`, `b.lobby`,
`cars.joined`, `go`, ...); any failure writes `abort` there and every side stops waiting.

What it checks, in order (each phone step prints `QA CHECK: PASS|FAIL`, the script checks Firestore alongside):

1. A creates the trip in the UI (name, New Trip, Where to? Ipoh, lobby) and reads the code off the lobby.
2. B joins with the code as a new car; the script joins cars 3 and 4; both lobbies read "4 of 4 ready"; numbers 1, 2, 3, 4.
3. Both tap Start Trip. All four drive the trip's route at 90 km/h (simctl playback for the phones, resynced every 20 s)
   from 3.0 km (A), 2.2 km (3), 1.4 km (B) and 0.6 km (4): convoy panel order 1, 3, 2, 4 on both phones and in Firestore.
4. A reports Debris from the Report sheet; B sees the marker and gets the approach alert (the pill, the map framing B and the debris, the debris pinging). Car 3 then reports an
   accident: the marker shows on both phones, B (behind it) is alerted, A (ahead) is not.
5. B taps Pit stop, Fuel; the request sends itself. A sees the card and agrees, cars 3 and 4 vote (car 3 suggests a place if
   B's phone found none), A pins it, B's card shows it pinned, A taps Everyone has arrived and both cards go.
6. B goes back to the lobby and pauses sharing: A's row 2 reads "Paused", `pausedAt` is set; Resume clears both.
7. B leaves the trip: its car disappears from A's list (memberCleanup deletes it). B rejoins as car 5, A ends the trip from
   the map menu and lands on Home, B's lobby says "Trip ended", the trip doc is `ended`.

Screenshots: `qa/screens/convoy2/A-*.png`, `B-*.png`. Logs: `$TMPDIR/ikut-qa/convoy2-A.log`, `convoy2-B.log` (and the
`.xcresult` bundles next to them). To watch, open Xcode > Window > Devices and Simulators (or the Simulator app with both
devices shown) while it runs. The script waits while another run on the shared simulator (`/tmp/ikut-dd-map`) is going.

Not covered: the hazard marker clearing after everyone passes and the signal-drop/stale case (both in `run-ui.mjs`);
the drive is short, so nobody reaches the destination. xcodebuild on the second simulator sometimes doesn't exit after
its suite finishes; the script takes the suite's result and kills it after 60 s.

## Layout

| Path | What |
| --- | --- |
| `generate-gpx.mjs` | Writes `gpx/*.gpx` (deterministic). `--fetch` refreshes `data/osrm-*.json` from the public OSRM server. |
| `data/osrm-main.json`, `osrm-car4.json` | Snapshots of the real E1 geometry: main route (just south of Bidor to Ipoh, 65 km) and car 4's own route (Tapah town to Ipoh). |
| `gpx/car1..car4.gpx`, `car5-app.gpx` | The tracks, 1 Hz, 900 s. `route-*.gpx` are reference polylines. |
| `convoy-sim.mjs` | The scenario driver. |
| `lib/route.mjs`, `lib/tracking.mjs` | JS ports of the Swift logic, each function annotated with its source file. |
| `lib/scenario.mjs` | The script: cars, speeds, gap, timeline. |
| `run-ui.mjs` | One-command orchestrator with the app in the loop. |
| `run-convoy2.mjs` | Two simulators (organizer and joiner) plus two scripted cars, see Two-phone convoy. |

## The drive

Route: the North-South Expressway from just south of Bidor to Ipoh. Cars 1-3 start 5.0, 4.2 and 2.9 km along it at 100, 99.7 and 99 km/h
(spacing stays 800-1500 m). Car 4 sits at a Tapah town petrol station (off route), drives its own road and joins at the Tapah ramp
(14.7 km along the main route). The phone (car 5) starts 1.9 km along, at 98.6 km/h.

| T (s) | Event |
| --- | --- |
| 0 | Go. Order 1 > 2 > 3 > phone; car 4 under JOINING (stationary, own route and `mergeOffset` already written). |
| 200-380 | Car 2 loses signal (3 minute gap in `car2.gpx`). Played as a network drop, see below. |
| about 262 | Car 2 is stale: "Last seen 1 min ago", and the others overtake its frozen position. |
| 380 | Car 2 reconnects. |
| 408 | Car 4 reaches its merge point: car doc `state: convoy`, `convoyOffset` appears, JOINING empties. Order 1 > 2 > 4 > 3 > phone. |
| 520 | Car 1 reports debris. Cars behind get an approach alert 500 m before it (car 2 at T=536, car 4 at 568, car 3 at 587, phone about 625). Marker disappears once everyone has passed (phone about 645). |
| 700 | Car 3 requests a fuel stop and proposes a place (agreeing vote with `suggestion`). |
| 715 | Car 1 (lead) pins the place. 730, 735: cars 2 and 4 agree. The UI test makes the phone agree. |
| 800 | Car 1 resolves the stop. Drive ends at 900. |

## What is checked

`convoy-sim.mjs` (PASS/FAIL lines, exit code 1 on any FAIL):

- rules: another car's position, heading 360 and a client timestamp are all rejected
- positions are fresh and on the GPX; car 4 has no `convoyOffset`; its doc is `joining` with `route` and `mergeOffset` (14666 m); cars 2/3 became `convoy` through ensureRoute
- convoy order read back from Firestore equals the order expected from the GPX at T=60, during the drop, after the merge, at T=560
- signal drop: car 2 is older than 60 s while offline, fresh and back at its true position after reconnect
- car 4 merge: state `convoy`, `convoyOffset` present, merged at the scripted time
- hazard: stored with the app's field set and 45 minute expiry; reaches each car's listener within 5 s; ApproachCore (ported) fires exactly once per car behind, at about 500 m, at the time predicted from the GPX; not for the author
- stop: event open with pinned place, three votes (requester's with `suggestion`), resolved by the lead
- phone: has a position with `convoyOffset`, its car doc is `convoy` with a tracker, and it voted (with `--expect-app-vote`, which `run-ui.mjs` passes)

`ConvoyScenarioUITests` (the panel as a person sees it, ids `convoy.row.N`, `joining.row.N`, `convoy.header`,
`convoy.joining.header`, `hazard.marker`):

1. before the drive: rows 1, 2, 3, 5 in that order, car 4 under JOINING, "4 in Convoy"
2. car 2 row says "Last seen"; cars 1 and 3 do not; car 2 drops below car 3
3. car 2 recovers
4. JOINING header disappears; order 1, 2, 4, 3, 5; "5 in Convoy"
5. hazard marker "Hazard: Debris ..." is on the map
6. approach banner "Debris ahead in ... meters"
7. hazard marker clears
8. stop card shows the pinned place; tapping Agree to Stop is recorded; the card goes when resolved

## Things to know

- **Staleness is server time.** `updatedAt` is a server timestamp, so at `--speed` above about 2.5 the 60 s stale threshold is never reached in a 3 minute
  (scenario time) gap; the sim then SKIPs that check. Use 1x for the real thing.
- **Why a gap means a network drop.** A GPS-only gap does not make a car stale: `PositionPublisher` re-writes the last position every 10 s
  (30 s when still), so a car in a tunnel looks fresh at a frozen spot. What makes a phone stale is a dead network, where the one in-flight write
  hangs. The sim does that for real (`disableNetwork` on car 2's client between the last fix before the gap and the first after) and runs the same
  one-write-in-flight publisher, so on reconnect one old position lands with a fresh timestamp, then the newest.
- **simctl playback drifts.** `xcrun simctl location start` on its own lagged the scenario clock and once stopped delivering fixes for minutes. `run-ui.mjs`
  restarts it every 20 s from the point the GPX says the car should be at.
- Not covered: off-route rerouting (the tracks stay on their roads; `OffRouteDetector` is not ported), background tracking, push, real MapKit ETAs
  (the app asks MapKit; the sim never does).
- Emulator data is not wiped; each run leaves an active trip behind (`--end-trip` ends it).

## Bugs this found

1. **Crash on opening the map as tracker**: `CLMonitor` names with dots threw. Fixed in `0fd1e3a`.
2. **Stop button icon missing** on iOS 27 (`minus.octagon.fill`): now `octagon.fill`.
3. **Alert banner hidden behind the stop card**: fixed in `15f5cdc`.
4. **First-run Join/New Trip went back to Home after Allow** (two-phone run): on iOS 27 the location prompt doesn't always
   make the app resign active, so `LocationPermission` gave up after 1 s with the status still undetermined. It now keeps
   waiting for the answer while the status is undetermined.
5. Open question: a GPS-only gap never makes a car stale (the heartbeat re-writes the last position),
   see Things to know. Probably intended; worth a decision.

## Battery watch (real drives)

`node battery-watch.mjs <TRIP CODE>` records a real tracker phone's battery and position writes
during a drive (L5, Q2). It joins the trip as a passenger named "Battery watch" in the tracked car
(add `--car "<name>"` when more than one car is tracked), writes every update to
`qa/battery/<CODE>-<time>.csv`, and flags silences over 60 s as they happen. Ctrl-C or ending the
trip prints the drain per hour and the gaps.

It reads from Firebase, not the phone, so the phone can be anywhere with signal. The Mac must stay
awake and online; the script runs `caffeinate`, but a closed lid on battery still sleeps the Mac.
A gap means no signal or a suspended app; the two look the same from here.

## Production smoke test

`node prod-smoke.mjs` runs one short trip against the real Firebase project (from
`ios/ikut/Resources/GoogleService-Info.plist`): anonymous sign-in, create, `previewTrip`, `joinTrip`,
positions, end. It deletes its two anonymous users; the ended trip is purged by `purgeTripDataJob`.

## Live demo

`node demo.mjs` is a ten-minute, real-time (1x) show for people watching two simulators: the shared iPhone 17 (Faiz,
`JoinAsSecondMemberUITests`) and `ikut-convoy-2` (Daniel, `DemoSecondPhoneUITests`). The script creates a trip as a
scripted organizer, prints the code, and joins both phones through UI tests that hold the map open
(`TEST_RUNNER_IKUT_HOLD_SECONDS`). Cast: Aisha (lead, scripted), phone 1, Hafiz (slowest, scripted) and phone 2, which
joins as the new car "Daniel's City" on Daniel's own road (`data/osrm-car4.json`) and merges between phone 1 and Hafiz.
The route is a 16.3 km piece of `data/osrm-main.json` driven at 95 km/h, so no network is needed. Timeline (T = seconds
after go): spread grows from the start; 90 debris reported ahead (phone 1 alert at about 119); 127 Daniel starts driving;
150-270 Hafiz loses signal (stale "Last seen" from about 210); 330 Daniel merges; 390 phone 2 taps Pit stop > Fuel (the
script writes a marker file the test waits for), Aisha and Hafiz vote, 425 Aisha pins "R&R Demo" (2 km ahead of the lead,
clamped before the destination), 500 resolved; 580 phone 1 arrives; 620 end.

```sh
node demo.mjs --dry-run          # print the timeline and check the geometry, no Firebase, no simulator
node demo.mjs --no-app --seconds 30   # scripted cars only, against the emulators
node demo.mjs --skip-build       # the real thing, reusing the build in --derived-data (/tmp/ikut-dd-q1)
node demo.mjs --one-phone        # the old show: only the iPhone 17, scripted Daniel, Hafiz requests the stop
# both simulators shared with other agents: take the locks first
simlock.sh C0A40D2A-0607-4B95-A1BE-F8C9190D81C1 simlock.sh FD0ACD10-F3C4-4797-8DB8-A6F554585CC1 node demo.mjs
```

Other options: `--udid`, `--udid2`, `--name`, `--speed N` (dev only; the signal-drop staleness needs <= 2.5). Both
simulators get `location-always`, are parked on their start (re-sent every 5 s, nudged, until the app reports a position),
and are driven with `simctl location start`, restarted every 20 s from where each should be. Not covered: phone 1 does not
vote or request a stop (watch only), and the trip is left active unless `--end-trip`.
