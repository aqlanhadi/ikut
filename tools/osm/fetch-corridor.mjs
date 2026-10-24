#!/usr/bin/env node
// One-time download for the D4 spike: the KL-Ipoh corridor from OpenStreetMap, and the drive both ways.
//
//   node tools/osm/fetch-corridor.mjs <out dir>   # corridor.json, service-roads.json, route-north.json, route-south.json
//
// Developer use only, run by hand once and cached: the public Overpass and OSRM servers are not for app traffic
// (https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances). The shipped plan is an extract
// built from a Geofabrik file in the same JSON shape (design/discovery/stop-places.html), never a live query
// from a phone.
//
// The files stay outside the repo (the overseer: untrusted downloads in their own folder), and an existing file
// is never fetched again.

import fs from 'node:fs';
import path from 'node:path';

const out = process.argv[2];
if (!out) { console.error('usage: fetch-corridor.mjs <out dir>'); process.exit(64); }
fs.mkdirSync(out, { recursive: true });

// KL (Jalan Kuching) to Ipoh, the demo trip.
const KL = { latitude: 3.1700, longitude: 101.6830 };
const IPOH = { latitude: 4.5975, longitude: 101.0901 };
// South, west, north, east: covers the E1 from KL to Ipoh with a few km either side.
const BBOX = '3.10,100.98,4.68,101.75';

const UA = { 'User-Agent': 'ikut-d4-spike/1 (one-time developer query)' };

async function osrm(from, to) {
  const url = `https://router.project-osrm.org/route/v1/driving/${from.longitude},${from.latitude};${to.longitude},${to.latitude}?overview=full&geometries=geojson`;
  const res = await fetch(url, { headers: UA });
  const json = await res.json();
  if (json.code !== 'Ok') throw new Error(`OSRM ${json.code}`);
  const r = json.routes[0];
  return { source: url, fetchedAt: new Date().toISOString(), distance: r.distance, duration: r.duration, coordinates: r.geometry.coordinates };
}

// Everything the stop pieces need and nothing else: services and rest areas, fuel stations, toilets, the
// slip roads, and the motorway carriageways (for which way each slip road joins).
const QUERY = `[out:json][timeout:180];
(
  nwr["highway"~"^(services|rest_area)$"](${BBOX});
  nwr["amenity"~"^(fuel|toilets|charging_station)$"](${BBOX});
  way["highway"~"^(motorway|motorway_link)$"](${BBOX});
);
out geom tags;`;

// The service roads within 500 m of a services area or rest area: most R&R slip roads on the E1 are one-way
// `highway=service`, not `motorway_link`.
const SERVICE_ROADS = `[out:json][timeout:180];
nwr["highway"~"^(services|rest_area)$"](${BBOX})->.s;
way["highway"="service"](around.s:500);
out geom tags;`;

async function overpass(query = QUERY) {
  const res = await fetch('https://overpass-api.de/api/interpreter', {
    method: 'POST', headers: { ...UA, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'data=' + encodeURIComponent(query),
  });
  if (!res.ok) throw new Error(`Overpass ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const json = await res.json();
  return { source: 'overpass-api.de', query, fetchedAt: new Date().toISOString(), osm3s: json.osm3s, elements: json.elements };
}

async function once(name, make) {
  const file = path.join(out, name);
  if (fs.existsSync(file)) { console.log(`${name}: cached`); return; }
  const data = await make();
  fs.writeFileSync(file, JSON.stringify(data));
  console.log(`${name}: ${(fs.statSync(file).size / 1024).toFixed(0)} KB`);
}

await once('route-north.json', () => osrm(KL, IPOH));
await once('route-south.json', () => osrm(IPOH, KL));
await once('corridor.json', () => overpass(QUERY));
await once('service-roads.json', () => overpass(SERVICE_ROADS));
