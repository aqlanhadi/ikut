import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { isIdle } from "../src/idle.ts";
import { Timestamp } from "firebase-admin/firestore";
import { compareKeys, cursorFromState, cursorToState, runSweep, type SweepCursor, type SweepItem } from "../src/sweep.ts";
import { EVENT_GRACE_MS, POSITION_RETENTION_MS, TRIP_RETENTION_MS, eventExpiryCutoff, shouldDeleteTrip, shouldPurgeTripData } from "../src/retention.ts";
import { routeDistanceMeters, summaryDurationSeconds } from "../src/summary.ts";
import { MAX_SIMPLIFY_POINTS, decodePolyline, encodePolyline, routeFrom, simplifiedRoute, thin } from "../src/previewRoute.ts";
import { DAY_MS, recentMisses, tooManyTries, waitMs } from "../src/guessLimit.ts";
import { CODE_ALPHABET, CODE_LENGTH, generateCode, parseCreateInput } from "../src/createTrip.ts";
import { EMULATOR_LIMITS, PRODUCTION_LIMITS, limitsFor, HOUR_MS, MAX_PER_DAY, MAX_PER_HOUR, createWaitMs, recentCreates, tooManyTrips, DAY_MS as CREATE_DAY_MS } from "../src/createLimit.ts";
import { APPCHECK_ENFORCE, appCheckOptions, appCheckOptionsFor, normalizeCode, normalizeName, parseJoinInput, pickCarColor } from "../src/joinTrip.ts";

const base = { code: "ab3-d9x", displayName: "  Aqlan   Z ", car: { newCar: { name: "Myvi", color: "red" } }, tracker: true };

function rejects(fn: () => unknown, code = "invalid-argument") {
  assert.throws(fn, (e: { code?: string }) => e.code === code);
}

describe("normalizeCode", () => {
  it("uppercases and strips spaces and dashes", () => assert.equal(normalizeCode(" ab3-d 9x "), "AB3D9X"));
  it("rejects bad lengths and characters", () => {
    for (const c of ["ABC12", "ABC1234", "ABC!23", "", "ÅBC123"]) rejects(() => normalizeCode(c));
  });
  it("rejects non-strings", () => rejects(() => normalizeCode(123456)));
});

describe("normalizeName", () => {
  it("trims and collapses whitespace", () => assert.equal(normalizeName("  a \t b  ", "x"), "a b"));
  it("rejects empty, blank, too long", () => {
    rejects(() => normalizeName("", "x"));
    rejects(() => normalizeName("   ", "x"));
    rejects(() => normalizeName("a".repeat(31), "x"));
  });
  it("accepts exactly 30", () => assert.equal(normalizeName("a".repeat(30), "x").length, 30));
});

describe("parseJoinInput", () => {
  it("parses newCar", () => {
    assert.deepEqual(parseJoinInput(base), {
      code: "AB3D9X", displayName: "Aqlan Z", car: { kind: "new", name: "Myvi", color: "red" }, tracker: true,
    });
  });
  it("parses existingCarId", () => {
    const r = parseJoinInput({ ...base, car: { existingCarId: "c1" }, tracker: false });
    assert.deepEqual(r.car, { kind: "existing", carId: "c1" });
  });
  it("rejects bad shapes", () => {
    rejects(() => parseJoinInput(null));
    rejects(() => parseJoinInput({ ...base, car: {} }));
    rejects(() => parseJoinInput({ ...base, car: "x" }));
    rejects(() => parseJoinInput({ ...base, car: { existingCarId: "" } }));
    rejects(() => parseJoinInput({ ...base, car: { existingCarId: "a/b" } }));
    rejects(() => parseJoinInput({ ...base, car: { newCar: { name: "", color: "red" } } }));
    rejects(() => parseJoinInput({ ...base, car: { newCar: { name: "a".repeat(31), color: "red" } } }));
    rejects(() => parseJoinInput({ ...base, car: { newCar: { name: "ok", color: "c".repeat(21) } } }));
    rejects(() => parseJoinInput({ ...base, car: { newCar: { name: "ok", color: 5 } } }));
    rejects(() => parseJoinInput({ ...base, tracker: "yes" }));
    rejects(() => parseJoinInput({ ...base, displayName: " " }));
    rejects(() => parseJoinInput({ ...base, code: "nope" }));
  });
});

