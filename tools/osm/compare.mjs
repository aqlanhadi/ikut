#!/usr/bin/env node
// D4 spike: the comparison tables. For each direction of the demo trip, every PLUS-listed R&R and lay-by
// against what OpenStreetMap has (found, which side of the road, whether the slip roads agree, facilities) and,
// where a probe was run, what MapKit's category search finds there.
//
//   node tools/osm/compare.mjs <data dir> <plus.json> [north|south]
//
// <data dir> holds fetch-corridor.mjs's files (corridor.json, service-roads.json, route-*.json) and, optionally,
// mapkit-<dir>.json from mapkit-probe.swift. <plus.json> is the PLUS list read by hand ({sites: [{name, dir, km,
// kind, fuel, food, toilets, ev}]}). Neither the PLUS list nor MapKit results are kept: they live in the scratch
// folder for this table only.

import fs from 'node:fs';
import path from 'node:path';
import { toPlaces, roadIndex, along, suggestStops, rankForRequest, RouteLine } from './places.mjs';
import { haversine } from '../../qa/lib/route.mjs';

const [dir, plusFile, only] = process.argv.slice(2);
if (!dir || !plusFile) { console.error('usage: compare.mjs <data dir> <plus.json> [north|south]'); process.exit(64); }
const read = (f) => JSON.parse(fs.readFileSync(path.join(dir, f)));
const elements = read('corridor.json').elements;
if (fs.existsSync(path.join(dir, 'service-roads.json'))) elements.push(...read('service-roads.json').elements);
const plus = JSON.parse(fs.readFileSync(plusFile)).sites;
const places = toPlaces(elements);
const roads = roadIndex(elements);

// PLUS names to OSM names (OSM spells several differently, and a site is often two or three outlines).
const NAMES = {
  'Sungai Buloh': /Overhead Bridge|Jejantas Sungai Buloh/i,
  'Sungai Buloh Lay-by': /Sungai Buloh Layby/i,
  Rawang: /Rawang Rest Area/i,
  'Tanjong Malim': /Tanjung Malim/i,
  Behrang: /Behrang/i,
  'Ladang Bikam': /Bikam/i,
  Tapah: /Tapah/i,
  'Simpang Pulai': /Simpang Pulai/i,
  'Ulu Bernam': /Ulu Bernam/i,
  'Gunung Tempurung': /Tempurung/i,
};

