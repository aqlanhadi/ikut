// Smoke test of what a phone on main's build does in the field test, against the real Firebase project
// (or, with --emulators, the local emulators): an organizer creates a trip with a planned meeting point, a second
// person previews it, joins by code and answers the stop, the organizer starts (a participant's Start is refused),
// marks arrival and leaves, both write a position, and the organizer ends the trip.
// The ended trip is purged by purgeTripDataJob after the retention window.
//
//   node prod-smoke.mjs                 # production: ios/ikut/Resources/GoogleService-Info.plist
//   node prod-smoke.mjs --emulators     # Auth :9099, Firestore :8080, Functions :5001 (project ikut-b1083, as convoy-sim)
//
// Every write mirrors the app's, field for field (the Swift file:line is on each step and in qa/README.md):
// TripService.createTrip / write(stops), StopAnswerService, StopLeaveService, TripService.markStarted, JoinService,
// TripSession.endTrip.

import { PROJECT_ID, productionFirebaseConfig } from './lib/firebase-config.mjs';
import { initializeApp, deleteApp } from 'firebase/app';
import { connectAuthEmulator, getAuth, signInAnonymously, deleteUser } from 'firebase/auth';
import {
  GeoPoint, Timestamp, collection, connectFirestoreEmulator, deleteDoc, doc, getDoc, initializeFirestore, serverTimestamp,
  setDoc, terminate, updateDoc, writeBatch,
} from 'firebase/firestore';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { endsWithResult } from './lib/shell.mjs';
import { generateCode } from './lib/scenario.mjs';
import { Polyline, destinationPoint, haversine } from './lib/route.mjs';

const emulators = process.argv.includes('--emulators');
const config = emulators ? { apiKey: 'qa-fake-key', projectId: PROJECT_ID, appId: 'prod-smoke' } : productionFirebaseConfig();

const REGION = 'asia-southeast1';

