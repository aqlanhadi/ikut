// Run via `npm run test:emulator` (inside firebase emulators:exec).
import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { initializeApp } from "firebase-admin/app";
import { FieldValue, GeoPoint, Timestamp, getFirestore } from "firebase-admin/firestore";

import { endIdleTrips } from "../lib/endIdleTrips.js";
import { purgeTripData } from "../lib/retention.js";
import { cleanupAfterMemberLeft } from "../lib/memberCleanup.js";

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
  await carRef.set({ name: "Lead", color: "blue", isLead: true, state: "joining", trackerUserId: organizerId, number: 1 });
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
    assert.deepEqual(car, { name: "Myvi", color: "red", isLead: false, state: "joining", number: 2, trackerUserId: user.uid });
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

  it("new cars get the next badge number", async () => {
    const { code, tripRef } = await seedTrip();
    const other = await newUser();
    const a = await call({ code, displayName: "Sam", car: newCar("Myvi"), tracker: true }, user.token);
    const b = await call({ code, displayName: "Ali", car: newCar("Alza"), tracker: true }, other.token);
    const num = async (id: string) => (await tripRef.collection("cars").doc(id).get()).data()!.number;
    assert.equal(await num(a.body.result.carId), 2);
    assert.equal(await num(b.body.result.carId), 3);
  });

  it("rejoining with a new car repeatedly does not climb the badge number", async () => {
    const { code, tripRef } = await seedTrip();
    let carId = "";
    for (let i = 0; i < 3; i++) {
      const r = await call({ code, displayName: "Sam", car: newCar(`Car ${i}`), tracker: true }, user.token);
      assert.equal(r.status, 200, JSON.stringify(r.body));
      carId = r.body.result.carId;
    }
    // Only the lead car (1) and the member's current car exist; each old car was deleted.
    assert.equal((await tripRef.collection("cars").get()).size, 2);
    assert.equal((await tripRef.collection("cars").doc(carId).get()).data()!.number, 2);
  });

  it("leaving a shared car for a new car keeps the shared car and gives max + 1", async () => {
    const { code, tripRef } = await seedTrip();
    const other = await newUser();
    const a = await call({ code, displayName: "Sam", car: newCar("Myvi"), tracker: true }, user.token);
    await call({ code, displayName: "Ali", car: { existingCarId: a.body.result.carId }, tracker: false }, other.token);
    const b = await call({ code, displayName: "Sam", car: newCar("Alza"), tracker: true }, user.token);
    assert.equal(b.status, 200, JSON.stringify(b.body));
    const shared = (await tripRef.collection("cars").doc(a.body.result.carId).get()).data();
    assert.equal(shared?.number, 2);
    assert.equal((await tripRef.collection("cars").doc(b.body.result.carId).get()).data()!.number, 3);
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
        { id: "lead", name: "Lead", color: "blue", hasTracker: true, number: 1 },
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

describe("endIdleTrips (emulator)", () => {
  const NOW = new Date();
  const hoursAgo = (h: number) => Timestamp.fromMillis(NOW.getTime() - h * 3_600_000);

  async function seedAged(opts: {
    status?: "active" | "ended";
    createdH: number;
    lastActivityH?: number;
    positionH?: number;
    eventH?: number;
  }) {
    const code = freshCode();
    const tripRef = db.collection("trips").doc();
    await tripRef.set({
      name: "T", code, organizerId: "org-" + code, route: "",
      destination: { name: "D", coordinate: new GeoPoint(1, 1) },
      status: opts.status ?? "active", createdAt: hoursAgo(opts.createdH),
      ...(opts.lastActivityH !== undefined ? { lastActivityAt: hoursAgo(opts.lastActivityH) } : {}),
    });
    if (opts.positionH !== undefined) {
      await tripRef.collection("positions").doc("lead").set({
        location: new GeoPoint(1, 1), speed: 0, heading: 0, routeOffset: 0, updatedAt: hoursAgo(opts.positionH),
      });
      // An older position from a second car must not matter.
      await tripRef.collection("positions").doc("other").set({
        location: new GeoPoint(1, 1), speed: 0, heading: 0, routeOffset: 0, updatedAt: hoursAgo(opts.positionH + 30),
      });
    }
    if (opts.eventH !== undefined) {
      await tripRef.collection("events").doc().set({ type: "message", category: "message", createdAt: hoursAgo(opts.eventH) });
    }
    return tripRef;
  }
  const status = async (ref: FirebaseFirestore.DocumentReference) => (await ref.get()).data()!;

  it("keeps a fresh trip", async () => {
    const ref = await seedAged({ createdH: 1 });
    await endIdleTrips(db, NOW);
    assert.equal((await status(ref)).status, "active");
  });

  it("keeps an old trip with a recent position", async () => {
    const ref = await seedAged({ createdH: 30, lastActivityH: 20, positionH: 0.1 });
    await endIdleTrips(db, NOW);
    assert.equal((await status(ref)).status, "active");
  });

  it("keeps an old trip with a recent event", async () => {
    const ref = await seedAged({ createdH: 30, positionH: 20, eventH: 2 });
    await endIdleTrips(db, NOW);
    assert.equal((await status(ref)).status, "active");
  });

  it("ends an old trip with old positions", async () => {
    const ref = await seedAged({ createdH: 30, lastActivityH: 20, positionH: 15, eventH: 16 });
    await endIdleTrips(db, NOW);
    const d = await status(ref);
    assert.equal(d.status, "ended");
    assert.ok(d.endedAt instanceof Timestamp);
  });

  it("handles a trip without lastActivityAt", async () => {
    const old = await seedAged({ createdH: 30 });
    const recent = await seedAged({ createdH: 30, positionH: 1 });
    await endIdleTrips(db, NOW);
    assert.equal((await status(old)).status, "ended");
    assert.equal((await status(recent)).status, "active");
  });

  it("leaves an already ended trip untouched", async () => {
    const ref = await seedAged({ status: "ended", createdH: 40 });
    const before = await ref.get();
    await endIdleTrips(db, NOW);
    const after = await ref.get();
    assert.equal(after.updateTime!.isEqual(before.updateTime!), true);
    assert.equal(after.data()!.endedAt, undefined);
  });

  it("is idempotent", async () => {
    const ref = await seedAged({ createdH: 30 });
    await endIdleTrips(db, NOW);
    const first = (await status(ref)).endedAt;
    await endIdleTrips(db, NOW);
    assert.ok((await status(ref)).endedAt.isEqual(first));
  });
});

describe("purgeTripData (emulator)", () => {
  const NOW = new Date();
  const at = (hours: number) => Timestamp.fromMillis(NOW.getTime() - hours * 3_600_000);
  const point = new GeoPoint(1, 1);

  async function seedRetentionTrip(opts: { status: "active" | "ended"; endedH?: number }) {
    const code = freshCode();
    const tripRef = db.collection("trips").doc();
    await tripRef.set({
      name: "T", code, organizerId: "org-" + code, route: "",
      destination: { name: "D", coordinate: point },
      status: opts.status, createdAt: at(400),
      ...(opts.endedH !== undefined ? { endedAt: at(opts.endedH) } : {}),
    });
    await tripRef.collection("positions").doc("lead").set({
      location: point, speed: 0, heading: 0, routeOffset: 0, updatedAt: at(1),
    });
    return tripRef;
  }
  async function addEvent(tripRef: FirebaseFirestore.DocumentReference, id: string, expiresAt?: Timestamp) {
    await tripRef.collection("events").doc(id).set({
      type: "message", category: "message", severity: "low", location: point, heading: 0, routeOffset: 0,
      authorId: "x", carId: "lead", createdAt: at(1), ...(expiresAt ? { expiresAt } : {}),
    });
  }

  it("deletes positions and events of a trip ended 8 days ago, keeps the trip doc", async () => {
    const ref = await seedRetentionTrip({ status: "ended", endedH: 24 * 8 });
    await addEvent(ref, "e1");
    const before = (await ref.get()).data()!;
    await purgeTripData(db, NOW);
    assert.equal((await ref.collection("positions").get()).size, 0);
    assert.equal((await ref.collection("events").get()).size, 0);
    const after = await ref.get();
    assert.equal(after.exists, true);
    assert.equal(after.data()!.status, "ended");
    assert.ok(after.data()!.endedAt.isEqual(before.endedAt));
  });

  it("keeps a trip ended 2 days ago intact", async () => {
    const ref = await seedRetentionTrip({ status: "ended", endedH: 24 * 2 });
    await addEvent(ref, "e1");
    await purgeTripData(db, NOW);
    assert.equal((await ref.collection("positions").get()).size, 1);
    assert.equal((await ref.collection("events").get()).size, 1);
    assert.equal((await ref.get()).data()!.status, "ended");
  });

  it("deletes an active trip's event that expired 2 hours ago", async () => {
    const ref = await seedRetentionTrip({ status: "active" });
    await addEvent(ref, "expired", at(2));
    await purgeTripData(db, NOW);
    assert.equal((await ref.collection("events").doc("expired").get()).exists, false);
    assert.equal((await ref.collection("positions").get()).size, 1);
    assert.equal((await ref.get()).data()!.status, "active");
  });

  it("keeps a non-expired event and an event without expiresAt", async () => {
    const ref = await seedRetentionTrip({ status: "active" });
    await addEvent(ref, "future", Timestamp.fromMillis(NOW.getTime() + 3_600_000));
    await addEvent(ref, "forever");
    await purgeTripData(db, NOW);
    assert.equal((await ref.collection("events").doc("future").get()).exists, true);
    assert.equal((await ref.collection("events").doc("forever").get()).exists, true);
  });
});

describe("member cleanup (emulator)", () => {
  const point = new GeoPoint(1, 1);

  // Each trip gets an auto-generated id, so tests never collide with other suites or agents.
  async function seedCleanupTrip(status: "active" | "ended" = "active") {
    const code = freshCode();
    const tripRef = db.collection("trips").doc();
    await tripRef.set({
      name: "T", code, organizerId: "org", route: "", destination: { name: "D", coordinate: point },
      status, createdAt: FieldValue.serverTimestamp(),
    });
    await tripRef.collection("cars").doc("lead").set({ name: "Lead", color: "blue", isLead: true, state: "joining", number: 1, trackerUserId: "org" });
    await tripRef.collection("members").doc("org").set({ displayName: "Org", carId: "lead", role: "organizer" });
    return tripRef;
  }
  async function addCar(tripRef: FirebaseFirestore.DocumentReference, carId: string, trackerUserId?: string) {
    await tripRef.collection("cars").doc(carId).set({
      name: carId, color: "green", isLead: false, state: "joining", number: 2,
      ...(trackerUserId ? { trackerUserId } : {}),
    });
    await tripRef.collection("positions").doc(carId).set({ location: point, speed: 0, heading: 0, routeOffset: 0, updatedAt: FieldValue.serverTimestamp() });
  }
  async function addMember(tripRef: FirebaseFirestore.DocumentReference, uid: string, carId: string) {
    await tripRef.collection("members").doc(uid).set({ displayName: uid, carId, role: "member" });
  }
  /**
   * Calls cleanup directly with the leaver's data. The member doc is deliberately NOT deleted here:
   * deleting it would also fire the real onMemberDeleted trigger and race these assertions.
   * cleanupAfterMemberLeft ignores the leaver's own doc when counting riders, so this matches the trigger.
   */
  async function leave(tripRef: FirebaseFirestore.DocumentReference, uid: string) {
    const removed = (await tripRef.collection("members").doc(uid).get()).data() as { carId: string };
    return cleanupAfterMemberLeft(db, tripRef.id, uid, removed);
  }

  it("last member leaves a non-lead car: car and position deleted", async () => {
    const ref = await seedCleanupTrip();
    await addCar(ref, "c2", "m1");
    await addMember(ref, "m1", "c2");
    const outcome = await leave(ref, "m1");
    assert.deepEqual(outcome, { kind: "deleted" });
    assert.equal((await ref.collection("cars").doc("c2").get()).exists, false);
    assert.equal((await ref.collection("positions").doc("c2").get()).exists, false);
    assert.equal((await ref.collection("cars").doc("lead").get()).exists, true);
  });

  it("member leaves a shared car they tracked: car kept, tracker released", async () => {
    const ref = await seedCleanupTrip();
    await addCar(ref, "c2", "m1");
    await addMember(ref, "m1", "c2");
    await addMember(ref, "m2", "c2");
    const outcome = await leave(ref, "m1");
    assert.deepEqual(outcome, { kind: "kept", trackerReleased: true });
    const car = (await ref.collection("cars").doc("c2").get()).data()!;
    assert.equal("trackerUserId" in car, false);
    assert.equal((await ref.collection("positions").doc("c2").get()).exists, true);
    assert.equal((await ref.collection("members").doc("m2").get()).data()!.carId, "c2");
  });

  it("member leaves a shared car they did not track: car untouched", async () => {
    const ref = await seedCleanupTrip();
    await addCar(ref, "c2", "m2");
    await addMember(ref, "m1", "c2");
    await addMember(ref, "m2", "c2");
    const before = (await ref.collection("cars").doc("c2").get()).data()!;
    const outcome = await leave(ref, "m1");
    assert.deepEqual(outcome, { kind: "kept", trackerReleased: false });
    assert.deepEqual((await ref.collection("cars").doc("c2").get()).data(), before);
    assert.equal((await ref.collection("positions").doc("c2").get()).exists, true);
  });

  it("last member leaves the lead car: car kept", async () => {
    const ref = await seedCleanupTrip();
    const outcome = await leave(ref, "org");
    assert.deepEqual(outcome, { kind: "kept", trackerReleased: true });
    const lead = await ref.collection("cars").doc("lead").get();
    assert.equal(lead.exists, true);
    assert.equal("trackerUserId" in lead.data()!, false);
  });

  it("ended trip: nothing changes", async () => {
    const ref = await seedCleanupTrip("ended");
    await addCar(ref, "c2", "m1");
    await addMember(ref, "m1", "c2");
    const before = (await ref.collection("cars").doc("c2").get()).data()!;
    const outcome = await leave(ref, "m1");
    assert.deepEqual(outcome, { kind: "skipped", reason: "trip-not-active" });
    assert.deepEqual((await ref.collection("cars").doc("c2").get()).data(), before);
    assert.equal((await ref.collection("positions").doc("c2").get()).exists, true);
  });

  it("trigger fires when a member doc is deleted in the functions emulator", async () => {
    const ref = await seedCleanupTrip();
    await addCar(ref, "c9", "m9");
    await addMember(ref, "m9", "c9");
    await ref.collection("members").doc("m9").delete();
    const carRef = ref.collection("cars").doc("c9");
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline && (await carRef.get()).exists) {
      await new Promise((r) => setTimeout(r, 250));
    }
    assert.equal((await carRef.get()).exists, false, "car c9 still exists 5s after member delete");
    assert.equal((await ref.collection("positions").doc("c9").get()).exists, false);
  });
});
