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

- Ended trips: positions and events are deleted 7 days after `trip.endedAt`. The trip doc is kept.
- Expired events: removed 1 hour after `expiresAt`, in active and ended trips.
- `purgeTripDataJob` (`firebase/functions/src/purgeTripDataJob.ts`, every 6 hours) is the guaranteed path for both. It runs in code, so it works without any console setup.
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