describe("isIdle", () => {
  const now = new Date("2026-01-02T12:00:00Z");
  const ago = (h: number) => ({ toMillis: () => now.getTime() - h * 3_600_000 });
  const trip = (over: Record<string, unknown> = {}) => ({ status: "active" as const, createdAt: ago(20), ...over });

  it("keeps a fresh trip", () => {
    assert.equal(isIdle(trip({ createdAt: ago(1) }), null, null, now), false);
  });
  it("ends an old trip with no other signals", () => {
    assert.equal(isIdle(trip(), null, null, now), true);
  });
  it("uses lastActivityAt over createdAt", () => {
    assert.equal(isIdle(trip({ lastActivityAt: ago(2) }), null, null, now), false);
    assert.equal(isIdle(trip({ lastActivityAt: ago(13) }), null, null, now), true);
  });
  it("keeps a trip with a recent position or event", () => {
    assert.equal(isIdle(trip(), { updatedAt: ago(0.1) }, null, now), false);
    assert.equal(isIdle(trip(), { updatedAt: ago(30) }, { createdAt: ago(3) }, now), false);
  });
  it("ends a trip whose position and event are old", () => {
    assert.equal(isIdle(trip(), { updatedAt: ago(15) }, { createdAt: ago(14) }, now), true);
  });
  it("is idle exactly at 12 hours and not just before", () => {
    assert.equal(isIdle(trip({ createdAt: ago(12) }), null, null, now), true);
    assert.equal(isIdle(trip({ createdAt: ago(11.99) }), null, null, now), false);
  });
  it("never touches ended trips", () => {
    assert.equal(isIdle(trip({ status: "ended" }), null, null, now), false);
  });
});

describe("shouldPurgeTripData", () => {
  const now = new Date("2026-01-20T12:00:00Z");
  const endedDaysAgo = (d: number) => ({ toMillis: () => now.getTime() - d * 86_400_000 });

  it("purges an ended trip older than 7 days", () => {
    assert.equal(shouldPurgeTripData({ status: "ended", endedAt: endedDaysAgo(8) }, now), true);
  });
  it("keeps an ended trip within 7 days, and exactly 7 days", () => {
    assert.equal(shouldPurgeTripData({ status: "ended", endedAt: endedDaysAgo(2) }, now), false);
    assert.equal(shouldPurgeTripData({ status: "ended", endedAt: endedDaysAgo(7) }, now), false);
  });
  it("never purges an active trip or one without endedAt", () => {
    assert.equal(shouldPurgeTripData({ status: "active", endedAt: endedDaysAgo(30) }, now), false);
    assert.equal(shouldPurgeTripData({ status: "ended" }, now), false);
    assert.equal(shouldPurgeTripData({ status: "ended", endedAt: null }, now), false);
  });
  it("uses the 7-day window constant", () => {
    assert.equal(POSITION_RETENTION_MS, 7 * 86_400_000);
  });
});

describe("eventExpiryCutoff", () => {
  const now = new Date("2026-01-20T12:00:00Z");
  const HOUR = 3_600_000;
  // The purge query deletes events whose expiresAt is strictly before the cutoff.
  const pastGrace = (expiresAtMs: number) => expiresAtMs < eventExpiryCutoff(now).toMillis();

  it("removes an event 2 hours past expiresAt", () => {
    assert.equal(pastGrace(now.getTime() - 2 * HOUR), true);
  });
  it("keeps an event inside the 1-hour grace period", () => {
    assert.equal(pastGrace(now.getTime() - 30 * 60_000), false);
    assert.equal(pastGrace(now.getTime() - EVENT_GRACE_MS), false);
  });
  it("keeps a future event", () => {
    assert.equal(pastGrace(now.getTime() + HOUR), false);
  });
  it("puts the cutoff one grace period before now", () => {
    assert.equal(eventExpiryCutoff(now).toMillis(), now.getTime() - EVENT_GRACE_MS);
  });
});

describe("pickCarColor", () => {
  it("keeps a free requested colour", () => assert.equal(pickCarColor("#7C3AED", ["#2563EB"]), "#7C3AED"));
  it("replaces a taken colour with the first free palette colour", () => {
    assert.equal(pickCarColor("#CC450D", ["#2563EB", "#0F766E", "#CC450D"]), "#7C3AED");
    assert.equal(pickCarColor("#cc450d", ["#2563EB", "#CC450D"]), "#0F766E");
  });
  it("cycles by car count when the palette is exhausted", () => {
    const all = ["#2563EB", "#CC450D", "#0F766E", "#7C3AED", "#BE185D", "#A16207"];
    assert.equal(pickCarColor("#2563EB", all), "#2563EB");
  });
});

