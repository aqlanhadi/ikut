# ikut

An iOS app that keeps a group of cars traveling together in sync: a live convoy map, one-tap stop requests, and hazard alerts for the cars behind.

## Layout

| Folder | What's in it |
| --- | --- |
| `ios/` | SwiftUI app (iOS 17+), bundle ID `dev.aqlan.ikut` |
| `firebase/` | Firestore rules and indexes, Cloud Functions, emulator config (project `ikut-b1083`, asia-southeast1) |
| `qa/` | Simulated convoy drives, live demos and the battery watch ([`qa/README.md`](qa/README.md)) |
| `tools/` | Helpers for working on tasks: start and finish a task, status, test summaries, emulators (`CLAUDE.md`, *Tools*); `tools/design-inventory.mjs` rewrites `ios/ikut/Debug/DesignInventory.swift` (the one-offs in Settings > Design, behind the name button): rerun it after a merge to refresh, `--check` says if it is stale, `--lower` lowers the ratchet ceilings (ad hoc literals, and the D78 token counts in `Debug/DesignTokenCeiling.swift`) after a piece that removes some |

## Local backend

```sh
cd firebase
firebase emulators:start   # Auth :9099, Firestore :8080, Functions :5001, UI http://localhost:4000
```

Needs the Firebase CLI and Java 21 on `PATH`.

## iOS app

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `ios/project.yml`. Change settings there, not in Xcode, then regenerate:

```sh
brew install xcodegen
cd ios && xcodegen
open ikut.xcodeproj
```

### Code layout (`ios/ikut/`)

One map, one sheet, one reader of the trip's data. Where the pieces live:

- **The trip screen** (`Map/TripScreen.swift`, `Map/MapSpace.swift`): `TripScreenModel` decides the mode (Home, lobby, driving) and holds the open trip's objects as one `OpenTrip` (session, lobby model, planner), made once when the trip opens. `TripSheet` is the one sheet for every mode. `MapSpace` is the one map frame and the one cover (what the top layers and the sheet hide), which Home, the lobby and driving all read for their camera. `TripScreenHost` draws the map and the layers over it.
- **Home** (`App/`): `HomeModel` holds its flows and what the camera did before each. `TripsHomeView` is the sheet; its rows, header, rename alerts and Debug demo states are `HomeTripRows`, `HomeHeader`, `HomeRenameAlerts` and `TripsHomeView+Demo`.
- **The trip's data** (`Session/`): `TripSession` is the one reader of the trip, cars, stops and members; the lobby and the convoy both read from it. `TrackingDuty` runs the car's tracker for it.
- **Lobby** (`Lobby/`): `LobbyView` and `LobbyModel`, with the tall-sheet sections in `LobbySheetSections` (they also continue below the convoy while driving).
- **Driving** (`Map/`): `TripMapView` is the driving layer over the host's map. `ConvoySheetState` holds the convoy sheet's motion and card hand-over; `CameraInputsWatch` (`CameraInsetMove.swift`) turns everything that changes what the camera can see into one move.
- **Debug launch states** (`IKUT_SCREEN`): `Lobby/LobbyDemo.swift`.

Debug builds talk to the local emulators (start them first). Set `IKUT_USE_PRODUCTION=1` in the scheme to hit the real project, or `IKUT_EMULATOR_HOST=<Mac's LAN IP>` when running on a real iPhone.

For field tests and battery runs, install with the `ikut-release` scheme. It builds Release, which always uses production, so the app works when opened from the home screen. Free-provisioning installs expire after 7 days.

## App Check

App Check makes the app prove to Firebase that it is the real app, so someone who only has the committed `GoogleService-Info.plist` can't call the backend.

- Release build on a real iPhone: Apple App Attest. This needs the App Attest entitlement, which a free personal team can't sign; until the paid team is set up (see the comment on `IKUT_APPATTEST` in `ios/project.yml`), Release builds use the debug provider like the rest.
- Debug builds, the simulator, and any device without App Attest: the App Check debug provider. The first launch logs a debug token.
- Against the local emulators the app sends no token and the emulators ignore App Check (the functions never enforce it there), so tests and simulated drives work as before. Firebase logs "Cannot instantiate FIRAppCheck … without a provider factory" on every emulator launch; it is harmless.

