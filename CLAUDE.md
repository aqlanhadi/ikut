# CLAUDE.md

Guidance for working in this repository. Setup, layout and test commands are in `README.md`; simulated drives are in
`qa/README.md`. Read only the sections you need.

The source is licensed under PolyForm Strict 1.0.0 (`LICENSE`): you may read it and use it for noncommercial purposes,
not distribute or change it. `NOTICE.md` lists what the licence doesn't cover.

## What this is

ikut keeps a group of cars travelling together in sync: a live convoy map, one-tap stop requests and hazard alerts
for the cars behind. SwiftUI app (iOS 17+) in `ios/`, Firebase (Firestore rules, Cloud Functions, emulator config) in
`firebase/`, simulated drives and demos in `qa/`.

## Where things are

`ios/ikut/` is organised by feature (`Map`, `Lobby`, `Session`, `Stops`, `Convoy`, `Recap` and so on); the code map is in
`README.md`, *Code layout*. Shared views and the design tokens are in `ios/ikut/UI/`. Cloud Functions are in
`firebase/functions/src/`, and the Firestore rules in `firebase/firestore.rules`.

## Rules for changes

- **The Xcode project is generated.** Change settings in `ios/project.yml`, then run `xcodegen` in `ios/`. Never edit
  `ikut.xcodeproj` by hand, and on a merge conflict in it, take the other side and regenerate.
- **Swift and TypeScript models mirror each other.** `firebase/functions/src/model.ts` and `ios/ikut/Model/` change
  together.
- **Location data is kept 7 days after a trip ends, no longer.** `purgeTripDataJob`
  (`firebase/functions/src/purgeTripDataJob.ts`) enforces it; don't add code paths that keep positions longer.
- **Identifiers and symbol names are constants.** Accessibility identifiers live in `AXID` (`ios/ikut/UI/AXID.swift`) and
  SF Symbol names in `Symbol` (`ios/ikut/UI/Symbol.swift`). The UI tests find controls by identifier, so never change a
  value without updating the tests; `AXIDTests` checks that every identifier a UI test uses exists.
- **Design tokens, not literals.** Spacing, radius, elevation, colours, type roles and motion come from the tokens in
  `ios/ikut/UI/`. `node tools/design-inventory.mjs --check` fails if ad hoc values creep back in or the generated
  `Debug/DesignInventory.swift` is stale. Run it without `--check` only when you mean to regenerate that file, then
  commit the result.
- **Use Apple's own control sizes** (`.controlSize`, system button styles) rather than fixed heights, except where
  alignment or the 44 pt hit target needs more.
- **Text is localizable.** Literal text in views goes through the String Catalog (`ios/ikut/Localizable.xcstrings`);
  shared components take `LocalizedStringKey`, and runtime values (names, places, numbers) are shown verbatim, never
  looked up. Capitals are applied with `.textCase`, not `uppercased()`.
- **Lists are lazy.** Rows of a SwiftUI `List` that are off screen aren't in the accessibility tree, so UI tests scroll
  first or find the list by identifier.

## Testing

Run each test once, in proportion to the change.

- Unit suites for the code you touched: `-only-testing:ikutTests/<Suite>`. The full unit suite (about 1.5 minutes)
  before merging.
- Add `-collect-test-diagnostics never` to every `xcodebuild test`, or a failing run spends minutes on a sysdiagnose.
- Give the simulator by id: `-destination 'platform=iOS Simulator,id=<udid>'`, never by name. One test run drives a
  simulator's screen at a time.
- A change to how positions, convoy order, events, hazards or stops are computed also runs `qa/convoy-sim.mjs`; a change
  to what the phone does while driving also runs `qa/run-ui.mjs`; a change to `firebase/firestore.rules` runs
  `tools/rules-tests.mjs`; a change to sign-in, trips or writes runs the emulator tests
  (`TEST_RUNNER_IKUT_EMULATOR_TESTS=1`, emulators up). See `README.md`, *Tests*.
- Test the logic, not the looks: routing, offsets, counts, rules and state. Add a UI test only when a change alters the
  navigation or controls of a flow a UI suite already covers.
- Anything that runs over about two minutes (full suites, cold builds, simulated drives) goes to a log file, and you wait
  for it in bounded steps, not an open-ended polling loop.

## Tools

Helpers in `tools/`. `emulators.mjs` starts the Firebase emulators and returns once they answer;
`rules-tests.mjs [worktree]` runs the rules tests on their own port; `with-rules.mjs <worktree> -- <cmd>` runs a
command with that worktree's rules loaded in the shared emulator and restores the main rules after;
`test-summary.mjs <log or .xcresult>` prints passed, failed and skipped counts with each failure's message;
`design-inventory.mjs` is described above. `start-task.mjs`, `finish-task.mjs` and `status.mjs` belong to a private task
board that isn't part of this repository; they won't work without it.
