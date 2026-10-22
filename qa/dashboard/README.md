# Demo dashboard

A local page with two tabs: the **Playground** (a Google map with a side panel, below) and **Scripted demos** (list the live demos `qa/demo*.mjs`, start one, stop it and watch its events).

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

A demo whose `--describe` says `"interactive": true` (`demo-playground.mjs`) is the Playground tab and is not in the list of scripted demos. The server starts it with its stdin piped and:

- `POST /api/command` with a JSON body writes `CMD {json}` plus a newline to the running demo's stdin. It answers 409
  when nothing is running or the demo is not interactive.
- the demo's `DEMO {"type":"state", ...}` lines (one a second) are not kept as a history: only the latest is kept,
  sent to the page as `{k:'state'}` and replayed on reload. `DEMO {"type":"geometry", ...}` lines (the playground's shared route and each
  car's own roads, sent only when they change) are kept the same way: sent as `{k:'geometry', geometry}` and replayed as `snapshot.geometry`.
- `POST /api/command` bodies are at most 2 MB (413 with plain words beyond) and must be a JSON object (400 otherwise); the demo checks every
  coordinate (finite, at most 20,000 points a list) and number and reports mistakes in `state.problem`.
- `GET /api/config` returns `{mapsKey, mapId}` for the page's Google map: from `qa/dashboard/.env` (gitignored; `.env.example` lists the names and the
  referrers to restrict the key to) or the environment, `GOOGLE_MAPS_API_KEY` (null when absent) and `GOOGLE_MAPS_MAP_ID` (default `DEMO_MAP_ID`).
  Read once at start; answered only for a trusted Host (below), 403 otherwise.

The page walks through setup (start picker or start pins, Prepare phones, Skip the build), waiting for the trip, and the controls
(trip code, one row per car with its pins, Play all / Pause all, Add car, what was reported), with the cars, roads, pins and stop request cards on the map.
`GET /page-logic.mjs` serves the page's plain logic module (tested by `qa/lib/page-logic.test.mjs`).

**Map key:** copy `.env.example` to `.env` and set `GOOGLE_MAPS_API_KEY`; open the page on `http://localhost:4322`, `http://127.0.0.1:4322` or the port you started it on, as the key's website restriction allows.
`GOOGLE_MAPS_MAP_ID` defaults to `DEMO_MAP_ID` (Google ignores any `styles` array with it; set a cloud-styled map ID in `.env` to restyle). Without a key the page runs as a plain list with pins as kilometres. The page's
layout, controls and pins are described in `qa/README.md`, "The page". Production is never offered:
the playground refuses `--backend production`. See `qa/README.md`, "Playground".
Developing the script without simulators: `IKUT_PLAYGROUND_NO_SIM=1 node qa/dashboard/server.mjs --port 4324`.

POSTs (`/api/start`, `/api/stop`, `/api/command`) and `GET /api/config` need `Content-Type: application/json` and a Host (and Origin, when a browser sends one) of
`127.0.0.1` or `localhost` on the server's own port; anything else gets a 403 (a GET has no content type to check). With curl add `-H 'content-type: application/json'`.