Console steps, in this order:

1. Firebase console, App Check, Apps: register the iOS app (`dev.aqlan.ikut`) with App Attest.
2. Every phone that runs ikut against production, Release too until App Attest is on, needs its debug token added (Manage debug tokens). Find it in Console.app with the phone selected: search "App Check debug token". Deleting and reinstalling the app makes a new token.
3. Set `APPCHECK_ENFORCE=true` in `firebase/functions/.env.ikut-b1083` (a local file, not committed), then deploy the functions. The committed `firebase/functions/.env` says `false`, which is what a deploy uses without that file: `joinTrip` and `previewTrip` then accept calls with or without a token. The emulators stay off either way.
4. Check that joining a trip still works from a registered build, then switch on Enforce for Cloud Firestore in the App Check page.

## Cloud Functions

TypeScript, Node 22 runtime, region asia-southeast1. `firebase/functions/src/model.ts` mirrors the Swift models in `ios/ikut/Model/`; keep the two in sync.

```sh
cd firebase/functions && npm install && npm run build
```

## Data retention

- Ended trips: 7 days after `trip.endedAt` the purge deletes positions, events (with their stop votes) and skip answers, clears the stops' `arrivedAt`/`leftAt`/`leftBy`, clears each car's own `route` and `mergeOffset` (a car's route often starts at someone's home) and each member's `pushToken`.
- **What is kept after 7 days:** the trip doc (name, code, destination and the trip's main route), the planned stops (name, kind, minutes, meeting time, note), the car docs (name, colour, number, lead flag, tracker id) and the member docs (display name, car, role), because the recap and Past trips read them. Each car's own route, merge offset and push token are deleted. The trip's main route is kept as it is: it begins where the organizer started when they made the trip, and the recap draws it (the "Trip started" pin). Only members of the trip can read it.
- A member may leave an ended trip (delete their own member doc; the rules allow it, `onMemberDeleted` leaves an ended trip's cars alone, and the app has no Leave button on an ended trip yet), which ends their read access to its cars and positions during the 7 days. Only the organizer of an active trip can remove someone else.
- Trip codes (D103): each new trip claims its code in the same batch that creates it, as `codes/{code}` (`tripId`, `organizerId`, `createdAt`). The rules accept a claim only while no doc holds that code, so two trips never share one, and refuse any read, update or delete from a client. The claim is not freed when the trip ends: the purge deletes `codes/{code}` with the rest of the trip's data 7 days after it ended (only if the claim names that trip), after which the code can be used again. The app retries with a new code up to 5 times if a claim is refused, then asks the person to try again. Trips made before D103 have no claim and keep working (`joinTrip` looks trips up by code and does not need one), so a code of an older active trip can still be copied by a new trip until that trip ends; `joinTrip`'s "ambiguous" answer stays for that old data. Deploy the rules before the app and before `qa/prod-smoke.mjs`, which now claim codes.
- Push tokens: the app does not write `pushToken` today and the rules refuse it (every member can read member docs). When push is built (A1/A2) the token goes in an owner-only document, not on the member doc.
- Deploy order: production runs an older functions build. If D95's cursor purge runs before D98 is live, old ended trips are passed over and their car routes are never cleared. Deploy D95 and D98 together, or delete `jobState/purgeTripData` once after D98 is live (the purge is safe to repeat).
- Known: a trip whose name is already over 200 characters (made before the cap) cannot be ended or renamed by its organizer, because the rules check the whole doc; `endIdleTrips` (admin) still ends it. The app now limits names to 60.
- Size caps in the rules (above anything the app writes): route strings 200,000 characters (about 4,000 km: the app's polyline is about 50 characters per km, 65 km is 3,091 characters), trip name 200 (the app limits it to 60), destination name 300, car name 100, colour 32, stop name 120, notes and messages 280, ids 128. `previewTrip` also thins a line to 1,500 points before simplifying, so even a hostile route answers in milliseconds.
- Expired events: removed 1 hour after `expiresAt`, in active and ended trips.
- `purgeTripDataJob` (`firebase/functions/src/purgeTripDataJob.ts`, every 6 hours) is the guaranteed path for both. It runs in code, so it works without any console setup. It takes ended trips oldest first from a cursor kept in `jobState/purgeTripData` (at most 500 trips and 5 minutes a run, so a backlog is finished over several runs and a finished trip is never read again); `purgeExpiredEventsJob` sweeps expired events hourly on its own, and the 6-hourly job sweeps them too even when its trip step ran out of cap or time. `endIdleTrips` keeps a cursor the same way (`jobState/endIdleTrips`) and goes round.
- Firestore TTL on `events.expiresAt` is left off in production (owner, 2026-10-25): the purge job covers expired events, and TTL would leave each stop request's votes behind until the trip has been ended 7 days. It could remove expired events on Firestore's own schedule (typically within 24 hours); to check or turn it on:

```sh
gcloud firestore fields ttls list --project=ikut-b1083
gcloud firestore fields ttls update expiresAt --collection-group=events --enable-ttl --project=ikut-b1083
```

TTL deletes only the event, not its stop votes; `purgeTripDataJob` deletes those once the trip has been ended for 7 days.

TTL does not cover positions, so the scheduled function remains the only thing that enforces the 7-day location promise.

## Tests

```sh
cd ios
xcodebuild test -scheme ikut -destination 'platform=iOS Simulator,id=C0A40D2A-0607-4B95-A1BE-F8C9190D81C1' -collect-test-diagnostics never -only-testing:ikutTests   # unit suite, about 1.5 min
# Include the emulator integration tests (start the emulators first):
TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test -scheme ikut -destination 'platform=iOS Simulator,id=C0A40D2A-0607-4B95-A1BE-F8C9190D81C1' -collect-test-diagnostics never -only-testing:ikutTests
```

Without `-only-testing` the scheme also runs every UI suite on the simulator. Add `-only-testing:ikutUITests/<suite>` for one:
`CreateTripUITests` takes about 5 min, `LobbyStopsUITests` about 1.

Shared test code lives in `ios/ikutTests/Support/` (`Fixtures.swift`: the clock, `Trip.fixture`, `waitUntil`, `EmulatorTrip.make` and the
`.emulator` suite trait; `Fakes.swift`: the tracking and car-route fakes) and `ios/ikutUITests/Support/ConvoyUITestCase.swift` (waits,
screenshots, name sheet, New Trip and join flows). Add to those before copying a helper into a second test file.

A simulator can stand in for a second person. This UI test signs in and joins an existing
trip with a new car (it's skipped unless a code is given; about 1 min):

```sh
TEST_RUNNER_IKUT_JOIN_CODE=Y5REFN TEST_RUNNER_IKUT_JOIN_NAME=Wyna \
  xcodebuild test -scheme ikut -destination 'platform=iOS Simulator,id=C0A40D2A-0607-4B95-A1BE-F8C9190D81C1' -collect-test-diagnostics never -only-testing:ikutUITests/ConvoyScenarioUITests/testFifthCarInSimulatedConvoy
```

Multi-car simulated drives (4 scripted cars plus a real simulator as the fifth), the two-phone run and the live demos are in [`qa/`](qa/README.md).

Security rules tests (Firestore emulator, needs Java):

```sh
cd firebase/rules-tests && npm install && npm run test:emulator   # starts its own emulator on :8080, so not while the shared one is up
tools/rules-tests.mjs [worktree]   # same tests on a free port and a scratch config: safe while the shared emulator is in use
```

The app's emulator tests (`TEST_RUNNER_IKUT_EMULATOR_TESTS=1`) use the shared emulator at :8080, which serves main's rules. To run them
against a branch that changes `firestore.rules`: `tools/with-rules.mjs <worktree> -- xcodebuild test …`. It loads the branch's rules, runs the
command and always puts main's back; only one such run at a time.
