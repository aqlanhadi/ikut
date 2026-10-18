# qa: simulated multi-car drives

Repeatable drives that push the whole data flow (rules, callables, positions, events, stops, the convoy panel,
approach alerts) before a real drive. Everything runs against the Firebase emulators (project `ikut-b1083`);
start them first (`cd firebase && firebase emulators:start`). Node 20+.

```sh
cd qa && npm install
node convoy-sim.mjs                  # 4 simulated cars, real time, prints TRIP CODE: XXXXXX, PASS/FAIL per check
node convoy-sim.mjs --speed 2        # 2x (the signal-drop check needs <= 2.5x, see below)
node run-ui.mjs --speed 1            # everything, with the app on simulator 88B5ECF1 as the fifth car
```

`run-ui.mjs` boots the simulator, grants location, starts `convoy-sim.mjs --wait-app`, runs
`ConvoyScenarioUITests` (`ios/ikutUITests`) with `TEST_RUNNER_IKUT_JOIN_CODE`, and feeds
`gpx/car5-app.gpx` to the simulator with `xcrun simctl location start`. Options: `--speed N`, `--skip-build`,
`--udid`, `--derived-data` (default `/tmp/ikut-dd-q1`, seed it from another derived-data folder's `SourcePackages`).
Screenshots land in `qa/screens/`, logs in `$TMPDIR/ikut-qa/`.

To join by hand instead: `node convoy-sim.mjs --wait-app`, join with the printed code from any simulator or phone, and
feed it the track with `xcrun simctl location <udid> start --speed=27.4 ...` (see `run-ui.mjs`).
`node convoy-sim.mjs --help` lists the other flags.

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

## Bugs this found (not fixed here)

1. **Crash on opening the map as tracker** (`ios/ikut/Map/TripMapView.swift:369`, `ios/ikut/Hazards/HazardRegionMonitor.swift:240,244`).
   `CLMonitor` names must be alphanumeric; `"ikut.hazards.<tripId>"` (and the default `"ikut.hazards"`) contain dots, so `CLMonitor(name)` throws
   `NSInternalInconsistencyException: Monitor name is not valid` and the app aborts. Repro: join a trip as tracker, tap Start Trip. Expected: map. Actual: crash.
2. **Stop button icon missing** (`ios/ikut/Map/ConvoyPanel.swift`, `Image(systemName: "minus.octagon.fill")`): the system logs
   `No symbol named 'minus.octagon.fill' found in system symbol set` on the iOS 27 simulator and the Stop button shows no icon (see `screens/`).
3. **Alert banner hidden behind the stop card** (`TripMapView.topStack` vs `stopCard`): with a stop request open, the approach banner is
   partly covered by the card (see `06-approach-alert.png` from an earlier run). Layering/space issue.
4. Observation: a GPS-only gap never makes a car stale (heartbeat re-writes the last position), see Things to know. Probably intended; worth a decision.

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
