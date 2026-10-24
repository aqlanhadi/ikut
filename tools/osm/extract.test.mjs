// node --test tools/osm/*.test.mjs
// The places file build: the .pbf reader on a hand-made file, the area and outline helpers, the file's shape, and
// the bundled file itself (size, Tapah on both carriageways, the Sungai Buloh overhead R&R).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { readPbf, readPbfTimestamp } from './pbf.mjs';
import { joinRing, simplifyRing, buildFile, serialize, readElements } from './extract.mjs';

// ---------------------------------------------------------------- a tiny protobuf writer

const varint = (n) => {
  const out = [];
  while (n >= 128) { out.push((n % 128) | 128); n = Math.floor(n / 128); }
  out.push(n);
  return Buffer.from(out);
};
const zigzag = (n) => (n < 0 ? -2 * n - 1 : 2 * n);
const field = (num, wire, body) => Buffer.concat([varint(num * 8 + wire), body]);
const len = (num, buf) => field(num, 2, Buffer.concat([varint(buf.length), buf]));
const packed = (num, values, signed) => len(num, Buffer.concat(values.map((v) => varint(signed ? zigzag(v) : v))));
const delta = (xs) => xs.map((x, i) => x - (i ? xs[i - 1] : 0));

function pbfFile(strings, group, { raw = false } = {}) {
  const block = Buffer.concat([
    len(1, Buffer.concat(strings.map((s) => len(1, Buffer.from(s))))),
    len(2, group),
  ]);
  const blob = raw ? Buffer.concat([len(1, block), field(2, 0, varint(block.length))])
    : Buffer.concat([field(2, 0, varint(block.length)), len(3, zlib.deflateSync(block))]);
  const header = Buffer.concat([len(1, Buffer.from('OSMData')), field(3, 0, varint(blob.length))]);
  const size = Buffer.alloc(4);
  size.writeUInt32BE(header.length);
  return Buffer.concat([size, header, blob]);
}

/** An OSMHeader block carrying only the replication timestamp (field 32). */
function headerFile(seconds) {
  const block = field(32, 0, varint(seconds));
  const blob = Buffer.concat([field(2, 0, varint(block.length)), len(3, zlib.deflateSync(block))]);
  const header = Buffer.concat([len(1, Buffer.from('OSMHeader')), field(3, 0, varint(blob.length))]);
  const size = Buffer.alloc(4);
  size.writeUInt32BE(header.length);
  return Buffer.concat([size, header, blob]);
}

// Block 1 (compressed): dense nodes going DOWN in id, latitude and longitude, so every delta is negative after
// the first: node 105 (tagged amenity=fuel) then node 100.
const STRINGS = ['', 'amenity', 'fuel'];
const LAT = (d) => Math.round(d * 1e7); // granularity 100 nano-degrees: units of 1e-7 degrees
// Block 2 (raw, uncompressed): a plain, non-dense node south of the equator (negative latitude) tagged
// amenity=toilets; a way whose refs go back and forth; a relation whose member ids go down.
const STRINGS2 = ['', 'amenity', 'toilets', 'type', 'multipolygon', 'highway', 'services', 'outer'];
function sample() {
  const dense = Buffer.concat([
    packed(1, delta([105, 100]), true),
    packed(8, delta([LAT(3.6), LAT(3.5)]), true),
    packed(9, delta([LAT(101.6), LAT(101.5)]), true),
    packed(10, [1, 2, 0, 0], false), // node 105 has amenity=fuel; node 100 has no tags
  ]);
  const plain = Buffer.concat([
    field(1, 0, varint(zigzag(90))), packed(2, [1], false), packed(3, [2], false),
    field(8, 0, varint(zigzag(LAT(-1.25)))), field(9, 0, varint(zigzag(LAT(100.5)))),
  ]);
  const way = Buffer.concat([field(1, 0, varint(7)), packed(8, delta([105, 100, 100, 105]), true)]);
  const relation = Buffer.concat([
    field(1, 0, varint(9)), packed(2, [3, 5], false), packed(3, [4, 6], false),
    packed(8, [7, 7], false), packed(9, delta([7, 3]), true), packed(10, [1, 1], false),
  ]);
  return Buffer.concat([
    pbfFile(STRINGS, len(2, dense)),
    pbfFile(STRINGS2, Buffer.concat([len(1, plain), len(3, way), len(4, relation)]), { raw: true }),
  ]);
}

function tmp(name, data) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ikut-osm-test-'));
  const file = path.join(dir, name);
  fs.writeFileSync(file, data);
  return file;
}

test('the pbf reader decodes dense nodes, ways and relations, and skips the kinds not asked for', () => {
  const file = tmp('s.pbf', sample());
  const nodes = [], ways = [], relations = [];
  readPbf(file, { nodes: (n) => nodes.push(n), ways: (w) => ways.push(w), relations: (r) => relations.push(r) });
  assert.deepEqual(nodes.map((n) => n.id), [105, 100, 90]);
  assert.ok(Math.abs(nodes[0].lat - 3.6) < 1e-7 && Math.abs(nodes[0].lon - 101.6) < 1e-7);
  assert.ok(Math.abs(nodes[1].lat - 3.5) < 1e-7 && Math.abs(nodes[1].lon - 101.5) < 1e-7);
  assert.ok(Math.abs(nodes[2].lat + 1.25) < 1e-7 && Math.abs(nodes[2].lon - 100.5) < 1e-7);
  assert.deepEqual(nodes.map((n) => n.tags), [{ amenity: 'fuel' }, {}, { amenity: 'toilets' }]);
  assert.deepEqual(ways, [{ id: 7, refs: [105, 100, 100, 105], tags: {} }]);
  assert.deepEqual(relations, [{
    id: 9, tags: { type: 'multipolygon', highway: 'services' },
    members: [{ type: 'way', ref: 7, role: 'outer' }, { type: 'way', ref: 3, role: 'outer' }],
  }]);
  const only = [];
  readPbf(file, { relations: (r) => only.push(r.id) });
  assert.deepEqual(only, [9]);
  fs.rmSync(path.dirname(file), { recursive: true });
});

