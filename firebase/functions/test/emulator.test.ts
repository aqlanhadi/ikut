// Run via `npm run test:emulator` (inside firebase emulators:exec).
import assert from "node:assert/strict";
import { before, describe, it } from "node:test";
import { initializeApp } from "firebase-admin/app";
import { FieldValue, GeoPoint, Timestamp, getFirestore } from "firebase-admin/firestore";

import { endIdleTrips } from "../lib/endIdleTrips.js";
import { purgeTripData } from "../lib/retention.js";
import { cleanupAfterMemberLeft } from "../lib/memberCleanup.js";
import { previewTripData } from "../lib/previewTrip.js";
import { decodePolyline, encodePolyline } from "../lib/previewRoute.js";

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
async function callFn(fn: string, data: unknown, token?: string): Promise<CallResult> {
  const res = await fetch(`http://127.0.0.1:5001/${PROJECT}/asia-southeast1/${fn}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ data }),
  });
  return { status: res.status, body: await res.json() };
}
const call = (data: unknown, token?: string) => callFn("joinTrip", data, token);

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

  it("never gives two cars the same colour", async () => {
    const { code, tripRef } = await seedTrip();
    await tripRef.collection("cars").doc("c2").set({ name: "Car2", color: "#D9480F", isLead: false, state: "joining", number: 2 });
    const r = await call({ code, displayName: "Sam", car: { newCar: { name: "Dup", color: "#d9480f" } }, tracker: false }, user.token);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const car = (await tripRef.collection("cars").doc(r.body.result.carId).get()).data()!;
    assert.equal(car.color, "#2563EB");
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
      destinationCoordinate: { latitude: 1, longitude: 1 },
      organizerName: "Org",
      cars: [
        { id: "lead", name: "Lead", color: "blue", hasTracker: true, number: 1 },
        { id: "second", name: "Alpha", color: "green", hasTracker: false },
      ],
    });
    assert.ok(!JSON.stringify(r.body).includes(organizerId));
  });

  it("gives the destination coordinate, the organiser's first name and the simplified main route", async () => {
    const { tripRef, organizerId } = await seedTrip();
    await tripRef.collection("members").doc(organizerId).set({ displayName: "Aqlan Nor Azman", carId: "lead", role: "organizer" });
    // 200 points on a nearly straight line KL to Ipoh: simplifies to far fewer, ends kept.
    const pts = Array.from({ length: 200 }, (_, i) => ({ latitude: 3.139 + (i / 199) * 1.4585, longitude: 101.6869 - (i / 199) * 0.5968 + (i % 2) * 0.00001 }));
    const full = encodePolyline(pts);
    await tripRef.update({ route: full, destination: { name: "Ipoh", coordinate: new GeoPoint(4.5975, 101.0901) } });
    const r = await previewTripData(db, tripRef.id);
    assert.deepEqual(r.destinationCoordinate, { latitude: 4.5975, longitude: 101.0901 });
    assert.equal(r.organizerName, "Aqlan");
    const line = decodePolyline(r.route!);
    assert.ok(line.length >= 2 && line.length < 20, String(line.length));
    assert.ok(line[0].latitude > 3.139 + 0.02 && Math.abs(line[line.length - 1].latitude - 4.5975) < 1e-4);
    assert.ok(r.route!.length < full.length);
    assert.ok(!JSON.stringify(r).includes("Nor Azman"));
  });

  describe("where the route line starts", () => {
    const HOME = { latitude: 3.0, longitude: 101.5 };
    // Straight north from HOME, 0.001 deg (about 111 m) a step, 100 steps: about 11 km.
    const line = (steps: number) => Array.from({ length: steps + 1 }, (_, i) => ({ latitude: HOME.latitude + i * 0.001, longitude: HOME.longitude }));
    const meters = (a: { latitude: number; longitude: number }, b: { latitude: number; longitude: number }) => Math.abs(a.latitude - b.latitude) * 111_320;

    it("starts 3 km in when there is no meeting point, and nowhere near the organiser's start", async () => {
      const { tripRef } = await seedTrip();
      await tripRef.update({ route: encodePolyline(line(100)) });
      const pts = decodePolyline((await previewTripData(db, tripRef.id)).route!);
      assert.ok(Math.abs(meters(pts[0], HOME) - 3000) < 5, String(meters(pts[0], HOME)));
      for (const p of pts) assert.ok(meters(p, HOME) > 500);
    });

    for (const left of [false, true]) {
      it(`starts at the meeting point${left ? " even after it was left" : ""}`, async () => {
        const { tripRef } = await seedTrip();
        await tripRef.update({ route: encodePolyline(line(100)) });
        // Maps snaps the start to a road, a few tens of metres off the line's first vertex.
        const meet = new GeoPoint(3.0002, 101.5003);
        await tripRef.collection("stops").doc("m").set({
          name: "Petronas", kind: "meet", coordinate: meet, routeOffset: 0, order: 0, meetAt: Timestamp.now(),
          ...(left ? { leftAt: Timestamp.now(), leftBy: "someone" } : {}),
        });
        const pts = decodePolyline((await previewTripData(db, tripRef.id)).route!);
        assert.deepEqual(pts[0], { latitude: meet.latitude, longitude: meet.longitude });
      });
    }

    it("has no route when the whole line is under 6 km", async () => {
      const { tripRef } = await seedTrip();
      await tripRef.update({ route: encodePolyline(line(45)) });
      assert.ok(!("route" in (await previewTripData(db, tripRef.id))));
    });
  });

  it("has no organiserName or route when the trip has neither", async () => {
    const { tripRef } = await seedTrip();
    await tripRef.collection("members").doc("org-" + (await tripRef.get()).data()!.code).delete();
    const r = await previewTripData(db, tripRef.id);
    assert.ok(!("organizerName" in r));
    assert.ok(!("route" in r));
  });

  it("sends nothing of a member's start, own route, position, phone or ids, for a trip that has all of them", async () => {
    const { tripRef, organizerId } = await seedTrip();
    const MAIN = encodePolyline([{ latitude: 3.14, longitude: 101.69 }, { latitude: 3.5, longitude: 101.5 }, { latitude: 4.6, longitude: 101.09 }]);
    const OWN = encodePolyline([{ latitude: 2.9, longitude: 101.8 }, { latitude: 3.0, longitude: 101.75 }, { latitude: 3.3, longitude: 101.6 }]);
    await tripRef.update({ route: MAIN });
    await tripRef.collection("members").doc(organizerId).set({ displayName: "Aqlan Z", carId: "lead", role: "organizer", pushToken: "PUSH-ORG-SECRET" });
    await tripRef.collection("members").doc("member-uid-77").set({ displayName: "Siti Bakar", carId: "second", role: "member", pushToken: "PUSH-MEMBER-SECRET" });
    await tripRef.collection("cars").doc("second").set({
      name: "Bezza", color: "green", isLead: false, state: "driving", trackerUserId: "member-uid-77", number: 2,
      route: OWN, joinOffset: 31337, startName: "SIRI-HOME-AT-SEREMBAN",
    });
    await tripRef.collection("positions").doc("second").set({ location: new GeoPoint(2.7123, 101.9321), speed: 20, heading: 90, routeOffset: 4242, updatedAt: Timestamp.now() });
    await tripRef.collection("stops").doc("s").set({ name: "Petronas Jalan Duta", kind: "meet", coordinate: new GeoPoint(3.17, 101.68), routeOffset: 0, order: 0, meetAt: Timestamp.fromMillis(1_800_000_000_000), note: "private note" });
    const r = await previewTripData(db, tripRef.id);
    assert.deepEqual(r.stops, [{ name: "Petronas Jalan Duta", kind: "meet", coordinate: { latitude: 3.17, longitude: 101.68 }, meetAt: 1_800_000_000_000 }]);
    const json = JSON.stringify(r);
    for (const secret of [
      OWN, "member-uid-77", organizerId, "PUSH-ORG-SECRET", "PUSH-MEMBER-SECRET", "Siti", "Bakar", "SIRI-HOME", "31337", "4242",
      "2.7123", "101.9321", "trackerUserId", "private note", "positions", "joinOffset", "pushToken",
    ]) {
      assert.ok(!json.includes(secret), secret);
    }
    assert.ok(json.includes(encodePolyline(decodePolyline(r.route!))), "main route present");
    assert.deepEqual(Object.keys(r).sort(), ["cars", "destinationCoordinate", "destinationName", "name", "organizerName", "route", "stops", "tripId"]);
    assert.deepEqual(r.cars.map((c) => Object.keys(c).sort()), [["color", "hasTracker", "id", "name", "number"], ["color", "hasTracker", "id", "name", "number"]]);
  });

  it("lists the planned stops in order as name, kind and minutes only, without skipped ones", async () => {
    const { tripRef } = await seedTrip();
    const meetAt = Timestamp.fromMillis(1_800_000_000_000);
    // Doc ids sort opposite to `order` (Firestore returns by id), so this fails without the sort.
    const stop = (order: number, name: string, extra: object = {}) => ({
      name, kind: "fuel", coordinate: new GeoPoint(4.2, 101.2), routeOffset: 1000 * (order + 1), order, ...extra,
    });
    await tripRef.collection("stops").doc("y").set(stop(1, "R&R Tapah", { minutes: 20, note: "ask for Sam", kind: "food" }));
    await tripRef.collection("stops").doc("z").set(stop(0, "Petronas SB", { meetAt, kind: "meet" }));
    await tripRef.collection("stops").doc("x").set(stop(2, "Skipped one", { skipped: true, skippedBy: "someone", skippedAt: Timestamp.now() }));
    await tripRef.collection("stops").doc("w").set(stop(3, "Kuala Kangsar", { minutes: 10, kind: "toilet" }));
    await tripRef.collection("stops").doc("v").set(stop(4, "Left one", { leftAt: Timestamp.now(), leftBy: "someone" }));
    const r = await previewTripData(db, tripRef.id);
    assert.deepEqual(r.stops, [
      { name: "Petronas SB", kind: "meet", coordinate: { latitude: 4.2, longitude: 101.2 }, meetAt: meetAt.toMillis() },
      { name: "R&R Tapah", kind: "food", minutes: 20, coordinate: { latitude: 4.2, longitude: 101.2 } },
      { name: "Kuala Kangsar", kind: "toilet", minutes: 10, coordinate: { latitude: 4.2, longitude: 101.2 } },
    ]);
    const json = JSON.stringify(r);
    for (const secret of ["Left one", "routeOffset", "note", "skipped", "order", "ask for Sam"]) {
      assert.ok(!json.includes(secret), secret);
    }
  });

  it("has no stops field when the trip has none", async () => {
    const { tripRef } = await seedTrip();
    const r = await previewTripData(db, tripRef.id);
    assert.ok(!("stops" in r));
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

  it("clears arrivedAt, leftAt and leftBy on an old trip's stops and deletes the skip answers, keeping the stops", async () => {
    const ref = await seedRetentionTrip({ status: "ended", endedH: 24 * 8 });
    const stop = (name: string, extra: object = {}) => ({
      name, kind: "fuel", coordinate: point, routeOffset: 1000, minutes: 20, order: 0, ...extra,
    });
    await ref.collection("stops").doc("left").set(stop("R&R Tapah", { arrivedAt: at(200), leftAt: at(199), leftBy: "u1" }));
    await ref.collection("stops").doc("plain").set(stop("Kopitiam", { order: 1 }));
    await ref.collection("stops").doc("skipped").set(stop("Skipped", { order: 2, skipped: true, skippedBy: "org", skippedAt: at(200) }));
    await ref.collection("stops/left/answers").doc("carB").set({ answer: "skip", userId: "u2", at: at(200) });
    const result = await purgeTripData(db, NOW);
    assert.ok(result.failed === 0);
    const left = (await ref.collection("stops").doc("left").get()).data()!;
    for (const f of ["arrivedAt", "leftAt", "leftBy"]) assert.equal(f in left, false, f);
    assert.equal(left.name, "R&R Tapah");
    assert.equal(left.kind, "fuel");
    // A stop with none of the three is untouched and does not fail the sweep.
    assert.equal((await ref.collection("stops").doc("plain").get()).data()!.name, "Kopitiam");
    assert.equal((await ref.collection("stops").doc("skipped").get()).data()!.skipped, true);
    assert.equal((await ref.collection("stops/left/answers").get()).size, 0);
    // A second sweep finds nothing more to do.
    const again = await purgeTripData(db, NOW);
    assert.equal(again.stopsCleared, 0);
  });

  it("keeps the leave times and skip answers of a trip ended 2 days ago", async () => {
    const ref = await seedRetentionTrip({ status: "ended", endedH: 24 * 2 });
    await ref.collection("stops").doc("left").set({
      name: "R&R", kind: "fuel", coordinate: point, routeOffset: 1000, order: 0, leftAt: at(5), leftBy: "u1",
    });
    await ref.collection("stops/left/answers").doc("carB").set({ answer: "skip", userId: "u2", at: at(5) });
    await purgeTripData(db, NOW);
    assert.equal((await ref.collection("stops").doc("left").get()).data()!.leftBy, "u1");
    assert.equal((await ref.collection("stops/left/answers").get()).size, 1);
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

  it("deletes the stop votes under an ended trip's event and under an expired event on an active trip", async () => {
    const ended = await seedRetentionTrip({ status: "ended", endedH: 24 * 8 });
    await addEvent(ended, "stop1");
    await ended.collection("events/stop1/votes").doc("carA").set({ userId: "u1", at: at(200) });
    await ended.collection("events/stop1/votes").doc("carB").set({ userId: "u2", at: at(200) });
    const active = await seedRetentionTrip({ status: "active" });
    await addEvent(active, "stop2", at(2));
    await active.collection("events/stop2/votes").doc("carA").set({ userId: "u1", at: at(3) });
    await addEvent(active, "stop3", Timestamp.fromMillis(NOW.getTime() + 3_600_000));
    await active.collection("events/stop3/votes").doc("carA").set({ userId: "u1", at: at(1) });
    const result = await purgeTripData(db, NOW);
    assert.equal(result.failed, 0);
    assert.equal((await ended.collection("events/stop1/votes").get()).size, 0);
    assert.equal((await active.collection("events/stop2/votes").get()).size, 0);
    assert.ok(result.votes >= 3);
    // A live event keeps its votes.
    assert.equal((await active.collection("events/stop3/votes").get()).size, 1);
  });

  it("deletes votes whose event doc is already gone, on a trip ended 8 days ago", async () => {
    const ref = await seedRetentionTrip({ status: "ended", endedH: 24 * 8 });
    await ref.collection("events/gone/votes").doc("carA").set({ userId: "u1", at: at(200) });
    const result = await purgeTripData(db, NOW);
    assert.equal(result.failed, 0);
    assert.equal((await ref.collection("events/gone/votes").get()).size, 0);
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
