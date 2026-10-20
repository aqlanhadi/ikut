# Demo dashboard

A local page to list the live demos (`qa/demo*.mjs`), start one, stop it and watch its events.

    node qa/dashboard/server.mjs [--port 4322] [--demos <dir | dir/pattern*.mjs>]   # http://localhost:4322

- Each demo is asked for `--describe` (JSON) when the server starts; "Look for demos again" re-reads them.
  A script without `--describe` is still listed, so Play works.
- Play runs `node <demo> [--skip-build] [--end-trip] --backend emulators|production` in `qa/`. One demo at a time
  (the second start gets a 409). Stop sends SIGTERM, then SIGKILL after 90 s (a production run needs up to 60 s to end the real trip).
- The Emulators / Production switch is remembered in the browser. Production shows a warning, reads "Play on
  production", asks "Are you sure?" first, and always ends the trip.
- The run's events and last 500 log lines are kept in memory and replayed on reload.
- `fake-demo.mjs` is a pretend 40 s demo for trying the page: copy it to a folder as `demo-fake.mjs` and start the
  server with `--demos <folder>`.

## Playground (interactive demos)

A demo whose `--describe` says `"interactive": true` (`demo-playground.mjs`) gets its own card at the top of the page
and is not in the list of scripted demos. The server starts it with its stdin piped and:

- `POST /api/command` with a JSON body writes `CMD {json}` plus a newline to the running demo's stdin. It answers 409
  when nothing is running or the demo is not interactive.
- the demo's `DEMO {"type":"state", ...}` lines (one a second) are not kept as a history: only the latest is kept,
  sent to the page as `{k:'state'}` and replayed on reload.

The card walks through setup (start picker, Prepare phones, Skip the build), waiting for the trip, and the controls
(trip code, route strip, one row per car, Play all / Pause all, what was reported). Production is never offered:
the playground refuses `--backend production`. See `qa/README.md`, "Playground".
Developing the script without simulators: `IKUT_PLAYGROUND_NO_SIM=1 node qa/dashboard/server.mjs --port 4324`.