test('the header timestamp is the data time, not the file time', () => {
  const file = tmp('h.pbf', Buffer.concat([headerFile(1_761_264_000), sample()]));
  assert.equal(readPbfTimestamp(file), '2025-10-24T00:00:00.000Z');
  assert.equal(readPbfTimestamp(tmp('s.pbf', sample())), null);
});

test('readElements turns a download into elements: a multipolygon area and a pump node, not its bare outline way', () => {
  const file = tmp('s.pbf', sample());
  const elements = readElements(file);
  assert.deepEqual(elements.map((e) => `${e.type}/${e.id}`).sort(), ['node/105', 'node/90', 'relation/9']);
  const rel = elements.find((e) => e.type === 'relation');
  assert.equal(rel.geometry.length, 4);
  fs.rmSync(path.dirname(file), { recursive: true });
});

test('joinRing closes an area drawn as several ways, whatever their direction', () => {
  const p = (lat, lon) => ({ lat, lon });
  const a = [p(0, 0), p(0, 1)], b = [p(1, 1), p(0, 1)], c = [p(1, 1), p(1, 0), p(0, 0)];
  const ring = joinRing([a, b, c]);
  assert.equal(ring.length, 5);
  assert.deepEqual(ring[0], ring[4]);
  assert.equal(joinRing([a, [p(5, 5), p(6, 6)]]), null);
});

test('simplifyRing drops points on a straight edge and keeps the corners', () => {
  const ring = [[0, 0], [0, 0.0005], [0, 0.001], [0.001, 0.001], [0.001, 0], [0, 0]]
    .map(([latitude, longitude]) => ({ latitude, longitude }));
  const out = simplifyRing(ring);
  assert.equal(out.length, 5); // the middle of the first edge is gone
  assert.deepEqual(out[0], out[out.length - 1]);
});

test('the file holds only what the app reads, with rounded coordinates', () => {
  const g = (lat, lon) => ({ lat, lon });
  const elements = [
    { type: 'way', id: 1, tags: { highway: 'services', name: 'Test R&R' }, geometry: [g(3.50001234, 101.5), g(3.50001234, 101.5011), g(3.5011, 101.5011), g(3.5011, 101.5), g(3.50001234, 101.5)] },
    { type: 'node', id: 2, tags: { amenity: 'fuel', brand: 'Shell', opening_hours: '24/7' }, lat: 3.5005, lon: 101.5005 },
    { type: 'node', id: 3, tags: { amenity: 'fuel', brand: 'Petronas' }, lat: 3.9, lon: 101.9 },
    { type: 'way', id: 4, tags: { highway: 'motorway', ref: 'E1' }, geometry: [g(3.49, 101.499), g(3.51, 101.499)] },
  ];
  const file = buildFile(elements, { generatedAt: '2026-10-24T00:00:00.000Z' });
  assert.equal(file.sites.length, 1);
  assert.deepEqual(file.sites[0].at.map(String), file.sites[0].at.map((x) => String(Math.round(x * 1e5) / 1e5)));
  assert.deepEqual(file.sites[0].facilities, ['fuel', 'food']); // a services area has food by the OSM wiki's definition
  assert.deepEqual(file.sites[0].brands, ['Shell']);
  assert.deepEqual(file.fuel, [['n3', 3.9, 101.9, 'Petronas']]);
  assert.deepEqual(Object.keys(file.sites[0]).sort(), ['at', 'brands', 'facilities', 'id', 'kind', 'name', 'ring']);
  // Round-trips as JSON.
  assert.deepEqual(JSON.parse(serialize(file)), JSON.parse(JSON.stringify(file)));
});

// ---------------------------------------------------------------- the bundled file

const here = path.dirname(fileURLToPath(import.meta.url));
const bundled = path.join(here, '../../ios/ikut/Resources/places.json');

test('the bundled file is small, has Tapah on both carriageways and the Sungai Buloh overhead R&R', () => {
  assert.ok(fs.statSync(bundled).size < 300 * 1024, 'under 300 KB');
  const file = JSON.parse(fs.readFileSync(bundled, 'utf8'));
  assert.equal(file.version, 1);
  const tapah = file.sites.filter((s) => s.name === 'Tapah Rest Area' && s.kind === 'services');
  assert.equal(tapah.length, 2);
  assert.ok(tapah.every((s) => s.entries?.length && s.exits?.length && s.facilities.includes('fuel')));
  const buloh = file.sites.find((s) => s.id === 'relation/11949586');
  assert.ok(buloh.ring.length >= 4 && buloh.facilities.includes('fuel'));
  assert.ok(file.sites.length > 300 && file.fuel.length > 3000);
  // No PLUS or Apple fields, no tags beyond the documented ones.
  const keys = new Set(file.sites.flatMap((s) => Object.keys(s)));
  assert.deepEqual([...keys].sort(), ['at', 'brands', 'entries', 'exits', 'facilities', 'id', 'kind', 'name', 'ring']);
});

test('the readme in the bundle is the one in tools/osm', () => {
  assert.equal(
    fs.readFileSync(path.join(here, 'README-places.md'), 'utf8'),
    fs.readFileSync(path.join(here, '../../ios/ikut/Resources/README-places.md'), 'utf8'),
  );
});
