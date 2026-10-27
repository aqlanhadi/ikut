# qa: simulated multi-car drives

Repeatable drives that push the whole data flow (rules, callables, positions, events, stops, the convoy panel,
approach alerts) before a real drive. The drives run against the Firebase emulators (project `ikut-b1083`);
start them first (`cd firebase && firebase emulators:start`, or `tools/emulators.mjs`). Only `prod-smoke` and `demo --backend production` can touch the real project. Node 20+.

```sh
cd qa && npm install
node convoy-sim.mjs                  # 4 simulated cars, fast (about 3 min), prints TRIP CODE: XXXXXX, PASS/FAIL per check
node convoy-sim.mjs --speed 1        # real time (15 min), for watching
node run-ui.mjs                      # everything at 2x (about 8.5 min), with the app on simulator C0A40D2A (iPhone 17 #1) as the fifth car
```

Nobody watches an agent's run, so the defaults are as fast as the checks allow, and `--speed 1` (real time) is for
when a person watches or drives the phone. `convoy-sim.mjs` alone plays at 10x and slows to 2x for car 2's signal
drop, the one stretch that has to last in real seconds (see Things to know). With a phone in the loop (`--wait-app`,
`run-ui.mjs`) it plays at one steady speed, 2x by default, since the phone's playback can't follow a changing clock.

