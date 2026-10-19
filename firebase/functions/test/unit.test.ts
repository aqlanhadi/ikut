import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { isIdle } from "../src/idle.ts";
import { EVENT_GRACE_MS, POSITION_RETENTION_MS, isEventPastGrace, shouldPurgeTripData } from "../src/retention.ts";
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
