// A small reader for OpenStreetMap .pbf files (the Geofabrik downloads), pure JS on node's own zlib, so the places
// file can be rebuilt with nothing installed (no osmium, no npm packages).
//
//   readPbf(file, { nodes, ways, relations })   streams the file's blocks; each callback gets one entity at a time
//
// A callback is only called for the kinds you pass (the others are skipped without decoding their tags), so a pass
// that wants relations or ways does not pay for the 60 million nodes. Entities are
//   node      {id, lat, lon, tags}
//   way       {id, refs: [node ids], tags}
//   relation  {id, members: [{type: 'node'|'way'|'relation', ref, role}], tags}
// Tags are plain objects. Format: https://wiki.openstreetmap.org/wiki/PBF_Format

import fs from 'node:fs';
import zlib from 'node:zlib';

/** Protobuf wire reader over a Buffer; varints are read as doubles (exact to 2^53, ample for OSM ids). */
class Reader {
  constructor(buf, pos = 0, end = buf.length) { this.buf = buf; this.pos = pos; this.end = end; }
  get more() { return this.pos < this.end; }
  varint() {
    let result = 0, mul = 1, b;
    do {
      b = this.buf[this.pos++];
      result += (b & 0x7f) * mul;
      mul *= 128;
    } while (b & 0x80);
    return result;
  }
  /** Negative int64 (ten bytes) as a negative number: only the low 53 bits matter here. */
  svarint() { const n = this.varint(); return n % 2 === 1 ? -(n + 1) / 2 : n / 2; }
  bytes() { const n = this.varint(); const r = this.buf.subarray(this.pos, this.pos + n); this.pos += n; return r; }
  skip(wire) {
    if (wire === 0) this.varint();
    else if (wire === 1) this.pos += 8;
    else if (wire === 2) { const n = this.varint(); this.pos += n; }
    else if (wire === 5) this.pos += 4;
    else throw new Error(`bad wire type ${wire}`);
  }
  /** Calls `on(field, wire, reader)` for every field; `on` must consume the value (or return false to skip it). */
  fields(on) {
    while (this.more) {
      const tag = this.varint();
      const field = Math.floor(tag / 8), wire = tag % 8;
      if (on(field, wire, this) === false) this.skip(wire);
    }
  }
  packed(signed) {
    const r = new Reader(this.bytes());
    const out = [];
    while (r.more) out.push(signed ? r.svarint() : r.varint());
    return out;
  }
}

function inflateBlob(buf) {
  let raw = null, zlibData = null;
  new Reader(buf).fields((f, w, r) => {
    if (f === 1) raw = r.bytes();
    else if (f === 3) zlibData = r.bytes();
    else return false;
  });
  return raw ?? zlib.inflateSync(zlibData);
}

/** Every blob of the file as [type, decoded bytes], reading the file in pieces. */
function* blobs(file) {
  const fd = fs.openSync(file, 'r');
  try {
    let pos = 0;
    const size = fs.fstatSync(fd).size;
    const head = Buffer.alloc(4);
    while (pos < size) {
      fs.readSync(fd, head, 0, 4, pos);
      const headerLen = head.readUInt32BE(0);
      const header = Buffer.alloc(headerLen);
      fs.readSync(fd, header, 0, headerLen, pos + 4);
      let type = '', dataSize = 0;
      new Reader(header).fields((f, w, r) => {
        if (f === 1) type = r.bytes().toString('utf8');
        else if (f === 3) dataSize = r.varint();
        else return false;
      });
      const data = Buffer.alloc(dataSize);
      fs.readSync(fd, data, 0, dataSize, pos + 4 + headerLen);
      pos += 4 + headerLen + dataSize;
      yield [type, inflateBlob(data)];
    }
  } finally { fs.closeSync(fd); }
}

const MEMBER_TYPES = ['node', 'way', 'relation'];

