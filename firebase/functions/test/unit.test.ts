import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { isIdle } from "../src/idle.ts";
import { EVENT_GRACE_MS, POSITION_RETENTION_MS, isEventPastGrace, shouldPurgeTripData } from "../src/retention.ts";
import { decodePolyline, encodePolyline, routeFrom, simplifiedRoute } from "../src/previewRoute.ts";
import { normalizeCode, normalizeName, parseJoinInput, pickCarColor } from "../src/joinTrip.ts";

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

describe("isEventPastGrace", () => {
  const now = new Date("2026-01-20T12:00:00Z");
  const at = (ms: number) => ({ toMillis: () => now.getTime() + ms });
  const HOUR = 3_600_000;

  it("removes an event 2 hours past expiresAt", () => {
    assert.equal(isEventPastGrace({ expiresAt: at(-2 * HOUR) }, now), true);
  });
  it("keeps an event inside the 1-hour grace period", () => {
    assert.equal(isEventPastGrace({ expiresAt: at(-30 * 60_000) }, now), false);
    assert.equal(isEventPastGrace({ expiresAt: at(-EVENT_GRACE_MS) }, now), false);
  });
  it("keeps a future event and one without expiresAt", () => {
    assert.equal(isEventPastGrace({ expiresAt: at(HOUR) }, now), false);
    assert.equal(isEventPastGrace({}, now), false);
  });
});

describe("pickCarColor", () => {
  it("keeps a free requested colour", () => assert.equal(pickCarColor("#7C3AED", ["#2563EB"]), "#7C3AED"));
  it("replaces a taken colour with the first free palette colour", () => {
    assert.equal(pickCarColor("#D9480F", ["#2563EB", "#0F766E", "#D9480F"]), "#7C3AED");
    assert.equal(pickCarColor("#d9480f", ["#2563EB", "#D9480F"]), "#0F766E");
  });
  it("cycles by car count when the palette is exhausted", () => {
    const all = ["#2563EB", "#D9480F", "#0F766E", "#7C3AED", "#BE185D", "#A16207"];
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
