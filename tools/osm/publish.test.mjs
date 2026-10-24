// node --test tools/osm/publish.test.mjs
// The hosted copy: the manifest's size and SHA-256 are the file's own, and the readme travels with it.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { publish, DEFAULT_SOURCE } from './publish.mjs';

test('the manifest describes the published file', () => {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'places-pub-'));
  const manifest = publish(DEFAULT_SOURCE, out);
  const file = fs.readFileSync(path.join(out, 'places.json'));
  const head = JSON.parse(file.toString('utf8'));
  assert.equal(manifest.bytes, file.length);
  assert.equal(manifest.sha256, crypto.createHash('sha256').update(file).digest('hex'));
  assert.equal(manifest.version, head.version);
  assert.equal(manifest.generatedAt, head.generatedAt);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(out, 'manifest.json'), 'utf8')), manifest);
  assert.ok(fs.existsSync(path.join(out, 'README-places.md')));
  assert.ok(fs.readFileSync(path.join(out, 'manifest.json')).length < 400);
});

test('a changed file gets a different hash', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'places-pub-'));
  const src = path.join(dir, 'places.json');
  fs.writeFileSync(src, '{"version":1,"generatedAt":"2026-01-01T00:00:00.000Z","sites":[]}');
  const a = publish(src, path.join(dir, 'a'));
  fs.writeFileSync(src, '{"version":1,"generatedAt":"2026-02-01T00:00:00.000Z","sites":[]}');
  const b = publish(src, path.join(dir, 'b'));
  assert.notEqual(a.sha256, b.sha256);
  assert.equal(b.generatedAt, '2026-02-01T00:00:00.000Z');
});
