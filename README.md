# ikut

An iOS app that keeps a group of cars traveling together in sync: a live convoy map, one-tap stop requests, and hazard alerts for the cars behind.

## Layout

| Folder | What's in it |
| --- | --- |
| `ios/` | SwiftUI app (iOS 17+), bundle ID `dev.aqlan.ikut` |
| `firebase/` | Firestore rules and indexes, Cloud Functions, emulator config (project `ikut-b1083`, asia-southeast1) |
| `design/` | Screen designs from the design canvas (`.dc.html` source files) |
| `qa/` | Simulated convoy drives, live demos and the battery watch ([`qa/README.md`](qa/README.md)) |
| `tools/` | Helpers for working on tasks: start and finish a task, status, test summaries, emulators (`CLAUDE.md`, *Tools*) |

## Local backend

```sh
cd firebase
firebase emulators:start   # Auth :9099, Firestore :8080, UI http://localhost:4000
```

Needs the Firebase CLI and Java 21 on `PATH`.

## iOS app

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `ios/project.yml`. Change settings there, not in Xcode, then regenerate:

```sh
brew install xcodegen
cd ios && xcodegen
open ikut.xcodeproj
```

Debug builds talk to the local emulators (start them first). Set `IKUT_USE_PRODUCTION=1` in the scheme to hit the real project, or `IKUT_EMULATOR_HOST=<Mac's LAN IP>` when running on a real iPhone.

For field tests and battery runs, install with the `ikut-release` scheme. It builds Release, which always uses production, so the app works when opened from the home screen. Free-provisioning installs expire after 7 days.

## Cloud Functions

TypeScript, Node 22 runtime, region asia-southeast1. `firebase/functions/src/model.ts` mirrors the Swift models in `ios/ikut/Model/`; keep the two in sync.

```sh
cd firebase/functions && npm install && npm run build
```

## Data retention

- Ended trips: positions and events are deleted 7 days after `trip.endedAt`. The trip doc is kept.
- Expired events: removed 1 hour after `expiresAt`, in active and ended trips.
- `purgeTripDataJob` (`firebase/functions/src/purgeTripDataJob.ts`, every 6 hours) is the guaranteed path for both. It runs in code, so it works without any console setup.
- Optional: Firestore TTL on `events.expiresAt` also removes expired events, on Firestore's own schedule (typically within 24 hours). Enable it once per project:

```sh
gcloud firestore fields ttls update expiresAt --collection-group=events --enable-ttl --project=ikut-b1083
```

TTL deletes only the event, not its stop votes; `purgeTripDataJob` deletes those once the trip has been ended for 7 days.

TTL does not cover positions, so the scheduled function remains the only thing that enforces the 7-day location promise.

## Tests

```sh
cd ios
xcodebuild test -scheme ikut -destination 'platform=iOS Simulator,id=C0A40D2A-0607-4B95-A1BE-F8C9190D81C1' -collect-test-diagnostics never
# Include the emulator integration tests (start the Auth emulator first):
TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test -scheme ikut -destination 'platform=iOS Simulator,id=C0A40D2A-0607-4B95-A1BE-F8C9190D81C1' -collect-test-diagnostics never
```

Shared test code lives in `ios/ikutTests/Support/` (`Fixtures.swift`: the clock, `Trip.fixture`, `waitUntil`, `EmulatorTrip.make` and the
`.emulator` suite trait; `Fakes.swift`: the tracking and car-route fakes) and `ios/ikutUITests/Support/ConvoyUITestCase.swift` (waits,
screenshots, name sheet, New Trip and join flows). Add to those before copying a helper into a second test file.

A simulator can stand in for a second person. This UI test signs in and joins an existing
trip with a new car (it's skipped unless a code is given):

```sh
TEST_RUNNER_IKUT_JOIN_CODE=Y5REFN TEST_RUNNER_IKUT_JOIN_NAME=Wyna \
  xcodebuild test -scheme ikut -destination 'platform=iOS Simulator,id=C0A40D2A-0607-4B95-A1BE-F8C9190D81C1' -collect-test-diagnostics never -only-testing:ikutUITests
```

Multi-car simulated drives (4 scripted cars plus a real simulator as the fifth) are in [`qa/`](qa/README.md).

Security rules tests (Firestore emulator, needs Java):

```sh
cd firebase/rules-tests && npm install && npm run test:emulator   # starts an emulator on :8080
tools/rules-tests.mjs [worktree]   # same tests on a free port and a scratch config: safe while the shared emulator is in use
```

The app's emulator tests (`TEST_RUNNER_IKUT_EMULATOR_TESTS=1`) use the shared emulator at :8080, which serves main's rules. To run them
against a branch that changes `firestore.rules`: `tools/with-rules.mjs <worktree> -- xcodebuild test …`. It loads the branch's rules, runs the
command and always puts main's back; only one such run at a time.