describe("simplifiedRoute", () => {
  const line = Array.from({ length: 500 }, (_, i) => ({ latitude: 3 + i * 0.003, longitude: 101.7 - i * 0.001 }));
  it("starts 3 km in, and leaves the line out under 6 km", () => {
    const first = decodePolyline(simplifiedRoute(encodePolyline(line)))[0];
    const d = Math.hypot((first.latitude - 3) * 111_320, (first.longitude - 101.7) * 111_320 * Math.cos((3 * Math.PI) / 180));
    assert.ok(Math.abs(d - 3000) < 5, String(d));
    assert.equal(simplifiedRoute(encodePolyline(line.slice(0, 15))), "");
  });
  describe("never near the organiser's own start", () => {
    const HOME = { latitude: 3, longitude: 101.5 };
    const m = (a: { latitude: number; longitude: number }) =>
      Math.hypot((a.latitude - HOME.latitude) * 111_320, (a.longitude - HOME.longitude) * 111_320 * Math.cos((3 * Math.PI) / 180));
    const north = (km: number, east = 0) => ({ latitude: HOME.latitude + (km * 1000) / 111_320, longitude: HOME.longitude + east / 111_320 });
    const dense = (path: Array<{ latitude: number; longitude: number }>) => {
      const out = [path[0]];
      for (let i = 1; i < path.length; i++) {
        for (let s = 1; s <= 20; s++) {
          out.push({
            latitude: path[i - 1].latitude + ((path[i].latitude - path[i - 1].latitude) * s) / 20,
            longitude: path[i - 1].longitude + ((path[i].longitude - path[i - 1].longitude) * s) / 20,
          });
        }
      }
      return out;
    };
    it("a loop back past the start", () => {
      const loop = dense([HOME, { latitude: 3, longitude: 101.5 + 1500 / (111_320 * Math.cos((3 * Math.PI) / 180)) }, { latitude: 3 + 150 / 111_320, longitude: 101.5 }, north(10.15)]);
      const pts = decodePolyline(simplifiedRoute(encodePolyline(loop)));
      assert.ok(pts.length >= 2);
      for (const p of pts) assert.ok(m(p) > 500, String(m(p)));
    });
    it("a zigzag in the first 3.5 km", () => {
      const zig = dense([HOME, north(0.5, 300), north(0.9, -300), north(1.3, 300), north(1.7, -300), north(2.1, 300), north(2.6, -250), north(3.5), north(12)]);
      const pts = decodePolyline(simplifiedRoute(encodePolyline(zig)));
      assert.ok(pts.length >= 2);
      for (const p of pts) assert.ok(m(p) > 500, String(m(p)));
    });
    it("a straight line still starts exactly 3 km in", () => {
      const pts = decodePolyline(simplifiedRoute(encodePolyline(dense([HOME, north(10)]))));
      assert.ok(Math.abs(m(pts[0]) - 3000) < 5, String(m(pts[0])));
    });
    it("sends nothing when less than 3 km is left after the cut", () => {
      assert.equal(simplifiedRoute(encodePolyline(dense([HOME, north(5), north(0.2), north(2.5, 2000)]))), "");
    });
  });
  it("routeFrom with an offset past the end gives nothing", () => {
    assert.deepEqual(routeFrom([{ latitude: 3, longitude: 101 }, { latitude: 3.1, longitude: 101 }], 99_999), []);
  });
  it("keeps the ends, drops points on a straight line and round-trips", () => {
    const out = decodePolyline(simplifiedRoute(encodePolyline(line)));
    assert.equal(out.length, 2);
    assert.ok(Math.abs(out[1].latitude - line[499].latitude) < 1e-5);
  });
  it("keeps a corner", () => {
    const corner = [{ latitude: 3, longitude: 101 }, { latitude: 3.5, longitude: 101 }, { latitude: 3.5, longitude: 101.5 }];
    assert.equal(decodePolyline(simplifiedRoute(encodePolyline(corner))).length, 3);
  });
  it("caps the number of points", () => {
    const wiggle = Array.from({ length: 5000 }, (_, i) => ({ latitude: 3 + i * 0.0005, longitude: 101 + Math.sin(i / 7) * 0.05 }));
    assert.ok(decodePolyline(simplifiedRoute(encodePolyline(wiggle), { maxPoints: 400 })).length <= 400);
  });
  it("gives an empty line for nothing readable", () => {
    for (const bad of ["", undefined, 5, "?"]) assert.equal(simplifiedRoute(bad), "");
  });
});

