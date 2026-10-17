# ikut

An iOS app that keeps a group of cars traveling together in sync: a live convoy map, one-tap stop requests, and hazard alerts for the cars behind.

## Layout

| Folder | What's in it |
| --- | --- |
| `ios/` | SwiftUI app (iOS 17+), bundle ID `dev.aqlan.ikut` |
| `firebase/` | Firestore rules and indexes, Cloud Functions, emulator config (project `ikut-b1083`, asia-southeast1) |
| `design/` | Screen designs from the design canvas (`.dc.html` source files) |

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

## Cloud Functions

TypeScript, Node 22 runtime, region asia-southeast1. `firebase/functions/src/model.ts` mirrors the Swift models in `ios/ikut/Model/`; keep the two in sync.

```sh
cd firebase/functions && npm install && npm run build
```

## Tests

```sh
cd ios
xcodebuild test -scheme ikut -destination 'platform=iOS Simulator,name=iPhone 17'
# Include the emulator integration tests (start the Auth emulator first):
TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test -scheme ikut -destination 'platform=iOS Simulator,name=iPhone 17'
```

Security rules tests (Firestore emulator, needs Java):

```sh
cd firebase/rules-tests && npm install && npm run test:emulator
```
