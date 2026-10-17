// Run via `npm run test:emulator` (inside firebase emulators:exec).
import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { initializeApp } from "firebase-admin/app";
import { FieldValue, GeoPoint, getFirestore } from "firebase-admin/firestore";

const PROJECT = "ikut-b1083";
process.env.FIRESTORE_EMULATOR_HOST ??= "127.0.0.1:8080";
const app = initializeApp({ projectId: PROJECT }, "test");
const db = getFirestore(app);

async function newUser(): Promise<{ uid: string; token: string }> {
  const res = await fetch("http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ returnSecureToken: true }),
  });
  const j = (await res.json()) as { localId: string; idToken: string };
  return { uid: j.localId, token: j.idToken };
}

interface CallResult { status: number; body: any }
async function call(data: unknown, token?: string): Promise<CallResult> {
  const res = await fetch(`http://127.0.0.1:5001/${PROJECT}/asia-southeast1/joinTrip`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ data }),
  });
  return { status: res.status, body: await res.json() };
}

let codeCounter = 0;
function freshCode(): string {
  const n = (Date.now() + codeCounter++).toString(36).toUpperCase().padStart(6, "0");
  return n.slice(-6);
}

async function seedTrip(opts: { status?: "active" | "ended" } = {}) {
  const code = freshCode();
  const organizerId = "org-" + code;
  const tripRef = db.collection("trips").doc();
  await tripRef.set({
    name: "T", code, organizerId, route: "", destination: { name: "D", coordinate: new GeoPoint(1, 1) },
    status: opts.status ?? "active", createdAt: FieldValue.serverTimestamp(),
  });
  const carRef = tripRef.collection("cars").doc("lead");
  await carRef.set({ name: "Lead", color: "blue", isLead: true, state: "joining", trackerUserId: organizerId });
  await tripRef.collection("members").doc(organizerId).set({ displayName: "Org", carId: "lead", role: "organizer" });
  return { code, tripRef, organizerId };
}

const newCar = (name = "Myvi") => ({ newCar: { name, color: "red" } });