describe("simplifiedRoute on a crafted route (D98)", () => {
  // A zigzag swinging up to 0.2 degrees (22 km) every point: the worst shape for Douglas-Peucker, which on 20,000
  // points took 26 s before the points were thinned.
  const zigzag = (n: number) =>
    Array.from({ length: n }, (_, i) => ({ latitude: 3 + (i % 2 ? 1 : -1) * i * 1e-5, longitude: 101 + i * 1e-4 }));
  for (const n of [5_000, 20_000, 100_000]) {
    it(`answers a ${n}-point zigzag within half a second, with at most 400 points`, () => {
      const encoded = encodePolyline(zigzag(n));
      const t = Date.now();
      const out = decodePolyline(simplifiedRoute(encoded));
      assert.ok(Date.now() - t < 500, `${Date.now() - t} ms`);
      assert.ok(out.length >= 2 && out.length <= 400, `${out.length} points`);
    });
  }
  it("thins to at most max points, keeping the first and last, for lengths around the cap", () => {
    const max = MAX_SIMPLIFY_POINTS;
    for (const n of [max, max + 1, 1_501, 2 * max, 2 * max + 1, 100_000]) {
      const pts = zigzag(n);
      const t = thin(pts, max);
      assert.ok(t.length <= max, `${n}: ${t.length}`);
      assert.equal(t[0], pts[0]);
      assert.equal(t[t.length - 1], pts[n - 1]);
    }
    // A line one over the cap loses almost nothing: it does not halve.
    assert.ok(thin(zigzag(1_501), max).length >= 1_499);
    assert.equal(thin(zigzag(100), max).length, 100);
  });
});

describe("App Check options", () => {
  it("are driven by APPCHECK_ENFORCE, which is off unless set", () => {
    assert.equal(appCheckOptions.enforceAppCheck, APPCHECK_ENFORCE);
    assert.equal(APPCHECK_ENFORCE.name, "APPCHECK_ENFORCE");
    assert.equal(APPCHECK_ENFORCE.value(), false);
  });
  it("are always off in the emulators", () => {
    assert.equal(appCheckOptionsFor({ FUNCTIONS_EMULATOR: "true" }).enforceAppCheck, false);
    assert.equal(appCheckOptionsFor({}).enforceAppCheck, APPCHECK_ENFORCE);
  });
});

// A sorted fake list standing in for the trips query: (seconds, nanos, id) order, "strictly after the cursor". The
// times carry microseconds, as real Firestore keeps them (the emulator rounds to milliseconds and hid a bug).
function fakeList(items: SweepItem<string>[], reads: string[]) {
  const sorted = [...items].sort(compareKeys);
  return async (after: SweepCursor | null, limit: number) => {
    const rest = sorted.filter((i) => !after || compareKeys(i, after) > 0).slice(0, limit);
    for (const r of rest) reads.push(r.id);
    return rest;
  };
}
const trips = (n: number): SweepItem<string>[] => Array.from({ length: n }, (_, i) => ({ id: `t${String(i).padStart(2, "0")}`, seconds: 1000, nanos: 123_456_000 + i * 1000, item: "x" }));