`run-ui.mjs` boots the simulator, grants location, starts `convoy-sim.mjs --wait-app`, runs
`ConvoyScenarioUITests` (`ios/ikutUITests`) with `TEST_RUNNER_IKUT_JOIN_CODE`, and feeds
`gpx/car5-app.gpx` to the simulator with `xcrun simctl location start`. Options: `--speed N`, `--skip-build`,
`--udid`, `--derived-data` (default `/tmp/ikut-dd-q1`, seed it from another derived-data folder's `SourcePackages`),
`--deadline S`, `--scenario parked`, `--name` (the joining car's name), `--screens DIR` (default `qa/screens/`), `--logs DIR` (default `$TMPDIR/ikut-qa/`).

To join by hand instead: `node convoy-sim.mjs --speed 1 --wait-app` (or `--setup-only`), join with the printed code
from any simulator or phone (only the organizer starts a trip, so the script starts it once your car shares its
location, and the lobby's button turns to Show map), and feed it the track with `xcrun simctl location <udid> start --speed=27.4 ...` (see `run-ui.mjs`).
`node convoy-sim.mjs --help` lists the other flags.

## Waiting on a run

- **Every runner** (`convoy-sim`, `run-ui`, `run-convoy2`, `demo`, `demo-two-cars`, `prod-smoke`) ends its output
  with one `RESULT: PASS`, `RESULT: FAIL` or `RESULT: ABORT (why)` line, also when it exits early, crashes, is
  stopped, or runs past its `--deadline` (seconds; the default fits its build and scenario). Stopping kills its
  xcodebuild and `convoy-sim` children.
- **The simulators are locked while a run drives them.** `run-ui`, `run-convoy2`, the demos, the playground and `drive-trip` hold
  theirs through `simlock.sh` (a `lockf` on `/tmp/ikut-sim-<udid>.lock`). A second run prints who has the simulator
  and waits up to 30 minutes, then ends with `RESULT: ABORT (simulator … busy …)`. The lock goes with the process,
  so a killed run never leaves it held. Wrap other screen-driving commands the same way:
  `qa/simlock.sh <udid> -- xcodebuild test … -only-testing:ikutUITests/CreateTripUITests`.

- **Don't run `convoy-sim --scenario stop` next to a `with-rules` or rule-mutant run on :8080.** Both use the shared
  emulator: a swapped rules file makes the stop scenario's writes fail or its positions read stale, and its
  FAIL then says nothing about the app (two false FAILs came that way in D25 3b). Run it with the emulator
  otherwise idle, or put its rules in with `tools/with-rules.mjs <worktree> -- node qa/convoy-sim.mjs --scenario stop`.

How agents wait on a run is in `CLAUDE.md`, *Long runs and waiting*.

## Drive one trip by hand

`node drive-trip.mjs [CODE]` (`--udid`, `--host` too) plays a trip's main route on the simulator (the newest active trip in the emulators if no code
is given), so you can create a trip in the app, tap Start trip and watch yourself drive to the destination. `--kmh 100`,
`--speed 20` (time multiplier), `--from 30` (start 30 km along). Set the simulator's location first
(`xcrun simctl location C0A40D2A-0607-4B95-A1BE-F8C9190D81C1 set 3.139,101.687`), since Where to? builds the route from it.

On a real iPhone: `node drive-trip.mjs CODE --gpx trip.gpx` writes a timed GPX. Run the app from Xcode on the phone, then
Debug > Simulate Location > Add GPX File to Workspace... and pick it. For a production trip, pass the route with
`--route <encoded polyline>` instead of a code.

`ConvoyScenarioUITests`' sibling `CreateTripUITests` walks name, New Trip, Where to?, lobby and Start trip;
`TEST_RUNNER_IKUT_HOLD_SECONDS=420` leaves it on the map for a drive.

## Two-phone convoy

```sh
node run-convoy2.mjs                 # builds, then about 5 minutes of test, real time; RESULT: PASS / FAIL
node run-convoy2.mjs --skip-build    # reuse /tmp/ikut-dd-convoy2
node run-convoy2.mjs --ask-location  # phone B starts without location permission and answers the system prompt
```

Other options: `--kmh N` (default 90), `--a-udid`, `--b-udid`, `--derived-data`, `--host`, `--deadline S`, `--screens DIR`, `--logs DIR`.

Two real app instances plus two scripted cars. Phone A (organizer, car 1) is the shared iPhone 17 #1 (`C0A40D2A`), phone B
(car 2) a second simulator, iPhone 17 #2 (`FD0ACD10`, an iPhone 17 Pro; it must already exist, the script never creates one). The script boots
both, grants location, parks them at the start of the E1 just south of Bidor, builds once, then runs
`ConvoyOrganizerUITests` on A and `ConvoyJoinerUITests` on B (`ios/ikutUITests/TwoPhoneConvoyUITests.swift`) at the same
time. Cars 3 (Hafiz) and 4 (Daniel) are Firebase clients in the script: joinTrip, the app's position pipeline, a hazard
report and stop OKs. The three take turns through marker files in `$TMPDIR/ikut-qa/convoy2-sync` (`a.code`, `b.lobby`,
`cars.joined`, `go`, ...); any failure writes `abort` there and every side stops waiting.

Both phones start from the same state every run: before booting anything else the script terminates and uninstalls
the ikut app on A and B (the app's UserDefaults go with it, so `Backend.dropUserFromOtherBackend` signs out the Keychain
user that survives an uninstall) and sets the text size to the default (`simctl ui content_size large`; a leftover
accessibility size from a screenshot session made A's stop button untappable). A phone that kept an old session never
reached the emulators at all ("No connection to the server" on A, a prefilled name on B), so no hand reset is needed.
If a phone still opens in a lobby, the test says so ("This phone is already in a trip") instead of failing on a field.

What it checks, in order (each phone step prints `QA CHECK: PASS|FAIL`, the script checks Firestore alongside):

1. A creates the trip in the UI (name, New Trip, Where to? Ipoh, lobby) and reads the code off the lobby.
2. B joins with the code as a new car; the script joins cars 3 and 4; both lobbies read "4 of 4 ready"; numbers 1, 2, 3, 4.
3. A taps Start trip (only the organizer can); B's lobby reads "Waiting for Aisha to start the trip" until then, and B taps Show map. All four drive the trip's route at 90 km/h (simctl playback for the phones, resynced every 20 s)
   from 3.0 km (A), 2.2 km (3), 1.4 km (B) and 0.6 km (4): convoy panel order 1, 3, 2, 4 on both phones and in Firestore.
4. A reports Debris from the Report sheet; B sees the marker and gets the approach alert (the pill, the map framing B and the debris, the debris pinging). Car 3 then reports an
   accident: the marker shows on both phones, B (behind it) is alerted, A (ahead) is not.
5. B taps Pit stop, Fuel, Add a message (the phone drives, so "Are you a passenger?" first), types "Need fuel, next R and R please" and taps Tell the convoy. A's Pit
   stop button shows the stop with a badge (the card does not open by itself) and the pill asks for an OK; A taps OK on the pill, cars 3 and 4 say OK, A opens the stop from the
   Pit stop button (four OKs, the message in full) and taps We've stopped, B's button shows 4 of 4 OK and then both buttons are Pit stop again. The script checks the event (message, no
   place, `expiresAt` 30 minutes after `createdAt`), A's vote and the close (`status closed`, `closedReason stopped`).
6. B goes back to the lobby and pauses sharing: A's row 2 reads "Paused", `pausedAt` is set; Resume clears both.
7. B leaves the trip: its car disappears from A's list (memberCleanup deletes it). B rejoins as car 5, A ends the trip from
   the map menu and lands on the recap, B's lobby says "Trip ended", the trip doc is `ended`.

Screenshots: `qa/screens/convoy2/A-*.png`, `B-*.png` (`--screens`). Logs: `$TMPDIR/ikut-qa/convoy2-A.log` (`--logs`), `convoy2-B.log` (and the
`.xcresult` bundles next to them). To watch, open Xcode > Window > Devices and Simulators (or the Simulator app with both
devices shown) while it runs. It holds both simulators while it runs (see Waiting on a run).

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
| `lib/scenario.mjs` | The script: cars, speeds, gap, timeline, and the parked and stop scenarios. |
| `lib/rebuild.mjs` | The route rebuilt mid-trip (port of `RouteRebuild`, `StopRouting.join`) and the town-loop geometry of `--scenario rebuild`, with `lib/rebuild.test.mjs`. |
| `lib/stoparrival.mjs` | Who is at a planned stop (port of `StopArrival`), with `lib/stoparrival.test.mjs`. |
| `lib/shell.mjs`, `lib/firebase-config.mjs` | `run`/`simctl`/`sleep`/`makeSay`, `endsWithResult` (the `RESULT` line and `--deadline`) and `holdSimulators` (the simulator lock) for the scripts that drive simulators; the production client config read from the app's plist. |
| `simlock.sh` | Holds one or more simulators while a command runs, see Waiting on a run. |
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
| 700 | Car 3 asks for a fuel stop with the message "Low on fuel, next R&R please" (written with `expiresAt` = 30 minutes later, no place). |
| 730, 735 | Cars 2 and 4 say OK (a vote with `userId` and `at`). The UI test makes the phone say OK from its card. |
| 800 | Car 1 (lead) says We've stopped (`status closed`, `closedReason stopped`, `expiresAt` now). Drive ends at 900. |

**A car parked ahead** (`--scenario parked`, D26): the same convoy plus Mei (car 6, a simulated car with its own
phone model), parked 28 km along, near Gopeng, until the convoy reaches her (drives on at T=835). In `run-ui.mjs
--scenario parked` the app is the parked car instead (`car5-parked.gpx`, parked 24 km along, drives on at T=691).
The timeline moves so it lands while she waits: car 3 asks for fuel at 300, car 2 says OK at 400 (after its drop:
an offline write would hold the clock), car 4 at 450, debris at 520, We've stopped at 800. The heads-up is due
about 2 minutes before the lead reaches her (car 6 about T=704, the phone about T=561).

**A planned stop** (`--scenario stop`, D25 piece 3b): cars 1-4 drive as in the default scenario (car 2's drop, car 4's
merge at 408) but each pulls in at R&R Tapah, 20 km along, and parks there (car 1 about T=532, car 2 565, car 4 598,
car 3 616; tracks `car<N>-stop.gpx`). The organizer writes the stop, a second stop (Kopitiam Gopeng, 50 km along) and
the trip's `startedAt` before the cars set off. No phone car, no timeline: it does not take `--wait-app` and
`run-ui.mjs` does not run it. D25 4a: car 1's phone writes `arrivedAt` when it first counts itself here and taps
Leave once all four are here (`lib/stopleave.mjs` ports Next stop and Leaving at).

**A rebuilt route** (`--scenario rebuild`, D25 4d, 420 s, about 45 s at the default speed): the trip is planned with Lunch in
Bidor, a town stop on a loop off the highway (leaves it at 15 km, 1.5 km out, back at 19 km), and R&R Tapah on the
highway at 22 km. At T=120 car 1 (the organizer, 8.3 km along) skips Lunch for everyone and writes the rebuilt route and the
new offset of R&R Tapah in one batch, as `RouteRebuild.build` and `TripService.rebuildRoute` do (the road behind the
organizer kept, then the highway). Each car's phone follows the new route from the snapshot on. Car 3 is parked at R&R
Tapah all along, car 4 keeps to the highway (1.9 km past the turn-off at T=120, so off the old route), cars 1 and 2
follow; car 4 passes car 3 at about T=305. Tracks are made in memory (`syntheticTrack`), no GPX files; no phone, so not
`--wait-app`.

## What is checked

`convoy-sim.mjs` (PASS/FAIL lines, exit code 1 on any FAIL):

- rules: another car's position, heading 360 and a client timestamp are all rejected
- positions are fresh and on the GPX; car 4 has no `convoyOffset`; its doc is `joining` with `route` and `mergeOffset` (14666 m); cars 2/3 became `convoy` through ensureRoute
- convoy order read back from Firestore equals the order expected from the GPX at T=60, during the drop, after the merge, at T=560
- signal drop: car 2 is older than 60 s while offline, fresh and back at its true position after reconnect
- car 4 merge: state `convoy`, `convoyOffset` present, merged at the scripted time
- hazard: stored with the app's field set and 45 minute expiry; reaches each car's listener within 5 s; ApproachCore (ported) fires exactly once per car behind, at about 500 m, at the time predicted from the GPX; not for the author
- stop: event open with its message, no place, `expiresAt` 30 minutes after `createdAt`; OKs from cars 2 and 4 with nothing but `userId` and `at`; closed as stopped by the lead
- phone: has a position with `convoyOffset`, its car doc is `convoy` with a tracker, and it said OK (with `--expect-app-ok`, which `run-ui.mjs` passes)
- parked (`--scenario parked`, car 6's convoy as `lib/farahead.mjs` ports it from the app): the arrival time comes
  from the lead the whole drive, never the car furthest ahead; no separation warning about the parked car; one
  heads-up "Aisha’s car is 3.2 km behind you." within 20 s of the time the GPX predicts; the far stop request is
  spoken with its distance ("Hafiz needs fuel, 17 km behind. Tap OK."), within 1.5 km of the GPX
- stop (`--scenario stop`, car 1's phone as `lib/stoparrival.mjs` ports `StopArrival` from the app): the stop is stored
  with its place on the route, kind and minutes; each car is counted here within 10 s of the GPX coming within 150 m of
  it, never before (not more than 2 s early); "4 of 4 here" when the last car pulls in, and still at the end; car 1's
  phone writes `arrivedAt` once and "Leaving at" is that plus 20 min; car 1 taps Leave (`leftAt`, `leftBy` car 1)
  after the last car is here, Next stop moves on from R&R Tapah to Kopitiam Gopeng within 10 s, a skip answer, a
  skip for everyone and a second Leave on the left stop are refused, and before it car 2 could not Leave or mark
  the arrival and car 4, still short of the stop, could skip and undo

- rebuild (`--scenario rebuild`; car 1's, car 2's and every phone's view): convoy order against the highway truth before,
  just after and well after the rebuild and after car 4 passes the parked car; one batch, R&R Tapah's offset read
  moving once on every phone (old route, then new, by what the loop added) and Lunch's never; the route read changing
  once; the server holds the same; the new route is the highway, its cut at the organizer; no separation warning
  within 60 s of it (car 2's phone, `lib/farahead.mjs`); the parked car had the new route within 5 s (real) and wrote at most one republish on the old one meanwhile, and never reads "Drove past" (car 1's phone, `lib/stoparrival.mjs`; a car at the stop is "here" by distance, so
  only the offset count can show the transient); car 4 was more than 100 m off the old route and is on the new one with its
  true `convoyOffset`. `OffRouteDetector` is not ported: car 4 turning back into the convoy stays covered by the unit test.
  `IKUT_QA_BREAK=<name>` breaks the drive on purpose to show each check fails: `parked-stays-old` and `parked-late`
  (the parked car keeps the old route, or takes the new one 8 s late), `nobody-swaps`, `batch-twice`, `moves-skipped`
  (the skipped stop is moved too), `car2-prefix-lost` (a rebuild that does not keep the line behind the organizer).

`ConvoyScenarioUITests` (the panel as a person sees it, ids `convoy.row.N`, `joining.row.N`, `convoy.header`,
`convoy.joining.header`, `hazard.marker`):

1. before the drive: rows 1, 2, 3, 5 in that order, car 4 under JOINING, "4 in Convoy"
2. car 2 row says "Last seen"; cars 1 and 3 do not; car 2 drops below car 3
3. car 2 recovers
4. JOINING header disappears; order 1, 2, 4, 3, 5; "5 in Convoy"
5. hazard marker "Hazard: Debris ..." is on the map
6. approach banner "Debris ahead in ... meters"
7. hazard marker clears
8. the Pit stop button shows the stop and the card has the message; tapping OK for our car is recorded; the card goes when the lead taps We've stopped

`testParkedAheadOfTheConvoy` (`run-ui.mjs --scenario parked`, the phone parked ahead): Mei's row says "km ahead ·
parked", the lead's row "km behind", "5 in Convoy"; the stop pill reads "Hafiz needs fuel · 13 km behind" and its
OK is recorded; the `catchup.pill` "Aisha’s car is behind you" shows once; no `convoy.separation` warning through all
three; then the lead passes and the pill goes.

## Things to know

- **Staleness is server time.** `updatedAt` is a server timestamp, so at `--speed` above about 2.5 the 60 s stale threshold is never reached in a 3 minute
  (scenario time) gap; the sim then SKIPs that check. So `convoy-sim.mjs` plays the drop at 2x at most (about 25 s of
  margin), however fast the rest runs.
- **Why a gap means a network drop.** A GPS-only gap does not make a car stale: `PositionPublisher` re-writes the last position every 10 s
  (30 s when still), so a car in a tunnel looks fresh at a frozen spot. What makes a phone stale is a dead network, where the one in-flight write
  hangs. The sim does that for real (`disableNetwork` on car 2's client between the last fix before the gap and the first after) and runs the same
  one-write-in-flight publisher, so on reconnect one old position lands with a fresh timestamp, then the newest.
- **simctl playback drifts.** `xcrun simctl location start` on its own lagged the scenario clock and once stopped delivering fixes for minutes. `run-ui.mjs`
  restarts it every 20 s from the point the GPX says the car should be at.
- Not covered: off-route rerouting (the tracks stay on their roads; `OffRouteDetector` is not ported), background tracking, push, real MapKit ETAs
  (the app asks MapKit; the sim never does).
- Emulator data is not wiped; each run leaves an active trip behind (`--end-trip` ends it).

## Battery watch (real drives)

`node battery-watch.mjs <TRIP CODE> [--car NAME] [--out FILE]` records a real tracker phone's battery and position writes
during a drive (L5, Q2). It joins the trip as a passenger named "Battery watch" in the tracked car
(add `--car "<name>"` when more than one car is tracked), writes every update to
`qa/battery/<CODE>-<time>.csv`, and flags silences over 60 s as they happen. Ctrl-C or ending the
trip prints the drain per hour and the gaps.

It reads from Firebase, not the phone, so the phone can be anywhere with signal. The Mac must stay
awake and online; the script runs `caffeinate`, but a closed lid on battery still sleeps the Mac.
A gap means no signal or a suspended app; the two look the same from here.

## Production smoke test

`node prod-smoke.mjs` runs one short trip against the real Firebase project (from
`ios/ikut/Resources/GoogleService-Info.plist`), writing what main's app writes, field for field, so it fails against
rules or functions older than the build. `node prod-smoke.mjs --emulators` runs the same script against the emulators
(Auth :9099, Firestore :8080, Functions :5001, project `ikut-b1083`); test it there, never point a change at production.
It checks, in order (the Swift each step mirrors is in the script's comments):

- anonymous sign-in; **Create trip** with `routeSeconds` (`TripService.createTrip`), the organiser's car;
- the lobby's stop batch (`TripService.write`): `route`, `routeSeconds`, `stopCount: 1` and a planned **meeting stop**
  (`kind meet`, `coordinate`, `meetAt`, `order 0`);
- `previewTrip`: the organiser's first name, a route that starts at the meeting point (not the organiser's start),
  and the meet stop with its coordinate and `meetAt`; `joinTrip` makes car 2; both cars write a position;
- **only the organiser can start** (D39): a participant's Start is an expected denial (`permission-denied` is a PASS),
  then the organiser's Start; the second car's **stop answer** (`stops/{s}/answers/{carId}`), read by the organiser;
- a participant's **Leave** is refused (expected denial); the organiser marks `arrivedAt` and taps Leave; the car
  takes its answer back; the organiser ends the trip.

Whatever fails, it takes back the answer, deletes the stop if the trip has not started, ends the trip and deletes its
two anonymous users, and it ends in a `RESULT` line (300 s deadline). The ended trip is purged by `purgeTripDataJob`,
which also clears the stop's `arrivedAt`/`leftAt`/`leftBy` and any answer a failed run left (D35 X1); the stop and
trip documents themselves stay, as they do for the app.

## Live demo

Two real-time (1x), 9-minute shows for people watching two simulators, **"iPhone 17 #1"** (`C0A40D2A`, phone 1) and
**"iPhone 17 #2"** (`FD0ACD10`, phone 2). In both, **a phone is the organizer**: phone 1 is Aisha, driving the lead car
(car 1). She creates the trip in the app ("Where to? Ipoh") from the start of a piece of the E1; the script reads that
route back from Firestore (as a member, through the client SDK) and drives everyone along it at 95 km/h, so no network
is needed besides MapKit's route. Scripted cars (Firebase clients) behind the lead: Daniel and Hafiz (slowest, loses
signal). The shared code is `lib/demo-common.mjs` (Car, marker files, xcodebuild, simctl playback, timeline runner, the
stop story); the phones are `ios/ikutUITests/DemoUITests.swift`.

```sh
node demo.mjs                  # 1. the organizer demo: phone 2 = Faiz, a PASSENGER in Aisha's car
node demo-two-cars.mjs         # 2. phone 2 = Faiz in his own car ("Faiz’s Axia") behind Aisha
node demo.mjs --dry-run        # print the timeline and check the geometry (osrm-main.json stands in for the route)
node demo.mjs --skip-build     # reuse the build in --derived-data (default /tmp/ikut-dd-q4)
node demo.mjs --udid U1 --udid2 U2 --end-trip --host H --logs DIR   # --end-trip: about 13 min with the build
node demo.mjs --backend production   # against the real Firebase project (see below)
```

Timeline (T = seconds after go; the same shape in both, differences marked):

| T | 1. organizer demo | 2. two-cars demo |
| --- | --- | --- |
| 0 | Aisha (phone 1) leads, Daniel and Hafiz behind; Faiz rides in her car (phone 2) | Faiz (phone 2) 800 m behind Aisha, ahead of Daniel and Hafiz |
| 75 | Faiz (co-pilot) reports Debris from his Report sheet; the scripted cars behind log "approach alert" | Aisha reports Debris from phone 1; phone 2 behind gets the approach alert (about T+90) |
| 150-270 | Hafiz loses signal; both phones show "Last seen" from about T+210; he comes back | same |
| 300 | **Highlight.** Faiz (a passenger in Aisha's car) taps Pit stop > Fuel > Add a message (the passenger check first), types "Low on fuel, next R&R please" and taps Tell the convoy on phone 2; Hafiz and Daniel tap OK | same, but Faiz drives his own car |
| about 340 | Phone 1: Aisha opens the stop from the Pit stop button and watches the OKs come in (her car asked, so she has none to give) | Phone 1: the pill asks Aisha for an OK, she taps it, then the card shows the OKs |
| about 385 | The request has been open 45 s; Aisha taps We've stopped and the button is Pit stop again on both phones | same |
| 560 | End; the maps stay open until then | same |

Handshake: the phones' tests and the script take turns through marker files in `$TMPDIR/ikut-qa/<demo|demo2>-sync`
(tests to script `a.code`, `b.lobby`, `a.map`, `b.map`, `b.stopRequested`, `a.ok`, `a.stopped`, `b.sawStopped`; script to tests `code`,
`cars.joined`, `report.a`/`report.b`, `stop.b`, `agree`, `arrive`, `end`, `abort`). The tests hold the map until `end` and
never fail the demo over cosmetic checks: those print `QA CHECK: NOTE`, a failed core step prints `QA CHECK: FAIL` and
fails that test after the demo has played out. Ctrl-C / SIGTERM kill the xcodebuilds and clear the simulators' locations.
The trip stays active afterwards unless `--end-trip` (the organizer phone ends it from the lobby's End trip row).

Machine-readable contract (for `qa/dashboard/`): `node <demo>.mjs --describe` prints one JSON object (id, title, summary,
phones, cast, durationSeconds, timeline) and exits 0 without Firebase or simulators. During a run, besides the human
output, lines prefixed `DEMO ` carry compact JSON: `phase` (building, joining, waiting, running, ended, failed), `backend`,
`code`, `event` (each timeline entry as it fires), `check` (each phone's QA CHECK), `tick` (every 5 s) and `error`.

`--backend production` runs the same show against the real Firebase project: the scripts take the client config from
`ios/ikut/Resources/GoogleService-Info.plist` (no emulator calls) and the phones get `IKUT_USE_PRODUCTION=1` (no rebuild
needed). The trip is always ended at the end (also on Ctrl-C/SIGTERM) and the scripted cars' anonymous users are deleted.

## Playground

`node dashboard/server.mjs` (port 4322, `--port` changes it), then the **Playground** tab (a full-height Google map with a side panel; see "The page" below). For trying one event at a time
on the real app without a 9 minute scripted demo: **you tap the phones**, the playground only provides a playable route.
(`demo-playground.mjs` is the script behind it; it takes `CMD {json}` lines on stdin and prints `DEMO {"type":"state"}` once a second.)

1. **Prepare phones** (pick the start: the E1 start used by the demos, or a free `lat,lng`; "Skip the build" reuses
   `--derived-data`, default `/tmp/ikut-dd-q4`). It refuses when another demo, UI test or location playback uses either
   simulator and says which. Then it fresh-installs the app on iPhone 17 #1 and #2, grants location-always, parks both at
   the start and opens the app.
2. **Create a trip on phone 1.** New trips since Prepare are listed with their code, destination, number of cars and how far the
   first car is from the start; press **Use this trip** (or type phone 1's code). Daniel and Hafiz join nothing before that. It
   picks by itself only when there is exactly one new trip, with one car, reporting within 300 m of the start (convoy-sim and
   UI tests make trips too). The page shows the code, big: **join on phone 2 with it.** When phone 1 ends the trip the page says
   "The trip has ended" and the generated cars stop.
3. **Place and play.** On the page: drag pins for each car's start, own ending and deviation ("The page" below); the commands are in "Tracks, pins and the command reference". Per car: speed (0-200 km/h), Play/Pause; Play all / Pause all. Defaults: phone 1 at 3.0 km, phone 2 at 2.2, Daniel 1.4, Hafiz 0.6, all 90 km/h, paused. Phones are driven with `simctl location start` from the car's current offset (restarted on every change and every 20 s); a parked phone gets a nudged `location set` every 5 s (the simulator ignores an unchanged location, the app drops fixes older than 15 s).
4. **Generated cars** (Daniel, Hafiz, and any you add) publish every second through the app's PositionBuilder/PositionPublisher (heartbeats while paused). They do nothing on their own: you say OK, ask and report on command (the page's cards and menus). *Drop signal* is `disableNetwork`, which is what makes a car stale; "Give signal back" re-enables it.
5. The page shows, per car, the position the app/Firestore really has and its age (read as the emulator's owner over REST),
   so a phone that is not following is flagged; plus the trip's events with their OKs, message and closed state.

Close the playground (SIGTERM) stops the players, clears the locations of the simulators it started and closes the generated cars. The trip is
left as it is; end it from phone 1's menu. Emulators only (`--backend production` is refused). It holds both simulators from the moment it starts (`simlock.sh`), so a
`run-ui` or demo started meanwhile waits for it, and it waits for them (up to 30 minutes) if another run has them.

Not covered: background tracking, push, off-route rerouting, MapKit ETAs. After a merge the generated car reports on the main route (the app keeps
its own route offset).

### The page (map and side panel)

Playground tab: a full-height Google map on the left (the trip code, the car list and a live feed in a panel on the right; under the map on a narrow window), in ikut's own colours and car badges, light and dark following the system (`?theme=light` or `?theme=dark` in the address forces one, for screenshots; `#demos` opens the other tab).
The **Scripted demos** tab is the old list (Play, Stop, timeline, checks, log). The page's logic that can be tested without a browser lives in `dashboard/page-logic.mjs` (tests: `lib/page-logic.test.mjs`).

- **Key.** The map needs `GOOGLE_MAPS_API_KEY` in `qa/dashboard/.env` (see `.env.example`; never committed, never printed). `GOOGLE_MAPS_MAP_ID` defaults to `DEMO_MAP_ID`,
  which makes Google ignore any `styles` array; to restyle the map later, make a cloud-styled map ID in the Cloud console and put it in `.env`. The Maps JavaScript API and the Routes API
  must be enabled for the key. Without a key (or if Google rejects it) the page still works: no map, a route strip with the cars, and every pin is a number of kilometres along the route.
- **Before the trip.** "Phones start at": the E1 start of the demos, pins on the map (place phone 1's start and phone 2's, drag to adjust; phone 2 follows phone 1 if not placed; sent as `prepare {starts}`), or a typed latitude, longitude.
  Then Prepare phones, create the trip on phone 1, "Use this trip".
- **On the map.** The shared route, each car's own roads (from the `geometry` line, redrawn only when a version changes), car badges in each car's colour with its initial (the two phones ringed, joining ones dashed,
  a car with no signal faded), a dashed ghost where the app has a car when that is more than 500 m from the playground's, and hazard / stop markers.
- **Pins** (per car, phones included): *Place start* (click, or drag the pin; a phone's start moves it by `placeAt`), *Set ending* (an end pin plus a "leaves here" dot you drag along the route), *Set pin* for a deviation
  (the pin, a wait in seconds, default 30, and a "leaves here" dot). Road paths come from Google's `Route.computeRoutes` and only when a pin is dropped or a drag ends (never while dragging), cached by endpoints:
  a start is one call, an ending one, a deviation two. If routing fails the page says so and sends straight lines. A pin is locked once the car has started driving that piece.
- **Car rows:** place, ending (+ Clear), deviate (+ Cancel), speed, Play/Pause, Drop signal, *Ask stop* and *Report* menus, Rename (inline), Remove, and **Add car** (up to 8 generated cars). A mistake from the playground shows under the row it came from.
- **Stop requests** show as a card over the map as they open (from a generated car or a phone): who asked, the type, the message if there is one, and each generated car with its OK as it lands. Each car that can still answer has **OK**; **Everyone says OK** sends `voteAll`, and **We’ve stopped** (when a generated car asked) sends `markStopped`. The card goes away when the request is no longer open. Each car's *Ask stop* menu sends the text of the box next to it as the message.

### Tracks, pins and the command reference

Every car (both phones and every generated car) drives a **track** (`lib/playground.mjs`): an ordered list of legs, each a stretch of the shared
route (main offsets from-to), an own road (a `RouteLine` with a role: `start`, `out`, `back`, `ending`) or a wait (no length, at a pin). A car keeps
one distance along its track and advances it at its speed. The old "km along the route" is a track that is just the shared route from km X.
A phone plays its track with `simctl location start` from the car's distance, up to the next wait (restarted on every change, every 20 s, and when
a wait starts or ends); a parked phone, one that waits, or one at the end of its track gets the nudged `location set` every 5 s.
Pieces fit in this order: start road, then a deviation, then an ending. A deviation ends (and is cleared) when the car has merged back; a second one on the same car waits again. A piece that does not fit the others (an ending that leaves before a
deviation is over) is refused with a plain message and nothing changes.

Commands are `CMD {json}` lines (the dashboard's `POST /api/command` body). A mistake sets `state.problem` to "That didn't work: <plain words>"
(and `problemAt`, ms); it is cleared by the next command. Coordinates are `{latitude, longitude}`, lists of them have 2 to 20,000 points. `car` is a
key: `phone1`, `phone2`, `daniel`, `hafiz`, then `g3`, `g4`... (stable, never reused). "km" values are kilometres along the shared route.

| Command | Does |
| --- | --- |
| `prepare {starts?:{phone1:{..},phone2:{..}}, start?, skipBuild?, derivedData?}` | As before. `starts` gives each phone its own start (phone 1's is where the trip starts, phone 2 is parked at its own); `start` ("default" or "lat,lng", the old page) puts both phones at one spot and, after the trip is attached, at the default km placements. `state.starts` echoes the phones' starts. |
| `useTrip {tripId?\|code?}` | As before. Attaching joins every generated car. With `starts`: phone 1 gets a start pin track (like `placeAt` without a road), phone 2 stays parked at its start (phase `parked`, no track) until the page sends `placeAt`; without `starts` both phones are at their default km. |
| `placeAt {car, start, road?}` | Start pin. `road` is Google's road from `start` towards the trip destination. Within 150 m of the shared route (`CarRouteLogic.nearMainThreshold`) the car starts on it at the projected offset. Otherwise `CarRouteLogic.makePlan(road, main)` cuts the road at the merge and the car is `joining` (own leg, then the shared route from the merge). No road (or one that never meets the route): a straight densified line to the route about 1.5 km ahead of the start's nearest point. Resets the car to the start of its new track (paused or playing as it was), clears its deviation, keeps its ending when it still fits. |
| `ending {car, end, road?, leaveKm?}` / `clearEnding {car}` | Own ending. `road` runs from a point on the shared route (the car's spot, or `leaveKm`) to `end`. Without `leaveKm` the car leaves where the road diverges from the route for good (the last point within 50 m of it, `divergeOffset`); with it, there (the road is used whole, a short hook is added if it does not start on the route). Without `road`, the road is a straight line from the leave point, and `leaveKm` defaults to where the car is (or where it rejoins). The car drives the shared route to the leave point, then the own road, then parks at the end and keeps publishing. A road that never leaves the shared route is just a parking offset (`pins.endOnRoute`). Refused: a leave point behind the car, a car already on its ending road, a road that leaves the route behind the car by more than about 300 m. `clearEnding` before the leave point drops it; after, the car goes back to the shared route at its old leave point. |
| `deviate {car, pin, out?, back?, waitSeconds?, leaveKm?}` / `cancelDeviation {car}` | Deviation. `out` runs from the leave point to `pin`, `back` from the pin towards the destination; `back` is cut with `makePlan` where it meets the shared route (the car merges there and carries on, and still honours its ending). Defaults: `waitSeconds` 30 (0 to 600; the clock runs only while the car plays), `leaveKm` the car's spot about 5 s ahead, no roads = straight lines. Phases: onRoute, out, waiting, back, onRoute. Refused with a plain message: a car that is joining, already deviating, already on its ending, or a leave point behind the car; a way back that never meets the route or joins it before the pin. `cancelDeviation` before the leave point drops it; after it, the car skips the rest of its wait and drives back. |
| `addCar {name?}` / `removeCar {car}` / `rename {car, name}` | Up to 8 generated cars (Daniel and Hafiz count). A new car takes the next first name from Mei Ling, Arjun, Siti, Kumar, Aina, Wei Jie, Farah, Raj ("<Name>’s <Myvi\|Axia\|Saga\|City\|X70\|Hilux…>"), the next colour of `#c2255c #2b8a3e #b08900 #1098ad #495057 #8b5e34`, joins the attached trip at once and starts paused 500 m behind the rearmost car on the shared route (3 km minus 500 m when none has a place yet; refused once the trip has ended; before a trip it just waits in the list). `removeCar` (generated cars only) stops its player and closes its client; the trip keeps its car doc, which the other phones see go stale. `rename` changes the first name in the playground; the car doc's name is changed too only if the rules let the car's own tracker (they let only the organizer), so after joining the app keeps the old name (`state.cars[].name` is what the app shows, `label` the playground's). |
| `vote {car, event}` / `voteAll {event}` | A generated car says OK to a stop request (a vote doc with `userId` and `at`, as the app writes it). `voteAll` does it for every generated car that has not said OK and did not ask. Refused: a closed request, the car that asked, a car with no signal, a phone. |
| `askStop {car, type, message?}` | A generated car asks for a stop (`stopRest`, `stopFuel`, `stopFood`, `stopToilet`) at its current position and route offset, as the app writes it (`expiresAt` 30 minutes after `createdAt`, no place). `message` is optional, trimmed, 280 letters at most. |
| `markStopped {event}` | We've stopped, written by the generated car that asked (the author may close it as stopped): `status closed`, `closedReason stopped`, `closedBy`, `expiresAt` now. Refused with a plain message when a phone asked: tap We've stopped in the app. |
| `report {car, type}` | A generated car reports `debris`, `accident`, `pothole`, `animal`, `stoppedVehicle`, `roadworks` (hazard, high, 45 min), `heavyRain`, `trafficJam` (condition, medium, 60 min) or `pullingOver`, `carTrouble`, `runningLate` (status, high, no expiry) where it is. |
| `place`, `speed`, `play`, `playAll`, `drop` | As before (`place {car, km, offRoute?, sideMeters?}` builds the same tracks: a main-only track from `km`, or a start road that merges at `km`). |

What a generated car writes to its car doc as it moves (what CarRouteService writes in the app): on the shared route `state convoy` (a car placed there also
clears its `route` and sets `mergeOffset`); on a start road `route` = the road, `mergeOffset` where it merges, `state joining`, no `convoyOffset` until it
merges, then `state convoy`; on a deviation (leave point, out, wait, back) `route` = that whole road from the leave point to the merge, `joining`, then
`convoy` at the merge; on its own ending `route` = the ending road, `mergeOffset` = where its end projects onto the shared route, `joining` (the app has no
per-car destination: a road that never rejoins is exactly what `makePlan` returns for a car driving off to somewhere else), and it never gets a `convoyOffset`.

**State** (`DEMO {"type":"state"}` once a second, plus what the old page reads: `phase, detail, problem, start, code, tripId, destination, routeLength, defaults, candidates`):

- top: `phase` (`setup | preparing | waiting | joining | ready | ended`), `detail` (a sentence for the person), `problem` / `problemAt`, `start` and `starts`
  (`{latitude, longitude, label}`; `starts` is `{phone1, phone2}` or null before Prepare, `start` is phone 1's), `code`, `tripId`, `destination` (name), `routeLength` (m),
  `defaults` ({key: metres} of the old km placements), `candidates` (while `waiting`: `[{tripId, code, destination, cars, firstCarDistance (m|null)}]`), `geometryVersion`, `cars[]`, `events[]`.
  `sideMeters` and `mergeKm` on a car are old-page fields; a phone 2 that was given its own start in `prepare` and has not been placed yet has `phase: 'parked'`, no track and its start as lat/lng.
- `cars[]`, in the order of the list (phones first): `key, label, kind ('phone'|'generated'), name (what the app shows), color, number, joined, carId`; where it is:
  `latitude, longitude, heading` (the car's own track point; null for a phone not yet placed), `offset` (m along the shared route, the nearest point while off it),
  `phase`: `onRoute | joining | out | waiting | back | ending | arrived | parked` (null before the trip), `waitSecondsLeft` (while `waiting`), `trackMeters {at, of}`;
  controls: `speed, playing, offline, state` (the car doc's), `joining, mergeKm, sideMeters` (old page);
  `pins`: `{start: {latitude, longitude}|null, startMergeKm, end: {latitude, longitude}|null, endLeaveKm, endOnRoute, deviation: {pin: {latitude, longitude}, leaveKm, mergeKm, waitSeconds}|null}` (a deviation is cleared once the car has merged back: `pins.deviation` null and its out/back legs leave the geometry, with a `legsVersion` and `geometryVersion` bump, as `cancelDeviation` after the merge);
  `legsVersion` (changes when its own roads change); `reported`: what the app/Firestore has, `{offset, convoyOffset, ageSeconds, speed, latitude, longitude, heading}` or null.
- `events[]`, newest first: `id, type, category, by (label), byKey (car key|null), offset, latitude, longitude, ageSeconds, status ('open'|'closed'),
  message (text|null), ok (the number of OK votes), oks {carKey: true} (only cars of the playground; a car that has not said OK is absent), closedReason ('stopped'|'cancelled'|null), resolved`.

**Geometry** is a separate line, `DEMO {"type":"geometry"}`, sent when the trip is attached or anything below changes (and only then), never every second; the dashboard
server keeps the latest like the state and replays it on reload (`{k:'geometry', geometry}` live, `snapshot.geometry` on connect). `state.geometryVersion` is its `version`:
the page redraws geometry when it differs from the one it holds. Shape: `{type, version, route (the shared route, Google-encoded polyline, precision 5), routeLength (m),
destination: {name, latitude, longitude}|null, cars: {key: {version (= that car's legsVersion), legs: [{role: 'start'|'out'|'back'|'ending', polyline, meters}]}}}`.
Own legs only (the shared stretches are the route); a car with no own road has `legs: []`. Long roads are simplified for display (about 5 m) above 60 kB encoded.

`--dry-run` also builds a start-pin track (the car 4 road of osrm-car4.json), a straight one, an ending and a deviation on the stand-in route and checks
their lengths and merge points; `npm test` (`node --test 'lib/*.test.mjs' '../tools/osm/*.test.mjs'`, so it also runs the OSM extract, places and publish tests) covers every pure function (track maths, divergence, plans, names, answers).

## Dashboard

`node qa/dashboard/server.mjs` opens http://localhost:4322: the Playground tab (above), and the Scripted demos tab, where you pick a live demo, press Play (emulators or production), watch its timeline, checks and log, and Stop it, and the Screens tab: one button per Debug launch state (`IKUT_SCREEN`, read from `DemoScreens` in `LobbyDemo.swift` on every load) that opens the app on iPhone 17 #1 or #2 straight into that screen (busy or not-installed answers say so in words). Details in `qa/dashboard/README.md`.