let failures = 0;
const check = (ok, label, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ` (${detail})` : ''}`);
  if (!ok) failures++;
};

const end = endsWithResult({ deadlineS: 300, signals: true });
const clients = []; // every signed-in client, so cleanup reaches them whatever fails
async function client(name) {
  const app = initializeApp(config, name);
  const auth = getAuth(app);
  const db = initializeFirestore(app, {});
  const fns = getFunctions(app, REGION);
  if (emulators) {
    connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
    connectFirestoreEmulator(db, '127.0.0.1', 8080);
    connectFunctionsEmulator(fns, '127.0.0.1', 5001);
  }
  const cred = await signInAnonymously(auth);
  const c = { app, auth, uid: cred.user.uid, db, fns };
  clients.push(c);
  return c;
}

/** A step that must work: PASS or FAIL under its own label, and a failure stops the run (cleanup still runs). */
async function step(label, fn) {
  try {
    const detail = await fn();
    check(true, label, detail ?? '');
  } catch (e) {
    check(false, label, e.code ?? e.message);
    throw e;
  }
}

/** A write the rules must refuse (an expected denial): PASS only on permission-denied. */
async function mustBeDenied(label, fn) {
  try {
    await fn();
    check(false, label, 'it went through');
  } catch (e) {
    check(e.code === 'permission-denied', label, e.code ?? e.message);
  }
}

const code = generateCode();
console.log(`${emulators ? 'EMULATORS, ' : ''}project ${config.projectId}, trip code ${code}`);

// A 30 km line going north from the organiser's start, a point every km; the meeting point is the 8th (8 km in), so
// the preview's route starts there, not at the organiser's start.
const START = { latitude: 3.8, longitude: 101.2 };
const points = Array.from({ length: 31 }, (_, i) => destinationPoint(START, 0, i * 1000));
const route = Polyline.encode(points);
const MEET_OFFSET = 8000;
const meet = points[8];
const destination = points[30];

let org;
let guest;
let tripRef = null;
let tripMade = false;
let started = false;
let ended = false;
let stopRef = null;
let answerRef = null;
let answerMade = false;
try {
  org = await client('smoke-organizer');
  check(Boolean(org.uid), 'organizer signed in anonymously');

  // TripService.createTrip (ios/ikut/Trip/TripService.swift:72-107, makeTrip :43-56): the trip with routeSeconds and
  // the organizer's member in one batch, then the car.
  tripRef = doc(collection(org.db, 'trips'));
  const carRef = doc(collection(org.db, `trips/${tripRef.id}/cars`));
  await step('Create trip (name, code, route, routeSeconds, member) as the app writes it', async () => {
    const batch = writeBatch(org.db);
    batch.set(tripRef, {
      name: 'Trip to Ipoh', code, organizerId: org.uid, route,
      destination: { name: 'Ipoh', coordinate: new GeoPoint(destination.latitude, destination.longitude) },
      routeSeconds: 1834.5, status: 'active', createdAt: serverTimestamp(),
    });
    // makeOrganizerMember (:58-60)
    batch.set(doc(org.db, `trips/${tripRef.id}/members/${org.uid}`), { displayName: 'Smoke Org', carId: carRef.id, role: 'organizer' });
    await batch.commit();
    tripMade = true;
    return tripRef.id;
  });
  // makeOrganizerCar (:62-66), written second because the rules need the member first (:101-105)
  await step('Create the organizer car (lead, convoy, number 1)', () =>
    setDoc(carRef, { name: "Smoke Org's car", color: '#2563EB', trackerUserId: org.uid, isLead: true, state: 'convoy', number: 1 }));

  // TripService.write (:166-196, called by saveStops :140): in the lobby the route, routeSeconds, stopCount and the
  // stops go in one batch. PlannedStop (ios/ikut/Model/PlannedStop.swift) encodes the meeting point without minutes.
  stopRef = doc(collection(org.db, `trips/${tripRef.id}/stops`));
  const meetAt = new Date(Date.now() + 2 * 3600 * 1000);
  await step('Plan the meeting stop (stopCount 1, meet stop with coordinate and meetAt)', async () => {
    const batch = writeBatch(org.db);
    batch.update(tripRef, { route, routeSeconds: 1834.5, stopCount: 1 });
    batch.set(stopRef, {
      name: 'Meeting point', coordinate: new GeoPoint(meet.latitude, meet.longitude), routeOffset: MEET_OFFSET,
      kind: 'meet', meetAt: Timestamp.fromDate(meetAt), order: 0,
    });
    await batch.commit();
  });

  // JoinService.preview (ios/ikut/Join/JoinService.swift, TripPreview at :1-60) through the previewTrip callable
  guest = await client('smoke-guest');
  const preview = (await httpsCallable(guest.fns, 'previewTrip')({ code })).data;
  check(preview.tripId === tripRef.id && preview.cars?.length === 1, 'previewTrip finds the trip by code', `${preview.cars?.length} car(s)`);
  check(preview.organizerName === 'Smoke', 'previewTrip gives the organiser\'s first name', String(preview.organizerName));
  const previewLine = typeof preview.route === 'string' && preview.route ? Polyline.decode(preview.route) : [];
  check(previewLine.length >= 2 && haversine(previewLine[0], meet) < 10 && haversine(previewLine[0], START) > 1000,
    'previewTrip route starts at the meeting point, not the organiser\'s start',
    previewLine.length ? `first point ${haversine(previewLine[0], meet).toFixed(0)} m from the meeting point, ${haversine(previewLine[0], START).toFixed(0)} m from the start` : 'no route');
  const pm = preview.stops?.find((x) => x.kind === 'meet');
  check(Boolean(pm) && Math.abs(pm.coordinate?.latitude - meet.latitude) < 1e-4 && Math.abs(pm.coordinate?.longitude - meet.longitude) < 1e-4
    && Math.abs(pm.meetAt - meetAt.getTime()) < 1000 && pm.minutes === undefined,
    'previewTrip lists the meeting stop with its coordinate and meetAt', pm ? `meetAt ${pm.meetAt}` : 'no meet stop');

  // JoinService.join (the joinTrip callable)
  const joined = (await httpsCallable(guest.fns, 'joinTrip')({
    code, displayName: 'Smoke Guest', car: { newCar: { name: "Smoke Guest's car", color: '#D9480F' } }, tracker: true,
  })).data;
  const guestCar = await getDoc(doc(guest.db, `trips/${tripRef.id}/cars/${joined.carId}`));
  check(joined.tripId === tripRef.id && guestCar.data()?.number === 2, 'joinTrip adds a second car numbered 2', `number ${guestCar.data()?.number}`);

  // PositionWriter (ios/ikut/Tracking/TrackingTypes.swift, FirestorePositionWriter)
  for (const [c, carId, lat] of [[org, carRef.id, 4.10], [guest, joined.carId, 4.09]]) {
    await setDoc(doc(c.db, `trips/${tripRef.id}/positions/${carId}`), {
      location: new GeoPoint(lat, 101.2), speed: 25, heading: 0, routeOffset: 1000, convoyOffset: 1000, updatedAt: serverTimestamp(),
    });
  }
  const pos = await getDoc(doc(org.db, `trips/${tripRef.id}/positions/${joined.carId}`));
  check(pos.exists(), "organizer reads the guest's position");

  // Only the organiser can start (D39): TripService.markStarted (:122-125) from a participant is refused.
  await mustBeDenied("a participant's Start is refused (expected denial)", () =>
    updateDoc(doc(guest.db, `trips/${tripRef.id}`), { startedAt: serverTimestamp() }));
  await step('organizer starts the trip (startedAt)', async () => {
    await updateDoc(tripRef, { startedAt: serverTimestamp() });
    started = true;
  });

  // StopAnswerService.skip (ios/ikut/Stops/StopAnswerService.swift:12-19): the second car, still joining, skips the meeting point.
  answerRef = doc(guest.db, `trips/${tripRef.id}/stops/${stopRef.id}/answers/${joined.carId}`);
  await step("second car answers the meeting stop (skip, userId, at)", async () => {
    await setDoc(answerRef, { answer: 'skip', userId: guest.uid, at: serverTimestamp() });
    answerMade = true;
  });
  const seen = await getDoc(doc(org.db, `trips/${tripRef.id}/stops/${stopRef.id}/answers/${joined.carId}`));
  check(seen.exists() && seen.data().answer === 'skip', "organizer reads the second car's answer");

  // StopLeaveService.markArrived / leave (ios/ikut/Stops/StopLeaveService.swift:20-24, :12-16): lead car or organizer only.
  await mustBeDenied("a participant's Leave is refused (expected denial)", () =>
    updateDoc(doc(guest.db, `trips/${tripRef.id}/stops/${stopRef.id}`), { leftAt: serverTimestamp(), leftBy: guest.uid }));
  await step('organizer marks the lead car at the stop (arrivedAt)', () =>
    updateDoc(doc(org.db, `trips/${tripRef.id}/stops/${stopRef.id}`), { arrivedAt: serverTimestamp() }));
  await step('organizer taps Leave (leftAt, leftBy)', () =>
    updateDoc(doc(org.db, `trips/${tripRef.id}/stops/${stopRef.id}`), { leftAt: serverTimestamp(), leftBy: org.uid }));

  // StopAnswerService.undo (:22-26): the car takes its answer back (a delete of its own answer).
  await step("second car takes its answer back (undo)", async () => {
    await deleteDoc(answerRef);
    answerMade = false;
  });

  // TripSession.endTrip
  await updateDoc(tripRef, { status: 'ended', endedAt: serverTimestamp() });
  ended = true;
  check((await getDoc(tripRef)).data()?.status === 'ended', 'organizer ends the trip');
} catch (e) {
  if (!failures) check(false, 'the smoke test ran to the end', e.code ?? e.message);
} finally {
  // Whatever failed above: take the guest's answer back if it is still there, delete the stop if the trip has not
  // started (the rules refuse it after), end the trip if it was made, then delete both anonymous users.
  // The stop doc stays after the trip ends, as in the app; purgeTripDataJob clears its traces (D35 X1) after the
  // retention window, and any answer left by a failed run.
  if (answerMade) {
    await deleteDoc(answerRef).then(() => console.log('took the answer back during cleanup'), (e) => check(false, 'cleanup could not delete the answer', e.code ?? e.message));
  }
  if (stopRef && tripMade && !started) {
    await deleteDoc(doc(org.db, `trips/${tripRef.id}/stops/${stopRef.id}`)).catch(() => {});
  }
  if (tripMade && !ended) {
    await updateDoc(tripRef, { status: 'ended', endedAt: serverTimestamp() })
      .then(() => console.log('ended the trip during cleanup'), (e) => check(false, 'cleanup could not end the trip', e.code ?? e.message));
  }
  for (const c of [...clients].reverse()) {
    await terminate(c.db).catch(() => {});
    await deleteUser(c.auth.currentUser).catch(() => {});
    await deleteApp(c.app).catch(() => {});
  }
}
if (failures) console.log(`\n${failures} check(s) failed`);
end.result(failures === 0);
process.exit(failures ? 1 : 0);
