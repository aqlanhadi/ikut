#!/usr/bin/env node
// Builds the places file the app bundles, from a Geofabrik OpenStreetMap download.
//
//   node tools/osm/extract.mjs <malaysia.osm.pbf> [out.json]
//   (out defaults to ios/ikut/Resources/places.json)
//
// Rebuild monthly:
//   mkdir -p /tmp/osm-dl && curl -L -o /tmp/osm-dl/malaysia.osm.pbf \
//     https://download.geofabrik.de/asia/malaysia-singapore-brunei-latest.osm.pbf
//   node tools/osm/extract.mjs /tmp/osm-dl/malaysia.osm.pbf && rm -r /tmp/osm-dl
//
// Pure node: pbf.mjs reads the file, places.mjs (the tested reference of the app's place logic) turns elements into
// places and works out each place's slip roads, and this file writes only what the app reads. Three passes over
// the download (relations, ways, nodes); about two minutes and under 1 GB of memory.
//
// File shape (all coordinates [latitude, longitude], 5 decimals, about 1 m):
//   {version, generatedAt, source, license,
//    sites: [{id, kind: 'services'|'rest_area', name, at: [lat, lon], ring?: [[lat, lon]...],
//             facilities: ['fuel','food','toilets','ev'], brands?: [...],
//             entries?: [slip], exits?: [slip]}],
//    fuel:  [[id, lat, lon, name|null]]}       // lone fuel stations, not part of a services area
//   slip = [junctionLat, junctionLon, bearing, gateLat, gateLon, meters]: where traffic turns off the motorway
//   (entries) or rejoins it (exits), the carriageway's bearing there, and the point on that road where it reaches
//   the place (the point to route to). Built from OpenStreetMap, ODbL: see README-places.md.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readPbf } from './pbf.mjs';
import { toPlaces, roadIndex, slipRoads, distanceToRing } from './places.mjs';
import { haversine } from '../../qa/lib/route.mjs';

export const FILE_VERSION = 1;
const SITE_KINDS = new Set(['services', 'rest_area']);
const AMENITIES = new Set(['fuel', 'toilets', 'charging_station']);
/** The only tags the place logic reads; everything else is dropped as it is read. */
const KEEP = ['highway', 'amenity', 'name', 'name:en', 'short_name', 'alt_name', 'brand', 'toilets', 'toilet', 'fuel', 'oneway', 'ref', 'type'];
/** Service roads count when within this of a services area or rest area (its slip roads). */
const SLIP_REACH = 500;

const slim = (tags) => {
  const t = {};
  for (const k of KEEP) if (tags[k] !== undefined) t[k] = tags[k];
  return t;
};
const wantedNode = (t) => AMENITIES.has(t.amenity) || SITE_KINDS.has(t.highway);
const wantedWay = (t) => AMENITIES.has(t.amenity) || SITE_KINDS.has(t.highway)
  || t.highway === 'motorway' || t.highway === 'motorway_link' || t.highway === 'service';

const round5 = (n) => Math.round(n * 1e5) / 1e5;
const rc = (p) => [round5(p.latitude), round5(p.longitude)];

/** Joins an area's outer ways end to end into the longest closed ring, or null when they do not close. */
export function joinRing(ways) {
  const parts = ways.filter((w) => w.length >= 2).map((w) => w.slice());
  const same = (a, b) => a.lat === b.lat && a.lon === b.lon;
  let best = null;
  while (parts.length) {
    let ring = parts.shift();
    let grew = true;
    while (grew && !same(ring[0], ring[ring.length - 1])) {
      grew = false;
      for (let i = 0; i < parts.length; i++) {
        const p = parts[i];
        const end = ring[ring.length - 1];
        if (same(p[0], end)) ring = ring.concat(p.slice(1));
        else if (same(p[p.length - 1], end)) ring = ring.concat(p.slice(0, -1).reverse());
        else continue;
        parts.splice(i, 1);
        grew = true;
        break;
      }
    }
    if (same(ring[0], ring[ring.length - 1]) && ring.length >= 4 && (!best || ring.length > best.length)) best = ring;
  }
  return best;
}

