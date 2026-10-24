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
import { readPbf } from './pbf.mjs';
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

function pbfFile(strings, group) {
  const block = Buffer.concat([
    len(1, Buffer.concat(strings.map((s) => len(1, Buffer.from(s))))),
    len(2, group),
  ]);
  const blob = Buffer.concat([field(2, 0, varint(block.length)), len(3, zlib.deflateSync(block))]);
  const header = Buffer.concat([len(1, Buffer.from('OSMData')), field(3, 0, varint(blob.length))]);
  const size = Buffer.alloc(4);
  size.writeUInt32BE(header.length);
  return Buffer.concat([size, header, blob]);
}

// Strings: 0 is the empty one. Two nodes (ids 100, 105) the second tagged amenity=fuel, then a way and a relation.
const STRINGS = ['', 'amenity', 'fuel', 'highway', 'services', 'type', 'multipolygon', 'outer'];
const LAT = (d) => Math.round(d * 1e7); // granularity 100 nano-degrees: units of 1e-7 degrees
function sample() {
  const dense = Buffer.concat([
    packed(1, delta([100, 105]), true),
    packed(8, delta([LAT(3.5), LAT(3.6)]), true),
    packed(9, delta([LAT(101.5), LAT(101.6)]), true),
    packed(10, [0, 1, 2, 0], false), // node 100 has no tags; node 105 has amenity=fuel
  ]);
  const way = Buffer.concat([field(1, 0, varint(7)), packed(8, delta([100, 105, 105, 100]), true)]);
  const relation = Buffer.concat([
    field(1, 0, varint(9)), packed(2, [5, 3], false), packed(3, [6, 4], false),
    packed(8, [7], false), packed(9, delta([7]), true), packed(10, [1], false),
  ]);
  return pbfFile(STRINGS, Buffer.concat([len(2, dense), len(3, way), len(4, relation)]));
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
  assert.equal(nodes.length, 2);
  assert.deepEqual(nodes.map((n) => n.id), [100, 105]);
  assert.ok(Math.abs(nodes[1].lat - 3.6) < 1e-7 && Math.abs(nodes[1].lon - 101.6) < 1e-7);
  assert.deepEqual(nodes[0].tags, {});
  assert.deepEqual(nodes[1].tags, { amenity: 'fuel' });
  assert.deepEqual(ways, [{ id: 7, refs: [100, 105, 105, 100], tags: {} }]);
  assert.deepEqual(relations, [{ id: 9, tags: { type: 'multipolygon', highway: 'services' }, members: [{ type: 'way', ref: 7, role: 'outer' }] }]);
  const only = [];
  readPbf(file, { relations: (r) => only.push(r.id) });
  assert.deepEqual(only, [9]);
  fs.rmSync(path.dirname(file), { recursive: true });
});

test('readElements turns a download into elements: a multipolygon area and a pump node, not its bare outline way', () => {
  const file = tmp('s.pbf', sample());
  const elements = readElements(file);
  assert.deepEqual(elements.map((e) => `${e.type}/${e.id}`).sort(), ['node/105', 'relation/9']);
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