describe("runSweep", () => {
  const base = { pageSize: 3, outOfTime: () => false };

  it("finishes a backlog bigger than one run's cap over several runs, oldest first, never reading a finished trip again", async () => {
    const reads: string[] = [];
    const handled: string[] = [];
    const list = fakeList(trips(7), reads);
    let cursor: SweepCursor | null = null;
    const runs: boolean[] = [];
    for (let run = 0; run < 5; run++) {
      const o = await runSweep<string>({ ...base, list, cursor, maxItems: 3, handle: async (i) => { handled.push(i.id); } });
      cursor = o.cursor;
      runs.push(o.more);
      if (!o.more) break;
    }
    assert.deepEqual(handled, ["t00", "t01", "t02", "t03", "t04", "t05", "t06"]);
    assert.deepEqual(runs, [true, true, false]);
    // Each trip was fetched exactly once.
    assert.deepEqual(reads, handled);
  });

  it("a finished trip is not read again by the next run", async () => {
    const reads: string[] = [];
    const list = fakeList(trips(2), reads);
    const first = await runSweep<string>({ ...base, list, cursor: null, maxItems: 10, handle: async () => {} });
    assert.equal(first.handled, 2);
    reads.length = 0;
    const second = await runSweep<string>({ ...base, list, cursor: first.cursor, maxItems: 10, handle: async () => {} });
    assert.equal(second.handled, 0);
    assert.deepEqual(reads, []);
  });

  it("saves the cursor after each page", async () => {
    const saved: (string | null)[] = [];
    await runSweep<string>({ ...base, list: fakeList(trips(7), []), cursor: null, maxItems: 100, handle: async () => {},
      save: async (c) => { saved.push(c?.id ?? null); } });
    assert.deepEqual(saved, ["t02", "t05", "t06"]);
  });

  it("a trip that throws is counted and the sweep moves past it", async () => {
    const failedIds: string[] = [];
    const o = await runSweep<string>({ ...base, list: fakeList(trips(4), []), cursor: null, maxItems: 10,
      handle: async (i) => { if (i.id === "t01") throw new Error("boom"); }, onFailure: (id) => failedIds.push(id) });
    assert.equal(o.failed, 1);
    assert.equal(o.handled, 4);
    assert.deepEqual(failedIds, ["t01"]);
    assert.equal(o.cursor?.id, "t03");
  });

  it("stops at the time budget and keeps its place", async () => {
    let calls = 0;
    const o = await runSweep<string>({ ...base, list: fakeList(trips(6), []), cursor: null, maxItems: 100,
      outOfTime: () => calls >= 4, handle: async () => { calls++; } });
    assert.equal(o.handled, 4);
    assert.equal(o.more, true);
    assert.equal(o.cursor?.id, "t03");
  });

  it("items that share a sort time are each handled once", async () => {
    const same = ["a", "b", "c", "d"].map((id) => ({ id, seconds: 5, nanos: 123_456_789, item: "x" }));
    const handled: string[] = [];
    let cursor: SweepCursor | null = null;
    for (let i = 0; i < 4; i++) {
      const o = await runSweep<string>({ ...base, pageSize: 1, list: fakeList(same, []), cursor, maxItems: 2, handle: async (it) => { handled.push(it.id); } });
      cursor = o.cursor;
    }
    assert.deepEqual(handled, ["a", "b", "c", "d"]);
  });

  it("wrap: starts over from the beginning once the list runs dry", async () => {
    const list = fakeList(trips(3), []);
    const first = await runSweep<string>({ ...base, list, cursor: null, maxItems: 10, wrap: true, handle: async () => {} });
    assert.equal(first.handled, 3);
    const second = await runSweep<string>({ ...base, list, cursor: first.cursor, maxItems: 10, wrap: true, handle: async () => {} });
    assert.equal(second.wrapped, true);
    assert.equal(second.cursor, null);
    const handled: string[] = [];
    await runSweep<string>({ ...base, list, cursor: second.cursor, maxItems: 10, wrap: true, handle: async (i) => { handled.push(i.id); } });
    assert.deepEqual(handled, ["t00", "t01", "t02"]);
  });

  it("wrap: busy old trips at the front do not starve the ones behind them", async () => {
    // 4 trips stay busy (never ended); the cap is 2 per run. Every trip is still checked within two runs.
    const list = fakeList(trips(4), []);
    const seen = new Set<string>();
    let cursor: SweepCursor | null = null;
    for (let run = 0; run < 2; run++) {
      const o = await runSweep<string>({ ...base, list, cursor, maxItems: 2, wrap: true, handle: async (i) => { seen.add(i.id); } });
      cursor = o.cursor;
    }
    assert.equal(seen.size, 4);
  });
});

describe("runSweep: a failure that cannot be kept", () => {
  const base = { pageSize: 3, outOfTime: () => false };
  it("holds the cursor before the item and stops, so the next run meets it again", async () => {
    const handled: string[] = [];
    let full = false;
    const run = (cursor: SweepCursor | null, boom: boolean) => runSweep<string>({ ...base, list: fakeList(trips(6), []), cursor, maxItems: 100,
      handle: async (i) => { if (boom && i.id === "t02") throw new Error("boom"); handled.push(i.id); },
      onFailure: () => { full = true; }, holdOnFailure: () => full });
    const first = await run(null, true);
    assert.equal(first.more, true);
    assert.equal(first.failed, 1);
    assert.equal(first.cursor?.id, "t01");
    full = false;
    const second = await run(first.cursor, false);
    assert.deepEqual(handled, ["t00", "t01", "t02", "t03", "t04", "t05"]);
    assert.equal(second.failed, 0);
  });
});