/** Reads the download into elements in the shape places.mjs takes (nodes; ways and areas with `geometry`). */
export function readElements(pbf, log = () => {}) {
  // Pass 1: the services and rest areas mapped as multipolygon relations, and which ways outline them.
  const relations = [];
  readPbf(pbf, {
    relations(r) {
      const t = r.tags;
      if (t.type === 'multipolygon' && (SITE_KINDS.has(t.highway) || AMENITIES.has(t.amenity))) {
        relations.push({ id: r.id, tags: slim(t), outer: r.members.filter((m) => m.type === 'way' && m.role !== 'inner').map((m) => m.ref) });
      }
    },
  });
  const outerWays = new Set(relations.flatMap((r) => r.outer));
  log(`relations: ${relations.length} areas`);

  // Pass 2: the ways that matter, with their node ids.
  const ways = new Map();
  readPbf(pbf, {
    ways(w) {
      if (wantedWay(w.tags) || outerWays.has(w.id)) ways.set(w.id, { id: w.id, tags: slim(w.tags), refs: w.refs });
    },
  });
  const need = new Set();
  for (const w of ways.values()) for (const r of w.refs) need.add(r);
  const ids = Float64Array.from(need).sort();
  log(`ways: ${ways.size}, ${ids.length} nodes needed`);

  // Pass 3: the nodes: coordinates for those ids, and the tagged ones (pumps, toilets, chargers, services).
  const lats = new Float64Array(ids.length), lons = new Float64Array(ids.length);
  const tagged = [];
  readPbf(pbf, {
    nodes(n) {
      if (wantedNode(n.tags)) tagged.push({ type: 'node', id: n.id, lat: n.lat, lon: n.lon, tags: slim(n.tags) });
      let lo = 0, hi = ids.length - 1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (ids[mid] === n.id) { lats[mid] = n.lat; lons[mid] = n.lon; return; }
        if (ids[mid] < n.id) lo = mid + 1; else hi = mid - 1;
      }
    },
  });
  const position = (ref) => {
    let lo = 0, hi = ids.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (ids[mid] === ref) return { lat: lats[mid], lon: lons[mid] };
      if (ids[mid] < ref) lo = mid + 1; else hi = mid - 1;
    }
    return null;
  };
  const geometry = (w) => w.refs.map(position).filter(Boolean);
  log(`nodes: ${tagged.length} tagged`);

  const elements = [...tagged];
  for (const w of ways.values()) {
    if (!wantedWay(w.tags)) continue;
    const g = geometry(w);
    if (g.length >= 2) elements.push({ type: 'way', id: w.id, tags: w.tags, geometry: g });
  }
  for (const r of relations) {
    const ring = joinRing(r.outer.map((id) => (ways.has(id) ? geometry(ways.get(id)) : [])));
    if (ring) elements.push({ type: 'relation', id: r.id, tags: r.tags, geometry: ring });
  }
  return elements;
}

/** Service roads far from every services area are dropped: only an R&R's slip roads matter. */
export function keepNearSites(elements, places) {
  const cell = (v) => Math.floor(v / 0.02);
  const grid = new Map();
  for (const p of places) {
    if (p.kind === 'fuel') continue;
    const k = `${cell(p.coordinate.latitude)},${cell(p.coordinate.longitude)}`;
    if (!grid.has(k)) grid.set(k, []);
    grid.get(k).push(p);
  }
  const near = (pt) => {
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
      for (const p of grid.get(`${cell(pt.latitude) + dy},${cell(pt.longitude) + dx}`) ?? []) {
        const d = p.ring ? distanceToRing(pt, p.ring) : haversine(pt, p.coordinate);
        if (d <= SLIP_REACH) return true;
      }
    }
    return false;
  };
  return elements.filter((e) => e.tags?.highway !== 'service'
    || e.geometry.some((g) => near({ latitude: g.lat, longitude: g.lon })));
}

const FACILITIES = ['fuel', 'food', 'toilets', 'ev'];