function decodeBlock(buf, want) {
  const strings = [];
  const groups = [];
  let granularity = 100, latOffset = 0, lonOffset = 0;
  new Reader(buf).fields((f, w, r) => {
    if (f === 1) {
      new Reader(r.bytes()).fields((sf, sw, sr) => {
        if (sf === 1) strings.push(sr.bytes().toString('utf8')); else return false;
      });
    } else if (f === 2) groups.push(r.bytes());
    else if (f === 17) granularity = r.varint();
    else if (f === 19) latOffset = r.svarint();
    else if (f === 20) lonOffset = r.svarint();
    else return false;
  });
  const tagsOf = (keys, vals) => {
    if (!keys.length) return {};
    const t = {};
    for (let i = 0; i < keys.length; i++) t[strings[keys[i]]] = strings[vals[i]];
    return t;
  };
  const lat = (v) => 1e-9 * (latOffset + granularity * v);
  const lon = (v) => 1e-9 * (lonOffset + granularity * v);

  for (const g of groups) {
    new Reader(g).fields((f, w, r) => {
      if (f === 1 && want.nodes) { // plain nodes
        let id = 0, la = 0, lo = 0, keys = [], vals = [];
        new Reader(r.bytes()).fields((nf, nw, nr) => {
          if (nf === 1) id = nr.svarint(); else if (nf === 2) keys = nr.packed(false); else if (nf === 3) vals = nr.packed(false);
          else if (nf === 8) la = nr.svarint(); else if (nf === 9) lo = nr.svarint(); else return false;
        });
        want.nodes({ id, lat: lat(la), lon: lon(lo), tags: tagsOf(keys, vals) });
      } else if (f === 2 && want.nodes) { // dense nodes
        let ids = [], las = [], los = [], kv = [];
        new Reader(r.bytes()).fields((df, dw, dr) => {
          if (df === 1) ids = dr.packed(true); else if (df === 8) las = dr.packed(true); else if (df === 9) los = dr.packed(true);
          else if (df === 10) kv = dr.packed(false); else return false;
        });
        let id = 0, la = 0, lo = 0, k = 0;
        for (let i = 0; i < ids.length; i++) {
          id += ids[i]; la += las[i]; lo += los[i];
          let tags = {};
          if (kv.length) {
            while (kv[k] !== 0 && k < kv.length) { tags[strings[kv[k]]] = strings[kv[k + 1]]; k += 2; }
            k++;
          }
          want.nodes({ id, lat: lat(la), lon: lon(lo), tags });
        }
      } else if (f === 3 && want.ways) {
        let id = 0, keys = [], vals = [], refs = [];
        new Reader(r.bytes()).fields((wf, ww, wr) => {
          if (wf === 1) id = wr.varint(); else if (wf === 2) keys = wr.packed(false); else if (wf === 3) vals = wr.packed(false);
          else if (wf === 8) refs = wr.packed(true); else return false;
        });
        let ref = 0;
        want.ways({ id, refs: refs.map((d) => (ref += d)), tags: tagsOf(keys, vals) });
      } else if (f === 4 && want.relations) {
        let id = 0, keys = [], vals = [], roles = [], mems = [], types = [];
        new Reader(r.bytes()).fields((rf, rw, rr) => {
          if (rf === 1) id = rr.varint(); else if (rf === 2) keys = rr.packed(false); else if (rf === 3) vals = rr.packed(false);
          else if (rf === 8) roles = rr.packed(false); else if (rf === 9) mems = rr.packed(true); else if (rf === 10) types = rr.packed(false);
          else return false;
        });
        let m = 0;
        want.relations({
          id, tags: tagsOf(keys, vals),
          members: mems.map((d, i) => ({ type: MEMBER_TYPES[types[i]], ref: (m += d), role: strings[roles[i]] })),
        });
      } else return false;
    });
  }
}

/**
 * When the data was current: the header's `osmosis_replication_timestamp` (seconds, same for every download of the
 * same Geofabrik file), as an ISO string, or null when the header has none.
 */
export function readPbfTimestamp(file) {
  for (const [type, data] of blobs(file)) {
    if (type !== 'OSMHeader') continue;
    let seconds = null;
    new Reader(data).fields((f, w, r) => { if (f === 32) seconds = r.varint(); else return false; });
    return seconds === null ? null : new Date(seconds * 1000).toISOString();
  }
  return null;
}

/** Reads the whole file once, calling `want.nodes`, `want.ways` and `want.relations` for the kinds given. */
export function readPbf(file, want) {
  for (const [type, data] of blobs(file)) {
    if (type === 'OSMData') decodeBlock(data, want);
  }
}