describe("cursors", () => {
  const bound = new Timestamp(2000, 500_000_000);
  it("keep microseconds: a trip is strictly after its own cursor and before the next", () => {
    const [a, b] = trips(2);
    const saved = cursorToState({ seconds: a!.seconds, nanos: a!.nanos, id: a!.id });
    const back = cursorFromState(saved as any, "job", bound)!;
    assert.equal(compareKeys(a!, back), 0);
    assert.ok(compareKeys(b!, back) > 0);
    assert.equal(back.nanos, 123_456_000);
  });
  it("a saved place later than the query's bound is ignored", () => {
    assert.equal(cursorFromState({ cursorSeconds: 2001, cursorNanos: 0, cursorId: "x" }, "job", bound), null);
    assert.ok(cursorFromState({ cursorSeconds: 2000, cursorNanos: 499_999_000, cursorId: "x" }, "job", bound));
  });
  it("a missing, old or malformed place starts from the beginning", () => {
    assert.equal(cursorFromState({}, "job", bound), null);
    assert.equal(cursorFromState({ cursorMs: 5, cursorId: "x" } as any, "job", bound), null);
    assert.equal(cursorFromState({ cursorSeconds: 5, cursorNanos: -1, cursorId: "x" }, "job", bound), null);
    assert.equal(cursorFromState({ cursorSeconds: 5, cursorNanos: 1.5, cursorId: "x" }, "job", bound), null);
  });
});

describe("guess limit", () => {
  const NOW = 1_000_000_000_000;
  const MIN = 60_000;
  const at = (...minsAgo: number[]) => minsAgo.map((m) => NOW - m * MIN).sort((a, b) => a - b);

  it("allows up to 9 misses in 10 minutes, blocks the 10th try after 10", () => {
    assert.equal(waitMs(at(1, 2, 3, 4, 5, 6, 7, 8, 9), NOW), 0);
    assert.ok(waitMs(at(1, 2, 3, 4, 5, 6, 7, 8, 9, 9.5), NOW) > 0);
  });
  it("the wait is until the oldest relevant miss leaves the window", () => {
    // 10 misses, the oldest 8 minutes ago: free again in 2 minutes.
    assert.equal(waitMs(at(8, 7, 6, 5, 4, 3, 2, 1, 0.5, 0.2), NOW), 2 * MIN);
  });
  it("misses older than 10 minutes do not count toward the window", () => {
    assert.equal(waitMs(at(11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21), NOW), 0);
  });
  it("50 misses in a day block even when spread out, until the oldest is a day old", () => {
    const spread = Array.from({ length: 50 }, (_, i) => NOW - (i * 25 + 1) * MIN).sort((a, b) => a - b);
    assert.ok(spread.every((t) => t > NOW - DAY_MS));
    const w = waitMs(spread, NOW);
    assert.equal(w, spread[0]! + DAY_MS - NOW);
    assert.equal(waitMs(spread.slice(1), NOW), 0);
  });
  it("misses a day old or older expire; malformed entries and future times are ignored", () => {
    const data = { misses: [NOW - DAY_MS, NOW - DAY_MS - 5, NOW - 5, "x", null, NOW + 10 * MIN, NaN] };
    assert.deepEqual(recentMisses(data, NOW), [NOW - 5]);
    assert.deepEqual(recentMisses(undefined, NOW), []);
  });
  it("the error is resource-exhausted, plain, carries a retry hint and is not the trip-full text", () => {
    const e = tooManyTries(3 * MIN + 1);
    assert.equal(e.code, "resource-exhausted");
    assert.match(e.message, /^Too many wrong codes\. Wait 4 minutes and try again\.$/);
    assert.deepEqual(e.details, { reason: "too-many-guesses", retryAfterSeconds: 181 });
    assert.match(tooManyTries(1000).message, /Wait a minute/);
    assert.ok(!/full|cars/i.test(e.message));
  });
});

