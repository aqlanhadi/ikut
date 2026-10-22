// Smoke test against the real Firebase project (not the emulators): an organizer creates a trip,
// a second person previews and joins it by code, both write a position, and the organizer ends it.
// The ended trip is purged by purgeTripDataJob after the retention window.
//
//   node prod-smoke.mjs            # uses ios/ikut/Resources/GoogleService-Info.plist
//
// Mirrors TripService.createTrip, JoinService (previewTrip/joinTrip) and TripSession.endTrip.

import { productionFirebaseConfig } from './lib/firebase-config.mjs';
import { initializeApp, deleteApp } from 'firebase/app';
import { getAuth, signInAnonymously, deleteUser } from 'firebase/auth';
import {
  GeoPoint, collection, doc, getDoc, initializeFirestore, serverTimestamp, setDoc, terminate, updateDoc, writeBatch,
} from 'firebase/firestore';
import { getFunctions, httpsCallable } from 'firebase/functions';

const config = productionFirebaseConfig();
const REGION = 'asia-southeast1';
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // TripService.codeAlphabet

let failures = 0;
const check = (ok, label, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ` (${detail})` : ''}`);
  if (!ok) failures++;
};

async function client(name) {
  const app = initializeApp(config, name);
  const auth = getAuth(app);
  const cred = await signInAnonymously(auth);
  return { app, auth, uid: cred.user.uid, db: initializeFirestore(app, {}), fns: getFunctions(app, REGION) };
}

const code = Array.from({ length: 6 }, () => ALPHABET[Math.floor(Math.random() * ALPHABET.length)]).join('');
console.log(`project ${config.projectId}, trip code ${code}`);

const org = await client('smoke-organizer');
check(Boolean(org.uid), 'organizer signed in anonymously');

// TripService.createTrip
const tripRef = doc(collection(org.db, 'trips'));
const carRef = doc(collection(org.db, `trips/${tripRef.id}/cars`));
const batch = writeBatch(org.db);
batch.set(tripRef, {
  name: 'Smoke test', code, organizerId: org.uid, route: '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
  destination: { name: 'Ipoh', coordinate: new GeoPoint(4.5975, 101.0901) },
  status: 'active', createdAt: serverTimestamp(),
});
batch.set(doc(org.db, `trips/${tripRef.id}/members/${org.uid}`), { displayName: 'Smoke Org', carId: carRef.id, role: 'organizer' });
await batch.commit();
await setDoc(carRef, { name: "Smoke Org's car", color: '#2563EB', trackerUserId: org.uid, isLead: true, state: 'convoy', number: 1 });
check(true, 'trip, member and car created', tripRef.id);

const guest = await client('smoke-guest');
const preview = await httpsCallable(guest.fns, 'previewTrip')({ code });
check(preview.data.tripId === tripRef.id && preview.data.cars?.length === 1, 'previewTrip finds the trip by code',
  `${preview.data.cars?.length} car(s)`);

const joined = await httpsCallable(guest.fns, 'joinTrip')({
  code, displayName: 'Smoke Guest', car: { newCar: { name: "Smoke Guest's car", color: '#D9480F' } }, tracker: true,
});
const guestCar = await getDoc(doc(guest.db, `trips/${tripRef.id}/cars/${joined.data.carId}`));
check(joined.data.tripId === tripRef.id && guestCar.data()?.number === 2, 'joinTrip adds a second car numbered 2',
  `number ${guestCar.data()?.number}`);

for (const [c, carId, lat] of [[org, carRef.id, 4.10], [guest, joined.data.carId, 4.09]]) {
  await setDoc(doc(c.db, `trips/${tripRef.id}/positions/${carId}`), {
    location: new GeoPoint(lat, 101.2), speed: 25, heading: 0, routeOffset: 1000, convoyOffset: 1000, updatedAt: serverTimestamp(),
  });
}
const pos = await getDoc(doc(org.db, `trips/${tripRef.id}/positions/${joined.data.carId}`));
check(pos.exists(), "organizer reads the guest's position");

// TripSession.endTrip
await updateDoc(tripRef, { status: 'ended', endedAt: serverTimestamp() });
check((await getDoc(tripRef)).data()?.status === 'ended', 'organizer ends the trip');

for (const c of [guest, org]) {
  await terminate(c.db);
  await deleteUser(c.auth.currentUser).catch(() => {});
  await deleteApp(c.app);
}
console.log(failures ? `\nRESULT: FAIL (${failures} check(s) failed)` : '\nRESULT: PASS');
process.exit(failures ? 1 : 0);