describe("joinTrip (emulator)", () => {
  let user: { uid: string; token: string };
  before(async () => { user = await newUser(); });

  it("joins with a new car and claims tracker", async () => {
    const { code, tripRef } = await seedTrip();
    const before = (await tripRef.get()).data()!;
    assert.equal(before.lastActivityAt, undefined);
    const r = await call({ code: code.toLowerCase(), displayName: "  Sam  ", car: newCar(), tracker: true }, user.token);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const { tripId, carId, trackerTaken } = r.body.result;
    assert.equal(tripId, tripRef.id);
    assert.equal(trackerTaken, false);
    const car = (await tripRef.collection("cars").doc(carId).get()).data()!;
    assert.deepEqual(car, { name: "Myvi", color: "red", isLead: false, state: "joining", trackerUserId: user.uid });
    const member = (await tripRef.collection("members").doc(user.uid).get()).data()!;
    assert.deepEqual(member, { displayName: "Sam", carId, role: "member" });
    assert.ok((await tripRef.get()).data()!.lastActivityAt);
  });

  it("new car without tracker has no trackerUserId", async () => {
    const { code, tripRef } = await seedTrip();
    const r = await call({ code, displayName: "Sam", car: newCar(), tracker: false }, user.token);
    const car = (await tripRef.collection("cars").doc(r.body.result.carId).get()).data()!;
    assert.equal("trackerUserId" in car, false);
  });

  it("joins an existing car with free tracker", async () => {
    const { code, tripRef } = await seedTrip();
    await tripRef.collection("cars").doc("c2").set({ name: "Car2", color: "green", isLead: false, state: "joining" });
    const r = await call({ code, displayName: "Sam", car: { existingCarId: "c2" }, tracker: true }, user.token);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.result, { tripId: tripRef.id, carId: "c2", trackerTaken: false });
    assert.equal((await tripRef.collection("cars").doc("c2").get()).data()!.trackerUserId, user.uid);
  });

  it("tracker already taken: still joins, trackerTaken true", async () => {
    const { code, tripRef, organizerId } = await seedTrip();
    const r = await call({ code, displayName: "Sam", car: { existingCarId: "lead" }, tracker: true }, user.token);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.result.trackerTaken, true);
    assert.equal((await tripRef.collection("cars").doc("lead").get()).data()!.trackerUserId, organizerId);
    assert.equal((await tripRef.collection("members").doc(user.uid).get()).data()!.carId, "lead");
  });

  it("existing car must belong to the trip", async () => {
    const { code } = await seedTrip();
    const r = await call({ code, displayName: "Sam", car: { existingCarId: "nope" }, tracker: false }, user.token);
    assert.equal(r.body.error.status, "INVALID_ARGUMENT");
  });

  it("joining twice is idempotent and updates name and car", async () => {
    const { code, tripRef } = await seedTrip();
    const a = await call({ code, displayName: "Sam", car: { existingCarId: "lead" }, tracker: false }, user.token);
    assert.equal(a.status, 200);
    const b = await call({ code, displayName: "Samuel", car: { existingCarId: "lead" }, tracker: false }, user.token);
    assert.equal(b.status, 200, JSON.stringify(b.body));
    assert.equal((await tripRef.collection("members").get()).size, 2);
    const m = (await tripRef.collection("members").doc(user.uid).get()).data()!;
    assert.equal(m.displayName, "Samuel");
    assert.equal(m.role, "member");
    // switch to a new car, claiming tracker; no duplicate member
    const c = await call({ code, displayName: "Samuel", car: newCar("Alza"), tracker: true }, user.token);
    assert.equal(c.status, 200, JSON.stringify(c.body));
    assert.equal((await tripRef.collection("members").get()).size, 2);
    assert.equal((await tripRef.collection("members").doc(user.uid).get()).data()!.carId, c.body.result.carId);
  });

  it("moving out of a car leaves no empty car behind", async () => {
    const { code, tripRef } = await seedTrip();
    const a = await call({ code, displayName: "Sam", car: newCar("Myvi"), tracker: true }, user.token);
    const b = await call({ code, displayName: "Sam", car: newCar("Alza"), tracker: true }, user.token);
    assert.equal(b.status, 200, JSON.stringify(b.body));
    assert.equal((await tripRef.collection("cars").doc(a.body.result.carId).get()).exists, false);
    assert.equal((await tripRef.collection("cars").get()).size, 2);
    // Leaving for the lead car still removes the empty one.
    const c = await call({ code, displayName: "Sam", car: { existingCarId: "lead" }, tracker: false }, user.token);
    assert.equal(c.status, 200, JSON.stringify(c.body));
    assert.equal((await tripRef.collection("cars").doc(b.body.result.carId).get()).exists, false);
  });

  it("moving out of a shared car keeps it and releases tracker", async () => {
    const { code, tripRef } = await seedTrip();
    const other = await newUser();
    const a = await call({ code, displayName: "Sam", car: newCar("Myvi"), tracker: true }, user.token);
    await call({ code, displayName: "Ali", car: { existingCarId: a.body.result.carId }, tracker: false }, other.token);
    await call({ code, displayName: "Sam", car: newCar("Alza"), tracker: true }, user.token);
    const old = (await tripRef.collection("cars").doc(a.body.result.carId).get()).data();
    assert.ok(old, "shared car should remain");
    assert.equal(old.trackerUserId, undefined);
  });

  it("the lead car is never removed", async () => {
    const { code, tripRef, organizerId } = await seedTrip();
    await tripRef.collection("members").doc(organizerId).update({ carId: "elsewhere" });
    await call({ code, displayName: "Sam", car: { existingCarId: "lead" }, tracker: false }, user.token);
    await call({ code, displayName: "Sam", car: newCar(), tracker: false }, user.token);
    assert.ok((await tripRef.collection("cars").doc("lead").get()).exists);
  });

  it("re-join keeps tracker claim on same car", async () => {
    const { code } = await seedTrip();
    const a = await call({ code, displayName: "Sam", car: newCar(), tracker: true }, user.token);
    const b = await call({ code, displayName: "Sam", car: { existingCarId: a.body.result.carId }, tracker: true }, user.token);
    assert.equal(b.body.result.trackerTaken, false);
  });

  it("rejects bad code format", async () => {
    const r = await call({ code: "ab", displayName: "Sam", car: newCar(), tracker: false }, user.token);
    assert.equal(r.status, 400);
    assert.equal(r.body.error.status, "INVALID_ARGUMENT");
  });

  it("unknown code is not-found", async () => {
    const r = await call({ code: "ZZZZZZ", displayName: "Sam", car: newCar(), tracker: false }, user.token);
    assert.equal(r.status, 404);
    assert.equal(r.body.error.message, "No active trip with that code");
  });

  it("ended trip is not joinable", async () => {
    const { code } = await seedTrip({ status: "ended" });
    const r = await call({ code, displayName: "Sam", car: newCar(), tracker: false }, user.token);
    assert.equal(r.body.error.status, "NOT_FOUND");
  });

  it("duplicate active codes are failed-precondition", async () => {
    const { code } = await seedTrip();
    await db.collection("trips").add({ name: "dup", code, organizerId: "x", status: "active" });
    const r = await call({ code, displayName: "Sam", car: newCar(), tracker: false }, user.token);
    assert.equal(r.body.error.status, "FAILED_PRECONDITION");
  });

  it("unauthenticated is rejected", async () => {
    const { code } = await seedTrip();
    const r = await call({ code, displayName: "Sam", car: newCar(), tracker: false });
    assert.equal(r.status, 401);
    assert.equal(r.body.error.status, "UNAUTHENTICATED");
  });

  it("member cap of 20", async () => {
    const { code, tripRef } = await seedTrip();
    const batch = db.batch();
    for (let i = 0; i < 19; i++) {
      batch.set(tripRef.collection("members").doc(`m${i}`), { displayName: `M${i}`, carId: "lead", role: "member" });
    }
    await batch.commit();
    const r = await call({ code, displayName: "Sam", car: { existingCarId: "lead" }, tracker: false }, user.token);
    assert.equal(r.body.error.status, "RESOURCE_EXHAUSTED");
    assert.equal((await tripRef.collection("members").doc(user.uid).get()).exists, false);
  });

  it("existing member can rejoin a full trip", async () => {
    const { code, tripRef } = await seedTrip();
    const batch = db.batch();
    for (let i = 0; i < 18; i++) {
      batch.set(tripRef.collection("members").doc(`m${i}`), { displayName: `M${i}`, carId: "lead", role: "member" });
    }
    batch.set(tripRef.collection("members").doc(user.uid), { displayName: "Sam", carId: "lead", role: "member" });
    await batch.commit();
    const r = await call({ code, displayName: "Sam2", car: { existingCarId: "lead" }, tracker: false }, user.token);
    assert.equal(r.status, 200, JSON.stringify(r.body));
  });

  it("car cap of 10", async () => {
    const { code, tripRef } = await seedTrip();
    const batch = db.batch();
    for (let i = 0; i < 9; i++) {
      batch.set(tripRef.collection("cars").doc(`k${i}`), { name: `K${i}`, color: "red", isLead: false, state: "joining" });
    }
    await batch.commit();
    const r = await call({ code, displayName: "Sam", car: newCar(), tracker: false }, user.token);
    assert.equal(r.body.error.status, "RESOURCE_EXHAUSTED");
    const ok = await call({ code, displayName: "Sam", car: { existingCarId: "k0" }, tracker: false }, user.token);
    assert.equal(ok.status, 200);
  });
});

