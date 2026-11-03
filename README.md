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

- Release build on a real iPhone: Apple App Attest. This needs the App Attest entitlement, which a free personal team can't sign. `IKUT_APPATTEST` is `YES` in `ios/project.yml` (the paid team is enrolled); clear it to build with a free team, and Release then uses the debug provider like the rest. The same switch signs in Sign in with Apple.
- Debug builds, the simulator, and any device without App Attest: the App Check debug provider. The first launch logs a debug token.
- Against the local emulators the app sends no token and the emulators ignore App Check (the functions never enforce it there), so tests and simulated drives work as before. Firebase logs "Cannot instantiate FIRAppCheck … without a provider factory" on every emulator launch; it is harmless.

Console steps, in this order:

1. Firebase console, App Check, Apps: register the iOS app (`dev.aqlan.ikut`) with App Attest.
2. Every phone that runs ikut against production, Release too until App Attest is on, needs its debug token added (Manage debug tokens). Find it in Console.app with the phone selected: search "App Check debug token". Deleting and reinstalling the app makes a new token.
3. Set `APPCHECK_ENFORCE=true` in `firebase/functions/.env.ikut-b1083` (a local file, not committed), then deploy the functions. The committed `firebase/functions/.env` says `false`, which is what a deploy uses without that file: `joinTrip` and `previewTrip` then accept calls with or without a token. The emulators stay off either way.
4. Check that joining a trip still works from a registered build, then switch on Enforce for Cloud Firestore in the App Check page.

## Cloud Functions

TypeScript, Node 22 runtime, region asia-southeast1. `firebase/functions/src/model.ts` mirrors the Swift models in `ios/ikut/Model/`; keep the two in sync. `onTripEnded` writes a trip's summary when it ends and `purgeTripsFullJob` deletes a trip 90 days after it ended: see *Data retention*.

```sh
cd firebase/functions && npm install && npm run build
```

## Data retention

**What is kept, and for how long (plain words).** While a trip runs, its cars' positions and reports are shared with its members only. Seven days after the trip ends, every position, report and stop answer is deleted, along with each car's own route and each member's push token. Ninety days after it ends, the whole trip is deleted: its name, planned route, planned stops, car and member names, and the small summary below. Nothing is kept longer, and the app keeps no history list on the server: a person's past-trips list lives on their phone. The planned route is the route the organiser drew before the trip, not where anyone drove; it begins where the organiser began planning, is deleted with the trip at day 90, and only members of the trip can read it. Location data in the sense of where a car actually was (positions) is gone at 7 days.

**On the phone.** Past trips, each trip's saved recap and its route on Home's map are kept on the phone only; *Delete from history* removes the entry, the saved recap and the route, and the person leaves the trip. The app also keeps Firestore's normal offline cache; deleting a trip from history does not clear it.

**The trip summary (D107).** When a trip ends (the organiser ends it, or `endIdleTripsJob` ends it after 12 idle hours), the `onTripEnded` function (`firebase/functions/src/summary.ts`, maths in `summaryMath.ts`) writes `summary` on the trip doc once: `distanceMeters` (length of the planned route, the same sum the recap's `RecapLogic.routeDistance` makes; a test pins both to one number), `durationSeconds` (from the first Start Trip, or from creation if it never started, to the end; for a trip ended after 12 idle hours, to its last sign of life instead), `peopleCount` and `carCount` (member and car docs at that moment), `stopCount` (planned stops the lead car reached, i.e. stops with `arrivedAt`; stop requests are not counted, because they expire after 30 minutes), `roadReportCount` (hazard and condition reports still stored when the trip ended: a report already swept after it expired is not counted) and `summarisedAt`. No names, no coordinates, no user ids. Members read it like the rest of the trip doc; no client can write it (the rules' key lists for a trip update do not have it, with a rules test for ending a trip with a planted `summary`). It is written inside a transaction that skips a trip that already has one, so a repeated trigger or the backfill never rewrites it. The daily `purgeTripsFullJob` also writes a summary for an ended trip that is inside its 7 days and has none (it ended before the function was deployed, or the trigger failed); an older trip without one is just deleted at 90 days, because its reports are already gone and the counts would be wrong.