const yes = (b) => (b ? 'y' : '-');
for (const way of only ? [only] : ['north', 'south']) {
  const D = way === 'north' ? 'N' : 'S';
  const route = read(`route-${way}.json`);
  const line = new RouteLine(route.coordinates.map(([lon, lat]) => ({ latitude: lat, longitude: lon })));
  const near = along(places, line, roads).filter((p) => p.kind !== 'fuel');
  const mapkitFile = path.join(dir, `mapkit-${way}.json`);
  const mapkit = fs.existsSync(mapkitFile) ? JSON.parse(fs.readFileSync(mapkitFile)) : null;

  console.log(`\n${way}bound: ${(line.length / 1000).toFixed(1)} km, ${Math.round(route.duration / 60)} min`);
  console.log('PLUS site | dir | KM | OSM found | km on route | OSM side | slip roads | right? | OSM fuel/food/toilets/EV | PLUS | MapKit');
  const counts = { sites: 0, found: 0, right: 0, slipAgree: 0, slipKnown: 0, slipEntrance: 0 };
  for (const name of [...new Set(plus.map((s) => s.name))]) {
    const ours = plus.find((s) => s.name === name && s.dir === D);
    const theirs = plus.find((s) => s.name === name && s.dir !== D);
    // The site's outlines on this route: every match by name, plus unnamed outlines within 300 m of one.
    const named = near.filter((p) => NAMES[name]?.test(p.name ?? ''));
    const group = near.filter((p) => named.includes(p) || (!p.name && named.some((n) => haversine(n.coordinate, p.coordinate) < 300)));
    const mine = group.filter((p) => p.ours);
    if (!group.length) {
      // In OSM but not within reach of this route (the route leaves the highway before it), or not in OSM at all.
      const anywhere = places.find((p) => NAMES[name]?.test(p.name ?? ''));
      const off = anywhere && line.project(anywhere.coordinate);
      console.log(`${name} | ${ours ? D : 'other only'} | ${(ours ?? theirs).km} | ${off ? `in OSM, ${(off.distance / 1000).toFixed(1)} km off this route` : 'no'} | not counted`);
      continue;
    }
    counts.sites++;
    counts.found++;
    // Right when the side matches PLUS: a site PLUS lists for this direction shows on our side, a site it lists
    // only for the other direction does not.
    const right = ours ? mine.length > 0 : mine.length === 0;
    if (right) counts.right++;
    for (const p of group) {
      if (!p.carriageway) continue;
      counts.slipKnown++;
      if ((p.carriageway === 'ours') === p.ours) counts.slipAgree++;
    }
    if (mine.some((p) => p.slipEntrance)) counts.slipEntrance++;
    const f = (k) => mine.some((p) => p.facilities[k]);
    const site = ours ?? theirs;
    let mk = '';
    if (mapkit && mine.length) {
      const hits = mapkit.filter((m) => mine.some((p) => haversine(p.coordinate, { latitude: m.latitude, longitude: m.longitude }) < 500));
      mk = hits.length ? hits.map((m) => `${m.name} (${m.category.replace('MKPOICategory', '')})`).slice(0, 4).join('; ') : 'nothing within 500 m';
    }
    console.log([
      name, ours ? D : `${theirs.dir} only`, site.km, `${group.length} outline(s)`,
      (group[0].routeOffset / 1000).toFixed(1), group.map((p) => p.side).join('+'),
      group.map((p) => p.carriageway ?? '?').join('+'), right ? 'yes' : 'NO',
      mine.length ? ['fuel', 'food', 'toilets', 'ev'].map((k) => yes(f(k))).join('/') : '',
      ours ? [Boolean(ours.fuel), ours.food, ours.toilets, ours.ev].map(yes).join('/') : '', mk,
    ].join(' | '));
  }
  console.log(`sites on this route ${counts.sites}, found in OSM ${counts.found}, side right ${counts.right}, slip roads known for ${counts.slipKnown} outlines and agree on ${counts.slipAgree}, a mapped slip-road entrance on our side at ${counts.slipEntrance}`);
  const extra = near.filter((p) => p.ours && !Object.values(NAMES).some((re) => re.test(p.name ?? '')) && p.distance < 200);
  // Worked examples for the discovery page: what "Suggest stops" proposes, and three places for a stop request.
  const trip = { routeLength: line.length, routeSeconds: route.duration };
  const show = (rows) => rows.map((r) => `${r.place.name ?? r.place.kind} at ${(r.place.routeOffset / 1000).toFixed(1)} km: ${r.where ? `${r.where} · ` : ''}${r.why}`).join('\n  ') || 'none';
  console.log(`suggest stops (every 2 h):\n  ${show(suggestStops(near, trip))}`);
  console.log(`suggest stops (every 1 h, for comparison):\n  ${show(suggestStops(near, { ...trip, every: 3600, window: 900 }))}`);
  const speed = line.length / route.duration;
  for (const [front, reasons] of [[60_000, ['toilet']], [60_000, ['toilet', 'fuel']], [100_000, ['food']]]) {
    console.log(`request at ${front / 1000} km for ${reasons.join(' + ')}:\n  ${show(rankForRequest(near, { frontOffset: front, reasons, speed }))}`);
  }
  console.log(`not on the PLUS list, on our side within 200 m: ${extra.map((p) => `${p.name ?? p.kind} ${(p.routeOffset / 1000).toFixed(1)} km`).join('; ') || 'none'}`);
}
