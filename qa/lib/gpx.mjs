// Minimal GPX 1.1 writer and reader for single-segment tracks.
import fs from 'node:fs';
import { haversine, bearing } from './route.mjs';

export function writeGpx(file, { name, desc, points }) {
  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<gpx version="1.1" creator="ikut qa/generate-gpx.mjs" xmlns="http://www.topografix.com/GPX/1/1">',
    `  <metadata><name>${esc(name)}</name><desc>${esc(desc)}</desc></metadata>`,
    `  <trk><name>${esc(name)}</name><trkseg>`,
  ];
  for (const p of points) {
    lines.push(`    <trkpt lat="${p.latitude.toFixed(6)}" lon="${p.longitude.toFixed(6)}"><ele>${(p.ele ?? 60).toFixed(1)}</ele><time>${p.time}</time></trkpt>`);
  }
  lines.push('  </trkseg></trk>', '</gpx>', '');
  fs.writeFileSync(file, lines.join('\n'));
}

/** Returns [{latitude, longitude, t}] with t in seconds from the first point. */
export function readGpx(file) {
  const xml = fs.readFileSync(file, 'utf8');
  const out = [];
  const re = /<trkpt lat="([-\d.]+)" lon="([-\d.]+)">(?:<ele>[^<]*<\/ele>)?<time>([^<]+)<\/time><\/trkpt>/g;
  let m;
  while ((m = re.exec(xml))) out.push({ latitude: +m[1], longitude: +m[2], ms: Date.parse(m[3]) });
  if (!out.length) throw new Error(`no track points in ${file}`);
  const t0 = out[0].ms;
  return out.map((p) => ({ latitude: p.latitude, longitude: p.longitude, t: (p.ms - t0) / 1000 }));
}

/**
 * Adds speed (m/s) and course (degrees) to each point from its neighbours, the way a GPS receiver reports them.
 * Across a gap (> maxStep seconds) only the side without the gap is used.
 */
export function withMotion(points, maxStep = 5) {
  return points.map((p, i) => {
    let a = points[i - 1];
    let b = points[i + 1];
    if (a && p.t - a.t > maxStep) a = undefined;
    if (b && b.t - p.t > maxStep) b = undefined;
    const from = a ?? p;
    const to = b ?? p;
    const dt = to.t - from.t;
    if (dt <= 0) return { ...p, speed: 0, course: -1 };
    const d = haversine(from, to);
    return { ...p, speed: d / dt, course: d > 0.5 ? bearing(from, to) : -1 };
  });
}