describe("createTrip codes (D108)", () => {
  it("a code is 6 characters of the app's alphabet, whatever the random number", () => {
    for (const r of [0, 0.5, 0.999999]) {
      const c = generateCode(() => r);
      assert.equal(c.length, CODE_LENGTH);
      assert.ok([...c].every((ch) => CODE_ALPHABET.includes(ch)), c);
    }
    assert.equal(generateCode(() => 0), "AAAAAA");
    assert.ok(!/[OIL01]/.test(CODE_ALPHABET));
    assert.equal(CODE_ALPHABET.length, 31);
  });
  it("the default draw does not use Math.random (its state leaks from codes handed out)", () => {
    const real = Math.random;
    Math.random = () => 0;
    try {
      const codes = new Set(Array.from({ length: 20 }, () => generateCode()));
      assert.ok(!codes.has("AAAAAA") && codes.size > 15, [...codes].join());
    } finally {
      Math.random = real;
    }
  });
  it("real draws are 6 characters from the alphabet and not all the same", () => {
    const seen = new Set(Array.from({ length: 50 }, () => generateCode()));
    assert.ok(seen.size > 40);
    for (const c of seen) assert.match(c, /^[A-HJKMNP-Z2-9]{6}$/);
  });
});

describe("parseCreateInput (D108)", () => {
  const ok = { name: "Trip to Ipoh", destination: { name: "Ipoh", latitude: 4.6, longitude: 101.1 }, route: "_p~iF~ps|U", routeSeconds: 600, organizerName: "  Sam  ", carId: "car1" };
  it("takes a well-formed request and trims the organizer's name", () => {
    const r = parseCreateInput(ok);
    assert.equal(r.organizerName, "Sam");
    assert.equal(r.routeSeconds, 600);
    assert.equal(parseCreateInput({ ...ok, routeSeconds: undefined }).routeSeconds, undefined);
    assert.equal(parseCreateInput({ ...ok, name: "" }).name, "");
  });
  it("holds the caps the rules had: name 200, destination 300, route 200,000", () => {
    parseCreateInput({ ...ok, name: "x".repeat(200), route: "x".repeat(200_000), destination: { ...ok.destination, name: "x".repeat(300) } });
    rejects(() => parseCreateInput({ ...ok, name: "x".repeat(201) }));
    rejects(() => parseCreateInput({ ...ok, route: "x".repeat(200_001) }));
    rejects(() => parseCreateInput({ ...ok, destination: { ...ok.destination, name: "x".repeat(301) } }));
  });
  it("counts the organizer's name in characters, as the app does: 30 emoji pass, 31 do not", () => {
    parseCreateInput({ ...ok, organizerName: "😀".repeat(30) });
    rejects(() => parseCreateInput({ ...ok, organizerName: "😀".repeat(31) }));
  });
  it("refuses a bad place, time, name or car id", () => {
    rejects(() => parseCreateInput(null));
    rejects(() => parseCreateInput({ ...ok, destination: { ...ok.destination, latitude: 91 } }));
    rejects(() => parseCreateInput({ ...ok, destination: { name: "x", latitude: "1", longitude: 1 } }));
    rejects(() => parseCreateInput({ ...ok, routeSeconds: -1 }));
    rejects(() => parseCreateInput({ ...ok, organizerName: "   " }));
    rejects(() => parseCreateInput({ ...ok, organizerName: "a".repeat(31) }));
    rejects(() => parseCreateInput({ ...ok, carId: "a/b" }));
    rejects(() => parseCreateInput({ ...ok, carId: "" }));
  });
});

