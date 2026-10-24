# ikut places file

`places.json` lists the services areas (R&Rs), rest areas and fuel stations of Malaysia, Singapore and Brunei,
with what each has (fuel and brands, food, toilets, EV charging), its outline, and the slip roads between it and
the motorway. ikut reads it to suggest stops and to find a place to stop on the road.

## Licence

The data is **© OpenStreetMap contributors**, available under the **Open Database License (ODbL) 1.0**:
<https://www.openstreetmap.org/copyright>. This file is a Derivative Database of OpenStreetMap and is offered under
the same licence: copy, share and adapt it, keeping this credit and the same licence. Nothing in it comes from
PLUS, Apple or any other source.

## How it is built

From the Geofabrik download `malaysia-singapore-brunei-latest.osm.pbf`
(<https://download.geofabrik.de/asia/malaysia-singapore-brunei.html>, itself ODbL), by `tools/osm/extract.mjs` in
the ikut repository, about once a month (node only, no other install; about 25 to 40 seconds and under 2 GB of memory):

    curl -L -R -o malaysia-singapore-brunei-latest.osm.pbf https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf
    node tools/osm/extract.mjs <malaysia-singapore-brunei-latest.osm.pbf>

It keeps `highway=services`, `highway=rest_area` and `amenity=fuel`, and the `toilets` and `charging_station`
points inside them; the slip roads are the one-way `service` and `motorway_link` roads that join a place to a
`motorway`. Coordinates are rounded to 5 decimals (about 1 m).

## Format

`version`, `generatedAt` (the data's own time, so the same download gives the same file), `source`, `license`, then `sites` (objects: `id`, `kind`, `name`, `at` `[lat, lon]`,
`ring`, `facilities`, `brands`, `entries`, `exits`) and `fuel` (`[id, lat, lon, name]` per lone fuel station). A
slip road is `[junctionLat, junctionLon, bearing, gateLat, gateLon, meters]`.

## Publishing a new file to phones

The app checks `https://ikut-b1083.web.app/places/manifest.json` once a week when it opens (`ios/ikut/Places/PlacesRefresher.swift`)
and downloads the file only when its `generatedAt` is newer than the one in use. To publish:

1. Run `extract.mjs` as above. With its default output it also copies the file and this readme to `firebase/hosting/places/` and
   writes `manifest.json` (version, generatedAt, bytes, SHA-256) there; `node tools/osm/publish.mjs` does just that step.
2. Commit the new bundled and hosted files together (the next app build then carries the same file).
3. `cd firebase && firebase deploy --only hosting`.

A phone ignores a hosted file whose size or hash does not match the manifest, that does not read, whose `version` is newer than
the app knows, or that has fewer than half the sites of the bundled file. Never publish a file with a higher `version` without an
app that reads it.
