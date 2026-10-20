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