/** Douglas-Peucker on a closed ring, to about `tolerance` meters (an outline of hundreds of points to a dozen). */
export function simplifyRing(ring, tolerance = 3) {
  const open = ring.slice(0, -1);
  const keep = new Array(open.length).fill(false);
  keep[0] = keep[open.length - 1] = true;
  const m = (p) => ({ x: p.longitude * 111_320 * Math.cos(p.latitude * Math.PI / 180), y: p.latitude * 110_540 });
  const dist = (p, a, b) => {
    const P = m(p), A = m(a), B = m(b);
    const dx = B.x - A.x, dy = B.y - A.y, len2 = dx * dx + dy * dy;
    const t = len2 ? Math.max(0, Math.min(1, ((P.x - A.x) * dx + (P.y - A.y) * dy) / len2)) : 0;
    return Math.hypot(P.x - A.x - t * dx, P.y - A.y - t * dy);
  };
  const go = (i, j) => {
    let worst = 0, at = -1;
    for (let k = i + 1; k < j; k++) { const d = dist(open[k], open[i], open[j]); if (d > worst) { worst = d; at = k; } }
    if (worst > tolerance) { keep[at] = true; go(i, at); go(at, j); }
  };
  go(0, open.length - 1);
  const out = open.filter((_, i) => keep[i]);
  return out.length >= 3 ? [...out, out[0]] : ring;
}

/** The places file's content from elements. Pure, so it is tested without a download. */
export function buildFile(elements, { generatedAt = new Date().toISOString(), source = 'Geofabrik' } = {}) {
  const all = toPlaces(elements);
  const roads = roadIndex(keepNearSites(elements, all));
  const sites = [], fuel = [];
  for (const p of all) {
    if (p.kind === 'fuel') {
      fuel.push([p.id.replace('node/', 'n').replace('way/', 'w').replace('relation/', 'r'), ...rc(p.coordinate), p.name]);
      continue;
    }
    const slips = slipRoads(p, roads);
    const slip = (s) => [...rc(s.junction), Math.round(s.bearing), ...rc(s.gate), Math.round(s.meters)];
    const site = {
      id: p.id, kind: p.kind, name: p.name, at: rc(p.coordinate),
      facilities: FACILITIES.filter((f) => p.facilities[f]),
    };
    if (p.ring) site.ring = simplifyRing(p.ring).map(rc);
    if (p.brands.length) site.brands = p.brands;
    if (slips.entries.length) site.entries = slips.entries.map(slip);
    if (slips.exits.length) site.exits = slips.exits.map(slip);
    sites.push(site);
  }
  sites.sort((a, b) => a.at[0] - b.at[0] || a.at[1] - b.at[1]);
  fuel.sort((a, b) => a[1] - b[1] || a[2] - b[2]);
  return {
    version: FILE_VERSION, generatedAt, source,
    license: 'Contains data from OpenStreetMap, ODbL 1.0, https://www.openstreetmap.org/copyright',
    sites, fuel,
  };
}

/** One line per number, no spaces: sites on their own lines so a diff of two monthly files reads. */
export function serialize(file) {
  const { sites, fuel, ...head } = file;
  const h = JSON.stringify(head).slice(0, -1);
  return `${h},\n"sites":[\n${sites.map((s) => JSON.stringify(s)).join(',\n')}\n],\n"fuel":[\n${fuel.map((f) => JSON.stringify(f)).join(',\n')}\n]}\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [pbf, out = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../ios/ikut/Resources/places.json')] = process.argv.slice(2);
  if (!pbf) { console.error('usage: extract.mjs <malaysia.osm.pbf> [out.json]'); process.exit(64); }
  const started = Date.now();
  const elements = readElements(pbf, (m) => console.log(`${((Date.now() - started) / 1000).toFixed(0)}s ${m}`));
  const file = buildFile(elements, { generatedAt: new Date(fs.statSync(pbf).mtime).toISOString() });
  fs.writeFileSync(out, serialize(file));
  // The licence readme travels with the file (the bundle, and the hosted copy).
  fs.copyFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), 'README-places.md'), path.join(path.dirname(out), 'README-places.md'));
  const bytes = fs.statSync(out).size;
  const by = (k) => file.sites.filter((s) => s.kind === k).length;
  console.log(`${out}: ${(bytes / 1024).toFixed(0)} KB, ${by('services')} services, ${by('rest_area')} rest areas, ${file.fuel.length} lone fuel stations, `
    + `${file.sites.filter((s) => s.entries || s.exits).length} sites with slip roads`);
}
