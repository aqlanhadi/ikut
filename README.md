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