describe("create limit (D108)", () => {
  const NOW = 10 * CREATE_DAY_MS;
  const MIN = 60_000;
  it("20 an hour pass, the 21st waits until the oldest is an hour old", () => {
    const times = Array.from({ length: MAX_PER_HOUR }, (_, i) => NOW - (50 - i) * MIN);
    assert.equal(createWaitMs(times.slice(1), NOW), 0);
    assert.equal(createWaitMs(times, NOW), times[0]! + HOUR_MS - NOW);
  });
  it("50 in a day wait for the day cap even when the hour is quiet", () => {
    const spread = Array.from({ length: MAX_PER_DAY }, (_, i) => NOW - (i * 25 + 61) * MIN).sort((a, b) => a - b);
    assert.ok(spread.every((t) => t > NOW - CREATE_DAY_MS));
    assert.equal(createWaitMs(spread, NOW), spread[0]! + CREATE_DAY_MS - NOW);
    assert.equal(createWaitMs(spread.slice(1), NOW), 0);
  });
  it("the emulator gets much looser limits; production keeps 20 and 50", () => {
    assert.deepEqual(limitsFor({ FUNCTIONS_EMULATOR: "true" }), EMULATOR_LIMITS);
    assert.deepEqual(limitsFor({}), PRODUCTION_LIMITS);
    assert.deepEqual(PRODUCTION_LIMITS, { perHour: 20, perDay: 50 });
    assert.ok(EMULATOR_LIMITS.perHour >= 1000 && EMULATOR_LIMITS.perDay >= 5000);
    const times = Array.from({ length: 100 }, (_, i) => NOW - (i + 1) * MIN);
    assert.ok(createWaitMs(times, NOW, PRODUCTION_LIMITS) > 0);
    assert.equal(createWaitMs(times, NOW, EMULATOR_LIMITS), 0);
  });
  it("old, malformed and future entries are ignored", () => {
    assert.deepEqual(recentCreates({ creates: [NOW - CREATE_DAY_MS, NOW - 5, "x", NOW + 10 * MIN] }, NOW), [NOW - 5]);
  });
  it("the error is resource-exhausted, plain, with a retry hint", () => {
    const e = tooManyTrips(3 * MIN + 1);
    assert.equal(e.code, "resource-exhausted");
    assert.match(e.message, /^Too many new trips\. Wait 4 minutes and try again\.$/);
    assert.deepEqual(e.details, { reason: "too-many-trips", retryAfterSeconds: 181 });
  });
});

// The same fixture and numbers are in ios/ikutTests/RecapTests.swift (RecapLogic.routeDistance): change both or neither.
const KL_IPOH_ROUTE = "wadRcvskRgthBbr_@_urDn~rA";
const KL_IPOH_METERS = 175813.34114927656;
const ANTIMERIDIAN_ROUTE = "?_v_ia@?~l`scA";
const ANTIMERIDIAN_METERS = 22239.016046705317;

describe("routeDistanceMeters (mirrors RecapLogic.routeDistance)", () => {
  it("gives the Swift number for the same route", () => {
    assert.ok(Math.abs(routeDistanceMeters(KL_IPOH_ROUTE)! - KL_IPOH_METERS) < 1e-6);
  });
  it("wraps longitude across 180 like the Swift haversine", () => {
    assert.ok(Math.abs(routeDistanceMeters(ANTIMERIDIAN_ROUTE)! - ANTIMERIDIAN_METERS) < 1e-6);
  });
  it("is null for no route, one point, or a truncated string (never a partial distance)", () => {
    assert.equal(routeDistanceMeters(""), null);
    assert.equal(routeDistanceMeters("_p~iF~ps|U"), null);
    assert.equal(routeDistanceMeters(KL_IPOH_ROUTE.slice(0, -1)), null);
    assert.equal(routeDistanceMeters("\u0001bad"), null);
  });
});

describe("summaryDurationSeconds", () => {
  const t = (s: number) => ({ toMillis: () => s * 1000 }) as never;
  it("counts from the first Start Trip when there was one, else from creation", () => {
    assert.equal(summaryDurationSeconds({ createdAt: t(0), startedAt: t(1000), endedAt: t(4600) }), 3600);
    assert.equal(summaryDurationSeconds({ createdAt: t(0), endedAt: t(4600) }), 4600);
  });
  it("is null when the end is not after the start, or there is no end", () => {
    assert.equal(summaryDurationSeconds({ createdAt: t(10), endedAt: t(10) }), null);
    assert.equal(summaryDurationSeconds({ createdAt: t(10) }), null);
  });
});

describe("shouldDeleteTrip", () => {
  const now = new Date("2026-12-01T00:00:00Z");
  const ended = (ms: number) => ({ status: "ended" as const, endedAt: { toMillis: () => now.getTime() - ms } });
  it("is 90 days, not 7", () => {
    assert.equal(TRIP_RETENTION_MS, 90 * 24 * 3600 * 1000);
    assert.equal(shouldDeleteTrip(ended(TRIP_RETENTION_MS + 1), now), true);
    assert.equal(shouldDeleteTrip(ended(89 * 24 * 3600 * 1000), now), false);
    assert.equal(shouldDeleteTrip(ended(POSITION_RETENTION_MS + 1), now), false);
  });
  it("never an active trip or an ended trip without endedAt", () => {
    assert.equal(shouldDeleteTrip({ status: "active", endedAt: { toMillis: () => 0 } }, now), false);
    assert.equal(shouldDeleteTrip({ status: "ended" }, now), false);
  });
});