async function callFn(fn: string, data: unknown, token?: string): Promise<CallResult> {
  const res = await fetch(`http://127.0.0.1:5001/${PROJECT}/asia-southeast1/${fn}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ data }),
  });
  return { status: res.status, body: await res.json() };
}

describe("previewTrip (emulator)", () => {
  let user: { uid: string; token: string };
  before(async () => { user = await newUser(); });

  it("returns trip name, destination and cars without personal data", async () => {
    const { code, tripRef, organizerId } = await seedTrip();
    await tripRef.collection("cars").doc("second").set({ name: "Alpha", color: "green", isLead: false, state: "joining" });
    const r = await callFn("previewTrip", { code: ` ${code.toLowerCase().slice(0, 3)}-${code.slice(3)} ` }, user.token);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.result, {
      tripId: tripRef.id,
      name: "T",
      destinationName: "D",
      cars: [
        { id: "lead", name: "Lead", color: "blue", hasTracker: true },
        { id: "second", name: "Alpha", color: "green", hasTracker: false },
      ],
    });
    assert.ok(!JSON.stringify(r.body).includes(organizerId));
  });

  it("previews, then joins the previewed car", async () => {
    const { code, tripRef } = await seedTrip();
    const p = await callFn("previewTrip", { code }, user.token);
    const car = p.body.result.cars[0];
    const j = await call({ code, displayName: "Sam", car: { existingCarId: car.id }, tracker: car.hasTracker }, user.token);
    assert.equal(j.status, 200, JSON.stringify(j.body));
    assert.equal(j.body.result.tripId, p.body.result.tripId);
    assert.equal(j.body.result.carId, car.id);
    assert.equal(j.body.result.trackerTaken, true);
    assert.ok((await tripRef.collection("members").doc(user.uid).get()).exists);
  });

  it("rejects unknown and ended trips with not-found", async () => {
    const unknown = await callFn("previewTrip", { code: "ZZZZZZ" }, user.token);
    assert.equal(unknown.status, 404);
    assert.equal(unknown.body.error.status, "NOT_FOUND");
    const { code } = await seedTrip({ status: "ended" });
    const ended = await callFn("previewTrip", { code }, user.token);
    assert.equal(ended.body.error.status, "NOT_FOUND");
  });

  it("rejects bad codes and signed-out callers", async () => {
    const bad = await callFn("previewTrip", { code: "abc" }, user.token);
    assert.equal(bad.body.error.status, "INVALID_ARGUMENT");
    const anon = await callFn("previewTrip", { code: "ABCDEF" });
    assert.equal(anon.body.error.status, "UNAUTHENTICATED");
  });
});
