import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { normalizeCode, normalizeName, parseJoinInput } from "../src/joinTrip.ts";

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
