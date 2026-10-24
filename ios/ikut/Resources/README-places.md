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
the ikut repository, about once a month, in one command (node only, no other install):

    node tools/osm/extract.mjs <malaysia-singapore-brunei-latest.osm.pbf>

It keeps `highway=services`, `highway=rest_area` and `amenity=fuel`, and the `toilets` and `charging_station`
points inside them; the slip roads are the one-way `service` and `motorway_link` roads that join a place to a
`motorway`. Coordinates are rounded to 5 decimals (about 1 m).

## Format

`version`, `generatedAt`, `source`, `license`, then `sites` (objects: `id`, `kind`, `name`, `at` `[lat, lon]`,
`ring`, `facilities`, `brands`, `entries`, `exits`) and `fuel` (`[id, lat, lon, name]` per lone fuel station). A
slip road is `[junctionLat, junctionLon, bearing, gateLat, gateLon, meters]`.
