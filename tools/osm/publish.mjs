// node tools/osm/publish.mjs [places.json] [outDir]
// Copies the places file and its readme to firebase/hosting/places/ (not in git) and writes manifest.json beside them: the few
// hundred bytes the app checks once a week (version, generatedAt, byte size, SHA-256). `firebase deploy` runs this
// first (hosting predeploy in firebase.json), so the hosted copy is always the bundled file.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const DEFAULT_SOURCE = path.join(here, '../../ios/ikut/Resources/places.json');
export const DEFAULT_OUT = path.join(here, '../../firebase/hosting/places');

export function publish(source = DEFAULT_SOURCE, outDir = DEFAULT_OUT) {
  const data = fs.readFileSync(source);
  const { version, generatedAt } = JSON.parse(data.toString('utf8'));
  const manifest = { version, generatedAt, bytes: data.length, sha256: crypto.createHash('sha256').update(data).digest('hex') };
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, 'places.json'), data);
  fs.copyFileSync(path.join(here, 'README-places.md'), path.join(outDir, 'README-places.md'));
  fs.writeFileSync(path.join(outDir, 'manifest.json'), `${JSON.stringify(manifest)}\n`);
  return manifest;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [source, out] = process.argv.slice(2);
  console.log(JSON.stringify(publish(source, out)));
}