**The 90-day delete.** `purgeTripsFullJob` (`firebase/functions/src/purgeTripDataJob.ts`, `fullPurge.ts`; daily at 04:30 Kuala Lumpur) deletes each trip with `status == "ended"` and `endedAt` more than `TRIP_RETENTION_MS` (90 days, `retention.ts`) ago with `recursiveDelete`: the trip and every subcollection (cars, members, removed, stops and their answers, events and their votes, positions), after deleting its leftover `codes/` claim (only if it names that trip) and its `rotateLimits/{tripId}` and `handOverLimits/{tripId}` counters. Oldest first from its own cursor in `jobState/purgeTripsFull` (apart from the 7-day purge's `jobState/purgeTripData`), at most 100 trips and 5 minutes a run, a failed trip retried first next run. An active trip is never deleted. An ended trip with no `endedAt` is never deleted either (the `endedAt` query never returns it); neither the rules nor `endIdleTrips` can produce one. A retried id whose trip doc is already gone still has its subtree, claim and limit docs cleaned, and leaves the retry list only after that succeeds. Scale: 100 deletes and 500 backfill checks a day are fine now; past about 100 trips ending a day, raise `FULL_MAX_TRIPS_PER_RUN` and run the job more than once a day. To check: `jobState/purgeTripsFull` has `lastRunAt` and the log line `purgeTripsFull: done` counts `deleted`, `summarised`, `failed`. To change the 90 days, edit `TRIP_RETENTION_MS` and redeploy the functions; to stop it, delete the `purgeTripsFullJob` export (the 7-day purge is a different job and does not depend on it). **Deploy order: the functions first** (`onTripEnded` and `purgeTripsFullJob`); the rules did not change for this, so they need no deploy. The first run after the deploy deletes every trip already past 90 days (up to 100 a run, the rest on the following days), so check the owner's wish to keep none of the old trips before deploying.

- Ended trips: 7 days after `trip.endedAt` the purge deletes positions, events (with their stop votes) and skip answers, clears the stops' `arrivedAt`/`leftAt`/`leftBy`, clears each car's own `route` and `mergeOffset` (a car's route often starts at someone's home) and each member's `pushToken`.
- **What is kept after 7 days (until day 90, when the whole trip is deleted):** the trip doc (name, code, destination and the trip's main route), the planned stops (name, kind, minutes, meeting time, note), the car docs (name, colour, number, lead flag, tracker id) and the member docs (display name, car, role), because the recap and Past trips read them. Each car's own route, merge offset and push token are deleted. The trip's main route is kept as it is: it begins where the organizer started when they made the trip, and the recap draws it (the "Trip started" pin). Only members of the trip can read it.
- A member may leave an ended trip (delete their own member doc; the rules allow it, `onMemberDeleted` leaves an ended trip's cars alone, and the app has no Leave button on an ended trip yet), which ends their read access to its cars and positions during the 7 days. Only the organizer of an active trip can remove someone else.
- Trip codes (D103, D108): a trip is created only by the `createTrip` callable (`firebase/functions/src/createTrip.ts`, `createTripCall.ts`); the rules refuse every client create of a trip, an organizer's first member doc and a `codes/{code}` claim, so nobody can probe whether a code is in use by trying to create. The function draws a random 6-character code (the app's 31-character alphabet), and in one transaction checks that no `codes/{code}` doc exists and no active trip has it, then writes the trip, the organizer's member doc and the claim (`tripId`, `organizerId`, `createdAt`) together. A taken code is never reported: it draws again, up to 20 times, then answers `unavailable` ("try again"). It returns only the trip id and the code. The caller sends the trip's name, destination, route, `routeSeconds`, the organizer's name and the id of the car it will create next (the car is the app's second write, as before). Limits per account (`createLimits/{uid}`, server-only, swept hourly like `guessLimits`): 20 trips in any hour and 50 in any 24 hours, then `resource-exhausted` with `details {reason: "too-many-trips", retryAfterSeconds}`; a call that creates nothing gives its slot back. Clients never read, create, update or delete a claim; the purge deletes `codes/{code}` with the rest of the trip's data 7 days after it ended (only if the claim names that trip), after which the code can be used again. Trips made before D103 have no claim and keep working (`joinTrip` looks trips up by code and does not need one); the picker also skips a code an active older trip holds, and `joinTrip`'s "ambiguous" answer stays for that old data. **Deploy order: the functions (`createTrip`) first, then the rules, then the app and `qa/prod-smoke.mjs`**, because the new rules turn away the old app's create, and an app that calls `createTrip` fails until the function is live. Also deploy the functions before or with the rules for the purge: production runs an older functions build whose cursor purge skips trips that end in the gap, so their `codes/{code}` docs, each holding an organizer id, would never be deleted; or delete `jobState/purgeTripData` once after the functions are live, as the D95/D98 note below says.
- Removing and new codes (D104): someone who **left** rejoins with the same code. Someone the **organiser removed** cannot until the organiser makes a new code. A removal is one batch from the organiser's phone: it deletes the member doc and creates `trips/{id}/removed/{userId}` (`userId`, `removedAt` server time, `removedBy`); the rules accept the create only from the organiser of an active trip, for another member, in the batch that deletes that member doc, and refuse the member delete without it. Nobody reads, updates or deletes a `removed` doc from a client (the functions use the admin SDK, so a member cannot learn who was removed; `previewTrip` is unchanged). `joinTrip` looks for the caller's `removed` doc inside its transaction, before writing anything, and answers `permission-denied` "You were removed from this trip. Ask the organiser for a new code." The `rotateTripCode` callable (`rotateTrip.ts`, `rotateTripCall.ts`; input `{tripId}`, answer `{code}` only) is for the organiser of an active trip: in one transaction it draws a free code with the picker of `createTrip.ts`, sets the trip's `code`, deletes the old `codes/{old}` claim (only if it names this trip), creates `codes/{new}` and deletes the trip's `removed/*` docs; people already in stay in, their member docs and cars untouched. A missing trip and someone else's trip give the same `permission-denied` answer ("Only the organiser can make a new code."), an ended trip `failed-precondition`, no free code after 20 tries `aborted`. Limit per trip (`rotateLimits/{tripId}`, server-only, swept hourly): 5 new codes in any hour and 10 in any 24 hours, then `resource-exhausted` with `details {reason: "too-many-codes", retryAfterSeconds}`; a call that changes nothing gives its slot back; the emulators get 1000 and 5000. The app shows it as "New code" in the lobby options (organiser only). `joinTrip` and `previewTrip` also check, inside their read or transaction, that the trip still has the code the caller sent, so a retry with the old code that lands just after a rotation (when the removed list is cleared) is answered like an unknown code. `previewTrip` gives a removed caller only the same removed answer as `joinTrip` (`permission-denied`, `details {reason: "removed"}`, which the app reads), no trip data. `removed` docs stay with the trip doc after it ends (user ids only, no positions). **Deploy order: the functions (`joinTrip` check, `rotateTripCode`) first, then the rules, then the app**: the new rules refuse an organiser's delete of another member without the record, and the app does not remove people yet except through `TripService.removeMember`.
- Handing over (D106): the organiser of an **active** trip cannot leave it (the rules refuse their own member delete), so a trip is never without one: they hand it to another member, then leave as an ordinary member, or end it for everyone (on an ended trip anyone may leave, D98). Before this the organiser could delete their own member doc at any time (the app offered Leave trip once the trip had started, only End before), leaving a trip nobody ran. The `handOverTrip` callable (`handOverTrip.ts`, `handOverTripCall.ts`; input `{tripId, newOrganizerId}`, answer `{ok: true}` only) runs one transaction that reads the trip doc (never the request) and checks the caller is its organiser, the trip is active, and the target is another current member (has a member doc, is not the caller); it then sets `trips/{id}.organizerId`, the `codes/{code}` claim's `organizerId` (when the claim names this trip) and the two members' `role`. A missing trip and someone else's give the same `permission-denied` ("Only the organiser can hand the trip over."), an ended trip `failed-precondition`, a bad or missing target (including a malformed id: slashes, `.`, `..`, `__x__`) `invalid-argument` ("Pick someone who is in the trip."). Clients still cannot write `organizerId` (the trip update rule's key list does not have it). Limit per trip (`handOverLimits/{tripId}`, server-only, swept hourly, reusing the new-code counter): 5 in any hour and 10 in any 24 hours, then `resource-exhausted` with `details {reason: "too-many-handovers", retryAfterSeconds}`; a call that changes nothing gives its slot back; the emulators get 1000 and 5000. **The lead label moves with the trip**: in the same transaction, if the old organiser's car is the lead (`isLead`) and the target rides in another car, `isLead` goes to the target's car and off the old one (that car is then deleted by `onMemberDeleted` once its last rider leaves, which also releases its tracker); if the target has no car, or rides in the same car, `isLead` stays as it is. `isLead` is also what the D97 tracker rule and the stop rules read, and they all follow the flag, so nothing else changes (a car's badge `number` is not renumbered). The new organiser's phone may then take a lead car (`joinTrip` lets only the trip's organiser track it); a lead car already tracked by another member keeps that tracker. The app: the lobby's options and the driving sheet's pulled-up options show "Hand over and leave" (for the organiser, when someone else is in the trip) in place of "Leave trip", then a list of the other members with their car, an alert (`Make Wyna the organiser?`), "Handing over…", the leave, and Home; the organiser alone sees only End trip and a line saying why. If the hand-over lands and the leave does not, the person stays in the trip as an ordinary member and is told so. **Deploy order: the function `handOverTrip` first, then the rules, then the app** (an app without it would let the organiser tap Leave and be refused by the new rules).
- Deleting an account (A4, decision #737): the `deleteAccount` callable (`deleteAccount.ts`, `deleteAccountCall.ts`; input `{tripIds?: string[]}`, an optional hint of the trips the phone knows, at most 200; answer `{ok: true}`; `unauthenticated` without sign-in, `invalid-argument` for a malformed hint) removes everything personal about the signed-in person, then deletes their Auth user last, only if every earlier step worked. It uses the admin SDK, so the rules did not change. It finds their trips by `members.userId` (a collection-group query, new field index in `firestore.indexes.json`, **deploy the indexes before the function**; `createTrip` and `joinTrip` now write `userId` on the member doc, a rejoin fills it in on an older one), by `trips.organizerId`, and by the hint (counted only where the caller has a member doc). In each trip: an organiser of an active trip hands it over (`handOverTripForUser`, same rules and limit; prefers someone in their own car) when others remain, and otherwise, or if the hand-over is refused, ends it and writes its summary at once (so `peopleCount` is right before their docs go); then their authored events (with the votes under them), stop votes and skip answers are deleted, `closedBy`, `skippedBy`, `leftBy`, `stoppedBy` and `removedBy` naming them are cleared, their car's position is deleted, a car nobody else rides in is deleted (the lead car of a trip that is still active only loses its tracker), a car they tracked loses its tracker, and last their member doc (name, push token) and `removed` record go in one batch, with `organizerId` set to `""` on the trip and its code claim when an ended trip still named them. Then `createLimits/{uid}` and `guessLimits/{uid}`. Every step is safe to repeat and the member doc goes last per trip, so a retry finds the same trips and finishes. **What stays**, none of it naming the person or holding a position: other people's trips, cars, events and names; for a trip that ended, its trip doc (name, destination, planned route, `organizerId: ""`), planned stops and `summary` until the 90-day delete; ids of members who were removed by someone else. A trip ID token stays valid up to an hour after the user is deleted, so a phone that still holds one could make a new member doc in that window (it has no account behind it and the usual purge removes it); the app signs out first.
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
command and always puts main's back; only one such run at a time. The shared functions emulator likewise runs main's functions (it reloads from the main checkout), so an emulator test that needs a function a branch adds (`createTrip`, D108) can only run once that function is on main and `npm run build` has been run in `firebase/functions` (the emulator serves the gitignored `lib/`, so a merge alone does not give it `createTrip`); `firebase/functions/test/emulator.test.ts` can run against a private emulator (`IKUT_TEST_PROJECT`, `IKUT_AUTH_HOST`, `IKUT_FUNCTIONS_HOST`, `FIRESTORE_EMULATOR_HOST`).
