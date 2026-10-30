import { after, before, beforeEach, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
  assertFails as assertFailsRaw,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  Timestamp,
  GeoPoint,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
  updateDoc,
  writeBatch,
} from 'firebase/firestore';

// Every denial must be a real "no", not the emulator giving up at 1000 expressions (a denial by
// exhaustion hides a rule that is too big and could flip to allow-or-deny by accident).
async function assertFails(promise) {
  let message = '';
  await assertFailsRaw(promise.catch((e) => { message = String(e?.message ?? e); throw e; }));
  assert.ok(!message.includes('maximum of 1000'), `denied by the expression limit: ${message}`);
}

const here = dirname(fileURLToPath(import.meta.url));
const T = 'trip1';
let env;
// emulators:exec says where its emulator is; the default is the usual local one.
const [emulatorHost, emulatorPortText] = (process.env.FIRESTORE_EMULATOR_HOST ?? '127.0.0.1:8080').split(':');
const emulatorPort = Number(emulatorPortText);

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-ikut-rules',
    firestore: {
      rules: readFileSync(join(here, '../firestore.rules'), 'utf8'),
      host: emulatorHost,
      port: emulatorPort,
    },
  });
});
after(async () => env.cleanup());

const db = (uid) => (uid ? env.authenticatedContext(uid).firestore() : env.unauthenticatedContext().firestore());
const ts = (msAgo = 0) => Timestamp.fromMillis(Date.now() - msAgo);
const pt = new GeoPoint(3.1, 101.6);

const tripDoc = (over = {}) => ({
  name: 'KL run', code: 'ABC123', organizerId: 'org', route: '_p~iF~ps|U',
  destination: { name: 'Genting', coordinate: pt }, status: 'active',
  createdAt: Timestamp.now(), ...over,
});
const memberDoc = (over = {}) => ({ displayName: 'Sam', carId: 'carA', role: 'member', ...over });
const carDoc = (over = {}) => ({ name: 'Car A', color: '#f00', isLead: false, state: 'joining', ...over });
const position = (over = {}) => ({
  location: pt, speed: 20, heading: 90, routeOffset: 100, updatedAt: serverTimestamp(), ...over,
});
const event = (over = {}) => ({
  type: 'pothole', category: 'hazard', severity: 'high', location: pt, heading: 10,
  routeOffset: 5, authorId: 'mem', carId: 'carA', createdAt: ts(), ...over,
});

async function seed({ ended = false } = {}) {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const f = ctx.firestore();
    await setDoc(doc(f, `trips/${T}`), tripDoc({ status: ended ? 'ended' : 'active' }));
    await setDoc(doc(f, `trips/${T}/members/org`), memberDoc({ displayName: 'Org', carId: 'carO', role: 'organizer' }));
    await setDoc(doc(f, `trips/${T}/members/mem`), memberDoc());
    await setDoc(doc(f, `trips/${T}/members/other`), memberDoc({ displayName: 'Oth', carId: 'carB' }));
    await setDoc(doc(f, `trips/${T}/cars/carA`), carDoc({ trackerUserId: 'mem' }));
    await setDoc(doc(f, `trips/${T}/cars/carB`), carDoc({ name: 'Car B' }));
    await setDoc(doc(f, `trips/${T}/cars/carO`), carDoc({ name: 'Car O', isLead: true }));
    await setDoc(doc(f, `trips/${T}/positions/carA`), position({ updatedAt: Timestamp.now() }));
    await setDoc(doc(f, `trips/${T}/events/ev1`), event({ expiresAt: ts(-60000) }));
  });
}

describe('reads', () => {
  beforeEach(() => seed());
  const paths = ['', '/members/mem', '/cars/carA', '/positions/carA', '/events/ev1'];
  for (const p of paths) {
    it(`member can read trips/T${p}`, () => assertSucceeds(getDoc(doc(db('mem'), `trips/${T}${p}`))));
    it(`non-member cannot read trips/T${p}`, () => assertFails(getDoc(doc(db('stranger'), `trips/${T}${p}`))));
    it(`unauthenticated cannot read trips/T${p}`, () => assertFails(getDoc(doc(db(null), `trips/${T}${p}`))));
  }
  it('cannot list trips', () => assertFails(getDocs(collection(db('mem'), 'trips'))));
  it('member can list cars', () => assertSucceeds(getDocs(collection(db('mem'), `trips/${T}/cars`))));
  it('non-member cannot list cars', () => assertFails(getDocs(collection(db('stranger'), `trips/${T}/cars`))));
});

describe('trips', () => {
  beforeEach(() => seed());
  it('organizer creates trip + own member doc in one batch', async () => {
    const f = db('newOrg');
    const b = writeBatch(f);
    b.set(doc(f, 'trips/t2'), tripDoc({ organizerId: 'newOrg', createdAt: serverTimestamp() }));
    b.set(doc(f, 'trips/t2/members/newOrg'), memberDoc({ role: 'organizer', displayName: 'N' }));
    await assertSucceeds(b.commit());
  });
  it('create with wrong organizerId fails', () =>
    assertFails(setDoc(doc(db('x'), 'trips/t2'), tripDoc({ organizerId: 'y', createdAt: serverTimestamp() }))));
  it('create with bad code fails', () =>
    assertFails(setDoc(doc(db('x'), 'trips/t2'), tripDoc({ organizerId: 'x', code: 'abc123', createdAt: serverTimestamp() }))));
  it('create with status ended fails', () =>
    assertFails(setDoc(doc(db('x'), 'trips/t2'), tripDoc({ organizerId: 'x', status: 'ended', createdAt: serverTimestamp() }))));
  it('create with missing field fails', () => {
    const d = tripDoc({ organizerId: 'x', createdAt: serverTimestamp() });
    delete d.route;
    return assertFails(setDoc(doc(db('x'), 'trips/t2'), d));
  });
  it('create with client createdAt fails', () =>
    assertFails(setDoc(doc(db('x'), 'trips/t2'), tripDoc({ organizerId: 'x' }))));
  it('unauthenticated create fails', () =>
    assertFails(setDoc(doc(db(null), 'trips/t2'), tripDoc({ createdAt: serverTimestamp() }))));
  it('organizer can rename', () => assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { name: 'New' })));
  it('organizer can end trip with endedAt = request.time', () =>
    assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { status: 'ended', endedAt: serverTimestamp() })));
  it('ending without server endedAt fails', () =>
    assertFails(updateDoc(doc(db('org'), `trips/${T}`), { status: 'ended', endedAt: ts() })));
  it('non-organizer member cannot update', () => assertFails(updateDoc(doc(db('mem'), `trips/${T}`), { name: 'Hax' })));
  it('organizerId is immutable', () => assertFails(updateDoc(doc(db('org'), `trips/${T}`), { organizerId: 'mem' })));
  it('code is immutable', () => assertFails(updateDoc(doc(db('org'), `trips/${T}`), { code: 'ZZZZZZ' })));
  it('ended trip cannot be reactivated', async () => {
    await seed({ ended: true });
    await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { status: 'active' }));
  });
  it('ended trip cannot be edited', async () => {
    await seed({ ended: true });
    await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { name: 'x' }));
  });
  it('the organizer can record startedAt once with server time', async () => {
    await assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { startedAt: serverTimestamp() }));
  });
  it('a member who is not the organizer cannot record startedAt', async () => {
    await assertFails(updateDoc(doc(db('mem'), `trips/${T}`), { startedAt: serverTimestamp() }));
    await assertFails(updateDoc(doc(db('other'), `trips/${T}`), { startedAt: serverTimestamp() }));
  });
  it('startedAt needs server time and cannot ride along other fields', async () => {
    await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { startedAt: ts() }));
    await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { startedAt: serverTimestamp(), name: 'Hax' }));
  });
  it('non-member cannot set startedAt', () =>
    assertFails(updateDoc(doc(db('stranger'), `trips/${T}`), { startedAt: serverTimestamp() })));
  it('startedAt on an ended trip fails', async () => {
    await seed({ ended: true });
    await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { startedAt: serverTimestamp() }));
  });
  it('delete always fails (organizer)', () => assertFails(deleteDoc(doc(db('org'), `trips/${T}`))));
  it('delete always fails (member)', () => assertFails(deleteDoc(doc(db('mem'), `trips/${T}`))));
});

describe('trip startedAt is write-once', () => {
  it('cannot be overwritten', async () => {
    await seed();
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), `trips/${T}`), tripDoc({ startedAt: ts(5000) })));
    await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { startedAt: serverTimestamp() }));
  });
});

describe('D95: trip and event timestamps are server time or capped', () => {
  beforeEach(() => seed());
  const far = Timestamp.fromDate(new Date('9999-01-01T00:00:00Z'));
  const createWith = async (extra) => {
    const f = db('att');
    const b = writeBatch(f);
    b.set(doc(f, 'trips/d95'), tripDoc({ organizerId: 'att', createdAt: serverTimestamp(), ...extra }));
    b.set(doc(f, 'trips/d95/members/att'), memberDoc({ role: 'organizer', displayName: 'A', carId: 'c' }));
    return b.commit();
  };
  it('create with lastActivityAt in year 9999 fails', () => assertFails(createWith({ lastActivityAt: far })));
  it('create with a client lastActivityAt of now fails, server time passes', async () => {
    await assertFails(createWith({ lastActivityAt: ts() }));
    await assertSucceeds(createWith({ lastActivityAt: serverTimestamp() }));
  });
  it('create with a client startedAt fails (even server time: Start Trip is its own write)', async () => {
    await assertFails(createWith({ startedAt: ts(86400000) }));
    await assertFails(createWith({ startedAt: serverTimestamp() }));
  });
  it('organizer cannot push lastActivityAt to year 9999 or a client time', async () => {
    await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { lastActivityAt: far }));
    await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { lastActivityAt: ts() }));
  });
  it('organizer bumps lastActivityAt with server time', () =>
    assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { lastActivityAt: serverTimestamp() })));
  it('an old bad lastActivityAt left untouched does not block other edits', async () => {
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), `trips/${T}`), tripDoc({ lastActivityAt: far })));
    await assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { name: 'Renamed' }));
  });
  const ev = (id = 'new') => doc(db('mem'), `trips/${T}/events/${id}`);
  it('hazard create with expiresAt a year away fails; the app\'s own 45 and 60 minutes pass', async () => {
    await assertFails(setDoc(ev(), event({ expiresAt: Timestamp.fromMillis(Date.now() + 365 * 86400000) })));
    await assertFails(setDoc(ev(), event({ expiresAt: Timestamp.fromMillis(Date.now() + 3 * 3600000) })));
    await assertSucceeds(setDoc(ev(), event({ expiresAt: Timestamp.fromMillis(Date.now() + 45 * 60000) })));
    await assertSucceeds(setDoc(ev('c2'), event({ category: 'condition', expiresAt: Timestamp.fromMillis(Date.now() + 60 * 60000) })));
  });
  it('author cannot move a hazard expiresAt to year 9999 or a day out; now passes', async () => {
    await assertFails(updateDoc(doc(db('mem'), `trips/${T}/events/ev1`), { expiresAt: far }));
    await assertFails(updateDoc(doc(db('mem'), `trips/${T}/events/ev1`), { expiresAt: Timestamp.fromMillis(Date.now() + 86400000) }));
    await assertSucceeds(updateDoc(doc(db('mem'), `trips/${T}/events/ev1`), { expiresAt: ts() }));
  });
});

describe('members', () => {
  beforeEach(() => seed());
  it('user cannot create member doc for someone else\'s trip', () =>
    assertFails(setDoc(doc(db('stranger'), `trips/${T}/members/stranger`), memberDoc())));
  it('user cannot self-join as organizer of someone else\'s trip', () =>
    assertFails(setDoc(doc(db('stranger'), `trips/${T}/members/stranger`), memberDoc({ role: 'organizer' }))));
  it('organizer cannot create a member doc for another user', () =>
    assertFails(setDoc(doc(db('org'), `trips/${T}/members/stranger`), memberDoc())));
  it('member can update displayName', () =>
    assertSucceeds(updateDoc(doc(db('mem'), `trips/${T}/members/mem`), { displayName: 'Sammy' })));
  it('member can set pushToken', () =>
    assertSucceeds(updateDoc(doc(db('mem'), `trips/${T}/members/mem`), { pushToken: 'tok' })));
  it('member cannot change own carId', () =>
    assertFails(updateDoc(doc(db('mem'), `trips/${T}/members/mem`), { carId: 'carB' })));
  it('member cannot change carId alongside allowed fields', () =>
    assertFails(updateDoc(doc(db('mem'), `trips/${T}/members/mem`), { displayName: 'Sammy', carId: 'carB', pushToken: 'tok' })));
  it('member cannot change own role', () =>
    assertFails(updateDoc(doc(db('mem'), `trips/${T}/members/mem`), { role: 'organizer' })));
  it('organizer cannot change own role', () =>
    assertFails(updateDoc(doc(db('org'), `trips/${T}/members/org`), { role: 'member' })));
  it('displayName empty fails', () =>
    assertFails(updateDoc(doc(db('mem'), `trips/${T}/members/mem`), { displayName: '' })));
  it('displayName over 30 chars fails', () =>
    assertFails(updateDoc(doc(db('mem'), `trips/${T}/members/mem`), { displayName: 'x'.repeat(31) })));
  it('cannot update another member', () =>
    assertFails(updateDoc(doc(db('mem'), `trips/${T}/members/other`), { displayName: 'Hax' })));
  it('member can leave', () => assertSucceeds(deleteDoc(doc(db('mem'), `trips/${T}/members/mem`))));
  it('organizer can remove a member', () => assertSucceeds(deleteDoc(doc(db('org'), `trips/${T}/members/mem`))));
  it('member cannot remove another member', () => assertFails(deleteDoc(doc(db('mem'), `trips/${T}/members/other`))));
});

describe('cars', () => {
  beforeEach(() => seed());
  const car = (id) => doc(db('mem'), `trips/${T}/cars/${id}`);
  it('member can create a car', () => assertSucceeds(setDoc(doc(db('mem'), `trips/${T}/cars/new`), carDoc({ state: 'convoy' }))));
  it('non-member cannot create a car', () => assertFails(setDoc(doc(db('stranger'), `trips/${T}/cars/new`), carDoc())));
  it('member cannot create a lead car', () => assertFails(setDoc(doc(db('mem'), `trips/${T}/cars/new`), carDoc({ isLead: true }))));
  it('organizer can create a lead car', () => assertSucceeds(setDoc(doc(db('org'), `trips/${T}/cars/new`), carDoc({ isLead: true }))));
  it('bad state fails', () => assertFails(setDoc(doc(db('mem'), `trips/${T}/cars/new`), carDoc({ state: 'flying' }))));
  it('non-string color fails', () => assertFails(setDoc(doc(db('mem'), `trips/${T}/cars/new`), carDoc({ color: 5 }))));
  it('car with a badge number succeeds', () => assertSucceeds(setDoc(doc(db('mem'), `trips/${T}/cars/new`), carDoc({ number: 3 }))));
  it('badge number 0 fails', () => assertFails(setDoc(doc(db('mem'), `trips/${T}/cars/new`), carDoc({ number: 0 }))));
  it('non-integer badge number fails', () => assertFails(setDoc(doc(db('mem'), `trips/${T}/cars/new`), carDoc({ number: 1.5 }))));
  it('badge number cannot be changed', () => assertFails(updateDoc(doc(db('org'), `trips/${T}/cars/carB`), { number: 7 })));
  it('claim tracker when free succeeds', () => assertSucceeds(updateDoc(car('carB'), { trackerUserId: 'mem' })));
  it('steal tracker when taken fails', () =>
    assertFails(updateDoc(doc(db('other'), `trips/${T}/cars/carA`), { trackerUserId: 'other' })));
  it('claim tracker for someone else fails', () => assertFails(updateDoc(car('carB'), { trackerUserId: 'other' })));
  it('tracker can release', () => assertSucceeds(updateDoc(car('carA'), { trackerUserId: null })));
  it('non-tracker cannot release', () =>
    assertFails(updateDoc(doc(db('other'), `trips/${T}/cars/carA`), { trackerUserId: null })));
  it('tracker can change route, mergeOffset, state', () =>
    assertSucceeds(updateDoc(car('carA'), { route: 'abc', mergeOffset: 12.5, state: 'convoy' })));
  it('tracker can pause with a timestamp', () => assertSucceeds(updateDoc(car('carA'), { pausedAt: ts() })));
  it('tracker can resume by clearing pausedAt', async () => {
    await env.withSecurityRulesDisabled(async (c) => {
      await updateDoc(doc(c.firestore(), `trips/${T}/cars/carA`), { pausedAt: ts() });
    });
    await assertSucceeds(updateDoc(car('carA'), { pausedAt: deleteField() }));
  });
  it('tracker can set pausedAt to null', () => assertSucceeds(updateDoc(car('carA'), { pausedAt: null })));
  it('pausedAt must be a timestamp', () => assertFails(updateDoc(car('carA'), { pausedAt: 'now' })));
  it('pausedAt as a number fails', () => assertFails(updateDoc(car('carA'), { pausedAt: 123 })));
  it('non-tracker member cannot pause', () =>
    assertFails(updateDoc(doc(db('other'), `trips/${T}/cars/carA`), { pausedAt: ts() })));
  it('organizer who is not the tracker cannot pause', () =>
    assertFails(updateDoc(doc(db('org'), `trips/${T}/cars/carA`), { pausedAt: ts() })));
  it('pause on an ended trip fails', async () => {
    await seed({ ended: true });
    await assertFails(updateDoc(car('carA'), { pausedAt: ts() }));
  });
  it('tracker can release and clear a pause together', () =>
    assertSucceeds(updateDoc(car('carA'), { trackerUserId: null, pausedAt: deleteField() })));
  it('release cannot set a pause', () =>
    assertFails(updateDoc(car('carA'), { trackerUserId: null, pausedAt: ts() })));
  it('tracker cannot change isLead', () => assertFails(updateDoc(car('carA'), { isLead: true })));
  it('non-tracker member cannot change route', () =>
    assertFails(updateDoc(doc(db('other'), `trips/${T}/cars/carA`), { route: 'abc' })));
  it('organizer can change isLead and name', () =>
    assertSucceeds(updateDoc(doc(db('org'), `trips/${T}/cars/carB`), { isLead: true, name: 'Lead' })));
  it('organizer cannot change color', () =>
    assertFails(updateDoc(doc(db('org'), `trips/${T}/cars/carB`), { color: '#000' })));
  it('organizer can delete car', () => assertSucceeds(deleteDoc(doc(db('org'), `trips/${T}/cars/carB`))));
  it('member cannot delete car', () => assertFails(deleteDoc(car('carB'))));
});

describe('positions', () => {
  beforeEach(() => seed());
  const pos = (uid, id = 'carA') => doc(db(uid), `trips/${T}/positions/${id}`);
  it('tracker can write', () => assertSucceeds(setDoc(pos('mem'), position())));
  it('tracker can write with optional fields', () =>
    assertSucceeds(setDoc(pos('mem'), position({ convoyOffset: 50, battery: 0.5 }))));
  it('tracker can write with null optionals', () =>
    assertSucceeds(setDoc(pos('mem'), position({ convoyOffset: null, battery: null }))));
  it('non-tracker member cannot write', () => assertFails(setDoc(pos('other'), position())));
  it('non-member cannot write', () => assertFails(setDoc(pos('stranger'), position())));
  it('tracker of another car cannot write this car', async () => {
    await assertFails(setDoc(pos('mem', 'carB'), position()));
  });
  it('heading 360 fails', () => assertFails(setDoc(pos('mem'), position({ heading: 360 }))));
  it('negative heading fails', () => assertFails(setDoc(pos('mem'), position({ heading: -1 }))));
  it('negative speed fails', () => assertFails(setDoc(pos('mem'), position({ speed: -1 }))));
  it('negative routeOffset fails', () => assertFails(setDoc(pos('mem'), position({ routeOffset: -1 }))));
  it('negative convoyOffset fails', () => assertFails(setDoc(pos('mem'), position({ convoyOffset: -1 }))));
  it('battery > 1 fails', () => assertFails(setDoc(pos('mem'), position({ battery: 1.1 }))));
  it('location not latlng fails', () => assertFails(setDoc(pos('mem'), position({ location: { lat: 1, lng: 2 } }))));
  it('extra field fails', () => assertFails(setDoc(pos('mem'), position({ extra: 1 }))));
  it('client updatedAt fails', () => assertFails(setDoc(pos('mem'), position({ updatedAt: ts() }))));
  it('write after trip ended fails', async () => {
    await seed({ ended: true });
    await assertFails(setDoc(pos('mem'), position()));
  });
  it('delete fails', () => assertFails(deleteDoc(pos('mem'))));
});

describe('events', () => {
  beforeEach(() => seed());
  const ev = (uid, id = 'new') => doc(db(uid), `trips/${T}/events/${id}`);
  it('member can create', () => assertSucceeds(setDoc(ev('mem'), event())));
  it('unknown type string succeeds', () => assertSucceeds(setDoc(ev('mem'), event({ type: 'someNewType', category: 'message', severity: 'low' }))));
  it('empty type fails', () => assertFails(setDoc(ev('mem'), event({ type: '' }))));
  it('type over 40 chars fails', () => assertFails(setDoc(ev('mem'), event({ type: 'x'.repeat(41) }))));
  it('wrong carId fails', () => assertFails(setDoc(ev('mem'), event({ carId: 'carB' }))));
  it('wrong authorId fails', () => assertFails(setDoc(ev('mem'), event({ authorId: 'other' }))));
  it('non-member cannot create', () => assertFails(setDoc(ev('stranger'), event({ authorId: 'stranger' }))));
  it('bad category fails', () => assertFails(setDoc(ev('mem'), event({ category: 'nope' }))));
  it('bad severity fails', () => assertFails(setDoc(ev('mem'), event({ severity: 'nope' }))));
  it('message 280 chars ok', () => assertSucceeds(setDoc(ev('mem'), event({ message: 'm'.repeat(280) }))));
  it('message 281 chars fails', () => assertFails(setDoc(ev('mem'), event({ message: 'm'.repeat(281) }))));
  it('stale createdAt (10 min) fails', () => assertFails(setDoc(ev('mem'), event({ createdAt: ts(10 * 60 * 1000) }))));
  it('createdAt 2 min old ok', () => assertSucceeds(setDoc(ev('mem'), event({ createdAt: ts(2 * 60 * 1000) }))));
  it('expiresAt after createdAt ok', () => assertSucceeds(setDoc(ev('mem'), event({ expiresAt: ts(-60000) }))));
  it('expiresAt before createdAt fails', () => assertFails(setDoc(ev('mem'), event({ expiresAt: ts(60000) }))));
  it('create on ended trip fails', async () => {
    await seed({ ended: true });
    await assertFails(setDoc(ev('mem'), event()));
  });
  it('author can clear expiresAt', () => assertSucceeds(updateDoc(ev('mem', 'ev1'), { expiresAt: null })));
  it('author cannot change other fields', () => assertFails(updateDoc(ev('mem', 'ev1'), { message: 'edit' })));
  it('non-author cannot update expiresAt', () => assertFails(updateDoc(ev('other', 'ev1'), { expiresAt: null })));
  it('seed event authored by mem', async () => {
    await env.withSecurityRulesDisabled(async (c) => {
      await setDoc(doc(c.firestore(), `trips/${T}/events/ev2`), event({ authorId: 'other', carId: 'carB' }));
    });
    // organizer can delete someone else's event, author can delete own, other member cannot.
    await assertSucceeds(deleteDoc(ev('org', 'ev2')));
  });
  it('author can delete', () => assertSucceeds(deleteDoc(ev('mem', 'ev1'))));
  it('non-author member cannot delete', () => assertFails(deleteDoc(ev('other', 'ev1'))));
});

// Attacker's-eye cases added during review: a member or outsider trying to
// act as someone else, escalate, or read across trips.
describe('review: impersonation and escalation', () => {
  beforeEach(() => seed());

  it('member cannot write another car\'s position', () =>
    assertFails(setDoc(doc(db('other'), `trips/${T}/positions/carA`), position())));
  it('tracker cannot backdate updatedAt', () =>
    assertFails(setDoc(doc(db('mem'), `trips/${T}/positions/carA`), position({ updatedAt: ts(60_000) }))));
  it('member cannot create a car tracked by someone else', () =>
    assertFails(setDoc(doc(db('mem'), `trips/${T}/cars/carZ`), carDoc({ trackerUserId: 'other' }))));
  it('member cannot edit another member', () =>
    assertFails(updateDoc(doc(db('mem'), `trips/${T}/members/other`), { displayName: 'Hacked' })));
  it('member cannot remove another member', () =>
    assertFails(deleteDoc(doc(db('mem'), `trips/${T}/members/other`))));
  it('non-organizer cannot rename the trip', () =>
    assertFails(updateDoc(doc(db('mem'), `trips/${T}`), { name: 'Mine now' })));
  it('organizer cannot change the join code', () =>
    assertFails(updateDoc(doc(db('org'), `trips/${T}`), { code: 'ZZZ999' })));
  it('organizer cannot add someone else as a member', () =>
    assertFails(setDoc(doc(db('org'), `trips/${T}/members/x`), memberDoc({ carId: 'carB' }))));
  it('cannot post an event as another user', () =>
    assertFails(setDoc(doc(db('mem'), `trips/${T}/events/e9`), event({ authorId: 'other', carId: 'carB' }))));
  it('cannot create a trip on someone else\'s behalf', () =>
    assertFails(setDoc(doc(db('x'), 'trips/t9'), tripDoc({ organizerId: 'org' }))));
  it('member cannot list all trips', () =>
    assertFails(getDocs(collection(db('mem'), 'trips'))));
  it('a member of another trip cannot read this trip\'s events', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const f = ctx.firestore();
      await setDoc(doc(f, 'trips/trip2'), tripDoc({ organizerId: 'x', code: 'XYZ789' }));
      await setDoc(doc(f, 'trips/trip2/members/x'), memberDoc({ role: 'organizer', carId: 'carX' }));
    });
    await assertFails(getDocs(collection(db('x'), `trips/${T}/events`)));
    await assertFails(getDoc(doc(db('x'), `trips/${T}/positions/carA`)));
  });
});

// Stop requests (D24: no places): an OK per car, closing as stopped or cancelled, a 30 minute life.
// Seed: 'mem' is on carA (author), 'other' on carB, 'org' (organizer) on carO. Lead car is carO, tracked
// by 'lead' (a member with their own member doc pointing at carO) unless a test says otherwise.
describe('stop requests', () => {
  const MIN = 60 * 1000;
  const stop = (over = {}) =>
    event({ type: 'stopFuel', category: 'stopRequest', severity: 'medium', expiresAt: ts(-30 * MIN), ...over });
  const evRef = (uid, id = 'stop1') => doc(db(uid), `trips/${T}/events/${id}`);
  const voteRef = (uid, carId, id = 'stop1') => doc(db(uid), `trips/${T}/events/${id}/votes/${carId}`);
  const ok = (uid, over = {}) => ({ userId: uid, at: serverTimestamp(), ...over });
  const closed = (reason, uid, over = {}) => ({ status: 'closed', closedReason: reason, closedBy: uid, expiresAt: ts(), ...over });

  beforeEach(async () => {
    await seed();
    await env.withSecurityRulesDisabled(async (c) => {
      const f = c.firestore();
      await setDoc(doc(f, `trips/${T}/members/lead`), memberDoc({ displayName: 'Lead', carId: 'carO' }));
      await setDoc(doc(f, `trips/${T}/cars/carO`), carDoc({ name: 'Car O', isLead: true, trackerUserId: 'lead' }));
      await setDoc(doc(f, `trips/${T}/events/stop1`), stop());
      await setDoc(doc(f, `trips/${T}/events/stopDone`), stop({ expiresAt: ts(1000) }));
    });
  });

  describe('asking', () => {
    it('member can create a stop request that expires in 30 minutes', () =>
      assertSucceeds(setDoc(evRef('mem', 'new'), stop())));
    it('a passenger message of 280 characters rides along', () =>
      assertSucceeds(setDoc(evRef('mem', 'new'), stop({ message: 'm'.repeat(280) }))));
    it('a message over 280 characters fails', () =>
      assertFails(setDoc(evRef('mem', 'new'), stop({ message: 'm'.repeat(281) }))));
    it('a stop request without expiresAt fails', () => {
      const e = stop();
      delete e.expiresAt;
      return assertFails(setDoc(evRef('mem', 'new'), e));
    });
    it('a stop request that lasts 2 hours fails', () =>
      assertFails(setDoc(evRef('mem', 'new'), stop({ expiresAt: ts(-120 * MIN) }))));
    it('a stop request that lasts 36 minutes fails', () =>
      assertFails(setDoc(evRef('mem', 'new'), stop({ expiresAt: ts(-36 * MIN) }))));
    it('a stop request that lasts 34 minutes (clock slack) passes', () =>
      assertSucceeds(setDoc(evRef('mem', 'new'), stop({ expiresAt: ts(-34 * MIN) }))));
    it('a hazard still needs no expiresAt', () => assertSucceeds(setDoc(evRef('mem', 'new'), event())));
    it('a place cannot be supplied', () =>
      assertFails(setDoc(evRef('mem', 'new'), stop({ place: { name: 'R&R', coordinate: pt, routeOffset: 1, pinnedBy: 'mem' } }))));
    it('a status cannot be supplied', () => assertFails(setDoc(evRef('mem', 'new'), stop({ status: 'closed' }))));
  });

  describe('OK votes', () => {
    it('member says OK for own car', () => assertSucceeds(setDoc(voteRef('mem', 'carA'), ok('mem'))));
    it('the same car can say OK twice', async () => {
      await assertSucceeds(setDoc(voteRef('mem', 'carA'), ok('mem')));
      await assertSucceeds(setDoc(voteRef('mem', 'carA'), ok('mem')));
    });
    it('another member of the same car can say OK for it', async () => {
      await env.withSecurityRulesDisabled(async (c) => {
        await setDoc(doc(c.firestore(), `trips/${T}/members/mate`), memberDoc({ displayName: 'Mate' }));
      });
      await assertSucceeds(setDoc(voteRef('mate', 'carA'), ok('mate')));
    });
    it('member cannot say OK for another car', () => assertFails(setDoc(voteRef('mem', 'carB'), ok('mem'))));
    it('userId must be the caller', () => assertFails(setDoc(voteRef('mem', 'carA'), ok('other'))));
    it('the old agree field fails', () => assertFails(setDoc(voteRef('mem', 'carA'), ok('mem', { agree: true }))));
    it('the old answer field fails', () => assertFails(setDoc(voteRef('mem', 'carA'), ok('mem', { answer: 'yes' }))));
    it('a suggested place fails', () =>
      assertFails(setDoc(voteRef('mem', 'carA'), ok('mem', { suggestion: { name: 'P', coordinate: pt, routeOffset: 1 } }))));
    it('missing userId fails', () => {
      const v = ok('mem');
      delete v.userId;
      return assertFails(setDoc(voteRef('mem', 'carA'), v));
    });
    it('client timestamp fails', () => assertFails(setDoc(voteRef('mem', 'carA'), ok('mem', { at: ts() }))));
    it('non-member cannot say OK', () => assertFails(setDoc(voteRef('stranger', 'carA'), ok('stranger'))));
    it('cannot say OK on a resolved stop', () => assertFails(setDoc(voteRef('mem', 'carA', 'stopDone'), ok('mem'))));
    it('cannot say OK on a non-stop event', () => assertFails(setDoc(voteRef('mem', 'carA', 'ev1'), ok('mem'))));
    it('cannot say OK on a missing event', () => assertFails(setDoc(voteRef('mem', 'carA', 'nope'), ok('mem'))));
    it('cannot say OK on a stop that closed itself 30 minutes after it was asked', async () => {
      await env.withSecurityRulesDisabled(async (c) => {
        await setDoc(doc(c.firestore(), `trips/${T}/events/old`), stop({ createdAt: ts(31 * MIN), expiresAt: ts(MIN) }));
      });
      await assertFails(setDoc(voteRef('mem', 'carA', 'old'), ok('mem')));
    });
    it('cannot say OK on a stop that was closed', async () => {
      await updateDoc(evRef('lead'), closed('stopped', 'lead', { expiresAt: ts(-3_600_000) }));
      await assertFails(setDoc(voteRef('mem', 'carA'), ok('mem')));
    });
    it('cannot say OK on an ended trip', async () => {
      await seed({ ended: true });
      await env.withSecurityRulesDisabled(async (c) => {
        await setDoc(doc(c.firestore(), `trips/${T}/events/stop1`), stop());
      });
      await assertFails(setDoc(voteRef('mem', 'carA'), ok('mem')));
    });
    it('member can read votes', async () => {
      await assertSucceeds(setDoc(voteRef('mem', 'carA'), ok('mem')));
      await assertSucceeds(getDocs(collection(db('other'), `trips/${T}/events/stop1/votes`)));
    });
    it('non-member cannot read votes', () =>
      assertFails(getDocs(collection(db('stranger'), `trips/${T}/events/stop1/votes`))));
    it('votes cannot be deleted', async () => {
      await assertSucceeds(setDoc(voteRef('mem', 'carA'), ok('mem')));
      await assertFails(deleteDoc(voteRef('mem', 'carA')));
    });
  });

  describe('no places any more', () => {
    const place = { name: 'R&R Tapah', coordinate: pt, routeOffset: 18000, pinnedBy: 'lead' };
    it('the lead car cannot pin a place', () => assertFails(updateDoc(evRef('lead'), { place })));
    it('the organizer cannot pin a place', () =>
      assertFails(updateDoc(evRef('org'), { place: { ...place, pinnedBy: 'org' }, status: 'pinned' })));
    it('status pinned is not a state any more', () => assertFails(updateDoc(evRef('lead'), { status: 'pinned' })));
    it('closing cannot slip a place in', () =>
      assertFails(updateDoc(evRef('mem'), closed('cancelled', 'mem', { place: { ...place, pinnedBy: 'mem' } }))));
  });

  describe('closing', () => {
    it('lead car tracker closes as stopped', () => assertSucceeds(updateDoc(evRef('lead'), closed('stopped', 'lead'))));
    it('organizer closes as stopped', () => assertSucceeds(updateDoc(evRef('org'), closed('stopped', 'org'))));
    it('the asker closes as stopped', () => assertSucceeds(updateDoc(evRef('mem'), closed('stopped', 'mem'))));
    it('the asker cancels', () => assertSucceeds(updateDoc(evRef('mem'), closed('cancelled', 'mem'))));
    it('lead cannot cancel someone else\'s request', () => assertFails(updateDoc(evRef('lead'), closed('cancelled', 'lead'))));
    it('organizer cannot cancel someone else\'s request', () => assertFails(updateDoc(evRef('org'), closed('cancelled', 'org'))));
    it('another member cannot close it at all', async () => {
      await assertFails(updateDoc(evRef('other'), closed('stopped', 'other')));
      await assertFails(updateDoc(evRef('other'), closed('cancelled', 'other')));
    });
    it('non-member cannot close it', () => assertFails(updateDoc(evRef('stranger'), closed('stopped', 'stranger'))));
    it('the old reasons left and noAnswer fail', async () => {
      await assertFails(updateDoc(evRef('lead'), closed('left', 'lead')));
      await assertFails(updateDoc(evRef('org'), closed('noAnswer', 'org')));
      await assertFails(updateDoc(evRef('mem'), closed('left', 'mem')));
    });
    it('a lead flag on a car someone else tracks does not grant closing', async () => {
      await env.withSecurityRulesDisabled(async (c) => {
        await setDoc(doc(c.firestore(), `trips/${T}/cars/carO`), carDoc({ isLead: true, trackerUserId: 'someoneElse' }));
      });
      await assertFails(updateDoc(evRef('lead'), closed('stopped', 'lead')));
    });
    it('closing needs closedBy to be the caller', () => assertFails(updateDoc(evRef('lead'), closed('stopped', 'org'))));
    it('closing without closedReason fails', () => {
      const c = closed('stopped', 'lead');
      delete c.closedReason;
      return assertFails(updateDoc(evRef('lead'), c));
    });
    it('closing without expiresAt fails', () => {
      const c = closed('stopped', 'lead');
      delete c.expiresAt;
      return assertFails(updateDoc(evRef('lead'), c));
    });
    it('an unknown closedReason fails', () => assertFails(updateDoc(evRef('lead'), closed('bored', 'lead'))));
    it('cannot close an already closed stop', () => assertFails(updateDoc(evRef('lead', 'stopDone'), closed('stopped', 'lead'))));
    it('cannot close a hazard event', () => assertFails(updateDoc(evRef('lead', 'ev1'), closed('stopped', 'lead'))));
    it('cannot close on an ended trip', async () => {
      await seed({ ended: true });
      await env.withSecurityRulesDisabled(async (c) => {
        const f = c.firestore();
        await setDoc(doc(f, `trips/${T}/members/lead`), memberDoc({ carId: 'carO' }));
        await setDoc(doc(f, `trips/${T}/cars/carO`), carDoc({ isLead: true, trackerUserId: 'lead' }));
        await setDoc(doc(f, `trips/${T}/events/stop1`), stop());
      });
      await assertFails(updateDoc(evRef('lead'), closed('stopped', 'lead')));
    });
  });

  describe('resolve', () => {
    it('author can resolve', () => assertSucceeds(updateDoc(evRef('mem'), { expiresAt: ts() })));
    it('organizer can resolve', () => assertSucceeds(updateDoc(evRef('org'), { expiresAt: ts() })));
    it('lead car tracker can resolve', () => assertSucceeds(updateDoc(evRef('lead'), { expiresAt: ts() })));
    it('other member cannot resolve', () => assertFails(updateDoc(evRef('other'), { expiresAt: ts() })));
    it('non-member cannot resolve', () => assertFails(updateDoc(evRef('stranger'), { expiresAt: ts() })));
    it('organizer cannot expire a hazard they did not author', () =>
      assertFails(updateDoc(evRef('org', 'ev1'), { expiresAt: ts() })));
    it('the asker cannot clear expiresAt on an expired stop to reopen it', () =>
      assertFails(updateDoc(evRef('mem', 'stopDone'), { expiresAt: null })));
    it('the asker cannot hold a stop open by setting expiresAt a year out', () =>
      assertFails(updateDoc(evRef('mem'), { expiresAt: ts(-365 * 24 * 60 * MIN) })));
    it('the lead cannot bring a closed stop back with 20 more minutes', async () => {
      await updateDoc(evRef('lead'), closed('stopped', 'lead'));
      await assertFails(updateDoc(evRef('lead'), { expiresAt: ts(-20 * MIN) }));
    });
    it('a phone clock a few seconds ahead can still close a stop early', () =>
      assertSucceeds(updateDoc(evRef('mem'), { expiresAt: ts(-5000) })));
    it('two minutes ahead is too far', () => assertFails(updateDoc(evRef('mem'), { expiresAt: ts(-2 * MIN) })));
    it('the asker cannot reopen an expired stop for 30 seconds', () =>
      assertFails(updateDoc(evRef('mem', 'stopDone'), { expiresAt: ts(-30 * 1000) })));
    it('the lead cannot reopen an expired stop for 30 seconds', () =>
      assertFails(updateDoc(evRef('lead', 'stopDone'), { expiresAt: ts(-30 * 1000) })));
    it('a stop can still be closed earlier than it was set to expire', () =>
      assertSucceeds(updateDoc(evRef('lead'), { expiresAt: ts(5 * MIN) })));
    it('the lead cannot push an open stop later', () => assertFails(updateDoc(evRef('lead'), { expiresAt: ts(-31 * MIN) })));
    it('the asker cannot clear expiresAt on an open stop', () => assertFails(updateDoc(evRef('mem'), { expiresAt: null })));
    it('lead cannot clear expiresAt to reopen', () => assertFails(updateDoc(evRef('lead', 'stopDone'), { expiresAt: null })));
    it('lead cannot change other fields while resolving', () =>
      assertFails(updateDoc(evRef('lead'), { expiresAt: ts(), message: 'x' })));
    it('resolve fails on an ended trip', async () => {
      await seed({ ended: true });
      await env.withSecurityRulesDisabled(async (c) => {
        await setDoc(doc(c.firestore(), `trips/${T}/events/stop1`), stop());
      });
      await assertFails(updateDoc(evRef('mem'), { expiresAt: ts() }));
    });
  });
});

describe('planned stops', () => {
  const stopDoc = (over = {}) => {
    const d = { name: 'R&R Tapah', coordinate: pt, routeOffset: 62000, kind: 'fuel', minutes: 20, order: 0, ...over };
    for (const k of Object.keys(d)) if (d[k] === undefined) delete d[k];
    return d;
  };
  const stopPath = (id = 's1') => `trips/${T}/stops/${id}`;
  const seedStops = async ({ started = false } = {}) => {
    await seed();
    await env.withSecurityRulesDisabled(async (ctx) => {
      const f = ctx.firestore();
      if (started) await setDoc(doc(f, `trips/${T}`), tripDoc({ startedAt: ts(60000) }));
      await setDoc(doc(f, stopPath('s1')), stopDoc());
      await setDoc(doc(f, stopPath('s2')), stopDoc({ name: 'Kopitiam', kind: 'food', order: 1, minutes: undefined }));
    });
  };

  describe('before the trip starts', () => {
    beforeEach(() => seedStops());
    it('a member can read a stop and list them', async () => {
      await assertSucceeds(getDoc(doc(db('mem'), stopPath())));
      await assertSucceeds(getDocs(collection(db('mem'), `trips/${T}/stops`)));
    });
    it('a non-member cannot read stops', async () => {
      await assertFails(getDoc(doc(db('stranger'), stopPath())));
      await assertFails(getDocs(collection(db('stranger'), `trips/${T}/stops`)));
    });
    it('the organizer adds a stop', () => assertSucceeds(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ order: 2 }))));
    it('the organizer adds a meeting point as the first stop, with a time and no length', () =>
      assertSucceeds(setDoc(doc(db('org'), stopPath('m')), stopDoc({
        kind: 'meet', minutes: undefined, meetAt: Timestamp.fromMillis(Date.now() + 3600000), order: 0,
      }))));
    it('a meeting point is refused anywhere but first', () =>
      assertFails(setDoc(doc(db('org'), stopPath('m')), stopDoc({ kind: 'meet', minutes: undefined, order: 1 }))));
    it('a meeting point has no length', () =>
      assertFails(setDoc(doc(db('org'), stopPath('m')), stopDoc({ kind: 'meet', minutes: 10, order: 0 }))));
    it('a time on a stop that is not a meeting point is refused', () =>
      assertFails(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ meetAt: Timestamp.now(), order: 2 }))));
    it('a member who is not the organizer cannot add a stop', () =>
      assertFails(setDoc(doc(db('mem'), stopPath('s3')), stopDoc({ order: 2 }))));
    it('a stranger cannot add a stop', () =>
      assertFails(setDoc(doc(db('stranger'), stopPath('s3')), stopDoc({ order: 2 }))));
    it('an unknown kind is refused', () =>
      assertFails(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ kind: 'spa', order: 2 }))));
    it('a stop with no name or a made-up field is refused', async () => {
      await assertFails(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ name: '', order: 2 })));
      await assertFails(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ order: 2, hacked: true })));
    });
    it('a stop that is already skipped cannot be created', () =>
      assertFails(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ order: 2, skipped: true }))));
    it('the organizer reorders and edits stops', async () => {
      await assertSucceeds(updateDoc(doc(db('org'), stopPath('s1')), { order: 1 }));
      await assertSucceeds(updateDoc(doc(db('org'), stopPath('s1')), { minutes: 30, kind: 'rest', routeOffset: 70000 }));
    });
    it('a member who is not the organizer cannot reorder', () =>
      assertFails(updateDoc(doc(db('mem'), stopPath('s1')), { order: 1 })));
    it('the organizer removes a stop', () => assertSucceeds(deleteDoc(doc(db('org'), stopPath('s1')))));
    it('a member who is not the organizer cannot remove a stop', () =>
      assertFails(deleteDoc(doc(db('mem'), stopPath('s1')))));
    it('the route and its stops go in one batch', async () => {
      const f = db('org');
      const b = writeBatch(f);
      b.update(doc(f, `trips/${T}`), { route: '_p~iF~ps|U_ulLnnqC', routeSeconds: 9600 });
      b.set(doc(f, stopPath('s1')), stopDoc({ order: 0 }));
      b.set(doc(f, stopPath('s3')), stopDoc({ name: 'Bidor', order: 1 }));
      b.delete(doc(f, stopPath('s2')));
      await assertSucceeds(b.commit());
    });
    it('the drive time on the trip must be a number', () =>
      assertFails(updateDoc(doc(db('org'), `trips/${T}`), { routeSeconds: 'long' })));
    it('nobody but the organizer can set the drive time', () =>
      assertFails(updateDoc(doc(db('mem'), `trips/${T}`), { routeSeconds: 100 })));
    it('a stop on an ended trip cannot be added', async () => {
      await seed({ ended: true });
      await assertFails(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ order: 2 })));
    });
    it('the organizer cannot skip before the start', () =>
      assertFails(updateDoc(doc(db('org'), stopPath('s1')), {
        skipped: true, skippedBy: 'org', skippedAt: serverTimestamp(),
      })));
  });

  describe('after the trip has started', () => {
    beforeEach(() => seedStops({ started: true }));
    const skip = (over = {}) => ({ skipped: true, skippedBy: 'org', skippedAt: serverTimestamp(), ...over });
    it('the organizer skips a stop', () => assertSucceeds(updateDoc(doc(db('org'), stopPath('s1')), skip())));
    it('a member who is not the organizer cannot skip', () =>
      assertFails(updateDoc(doc(db('mem'), stopPath('s1')), skip({ skippedBy: 'mem' }))));
    it('the skip must name the organizer and use server time', async () => {
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), skip({ skippedBy: 'mem' })));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), skip({ skippedAt: ts() })));
    });
    it('a skip cannot be undone', async () => {
      await env.withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), stopPath('s1')), { skipped: true, skippedBy: 'org', skippedAt: Timestamp.now() }));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), { skipped: false }));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), skip()));
    });
    it('a skip cannot carry other changes', async () => {
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), skip({ order: 5 })));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), skip({ routeOffset: 1 })));
    });
    it('nothing but a skip can change', async () => {
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), { order: 1 }));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), { name: 'Elsewhere' }));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), { minutes: 5 }));
    });
    it('no stop can be added or removed', async () => {
      await assertFails(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ order: 2 })));
      await assertFails(deleteDoc(doc(db('org'), stopPath('s1'))));
    });
    it('a member can still read the stops', () => assertSucceeds(getDoc(doc(db('mem'), stopPath()))));
  });

  // D25 4d: a rebuilt route moves the stops still ahead (open, not reached) to their place on it, in the same batch.
  describe('the route rebuilt after the start', () => {
    beforeEach(async () => {
      await seedStops({ started: true });
      await env.withSecurityRulesDisabled((ctx) => updateDoc(doc(ctx.firestore(), `trips/${T}`), { stopCount: 2 }));
    });
    const rebuild = (uid, stops, trip = { route: '_p~iF~ps|U_ulLnnqC', routeSeconds: 9000 }) => {
      const f = db(uid);
      const b = writeBatch(f);
      if (trip) b.update(doc(f, `trips/${T}`), trip);
      for (const [id, fields] of Object.entries(stops)) b.update(doc(f, stopPath(id)), fields);
      return b.commit();
    };
    const mark = (id, fields) => env.withSecurityRulesDisabled((ctx) => updateDoc(doc(ctx.firestore(), stopPath(id)), fields));
    it('the organizer writes the route and the new offsets of the stops ahead together', () =>
      assertSucceeds(rebuild('org', { s1: { routeOffset: 40000 }, s2: { routeOffset: 90000 } })));
    it('an offset alone, without a new route in the batch, is refused', async () => {
      await assertFails(rebuild('org', { s1: { routeOffset: 40000 } }, null));
      await assertFails(rebuild('org', { s1: { routeOffset: 40000 } }, { name: 'Renamed' }));
    });
    it('a member who is not the organizer cannot move a stop', () =>
      assertFails(rebuild('mem', { s1: { routeOffset: 40000 } })));
    it("the lead car's tracker, who may mark a stop reached or left, cannot move its offset", async () => {
      await env.withSecurityRulesDisabled(async (ctx) => {
        const f = ctx.firestore();
        await setDoc(doc(f, `trips/${T}/members/lead`), memberDoc({ displayName: 'Lead', carId: 'carL' }));
        await setDoc(doc(f, `trips/${T}/cars/carL`), carDoc({ name: 'Car L', isLead: true, trackerUserId: 'lead' }));
      });
      await assertFails(rebuild('lead', { s1: { routeOffset: 40000 } }));
      await assertFails(rebuild('lead', { s1: { routeOffset: 40000 } }, null));
      await assertFails(rebuild('lead', { s1: { routeOffset: 40000, arrivedAt: serverTimestamp() } }, null));
      await assertSucceeds(rebuild('lead', { s1: { arrivedAt: serverTimestamp() } }, null));
    });
    it('only the offset moves: nothing else on the stop changes with it', async () => {
      await assertFails(rebuild('org', { s1: { routeOffset: 40000, name: 'Elsewhere' } }));
      await assertFails(rebuild('org', { s1: { routeOffset: 40000, order: 1 } }));
      await assertFails(rebuild('org', { s1: { routeOffset: -5 } }));
      await assertFails(rebuild('org', { s1: { routeOffset: 'far' } }));
    });
    it('a skipped stop keeps its offset', async () => {
      await mark('s1', { skipped: true, skippedBy: 'org', skippedAt: Timestamp.now() });
      await assertFails(rebuild('org', { s1: { routeOffset: 40000 } }));
      await assertSucceeds(rebuild('org', { s2: { routeOffset: 90000 } }));
    });
    it('a stop the convoy has left keeps its offset', async () => {
      await mark('s1', { leftAt: Timestamp.now(), leftBy: 'org' });
      await assertFails(rebuild('org', { s1: { routeOffset: 40000 } }));
    });
    it('a stop the lead car has reached keeps its offset', async () => {
      await mark('s1', { arrivedAt: Timestamp.now() });
      await assertFails(rebuild('org', { s1: { routeOffset: 40000 } }));
    });
    it('a meeting point keeps its offset', async () => {
      await mark('s1', { kind: 'meet', minutes: deleteField() });
      await assertFails(rebuild('org', { s1: { routeOffset: 40000 } }));
    });
    it('not on an ended trip', async () => {
      await env.withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), `trips/${T}`), { status: 'ended', endedAt: Timestamp.now() }));
      await assertFails(rebuild('org', { s1: { routeOffset: 40000 } }));
    });
  });

  // D25 4a: the lead car's tracker or the organizer taps Leave (leftAt, leftBy); the lead car's tracker also writes
  // arrivedAt, once, when it first counts itself at the stop (the start of "Leaving at 12:40").
  describe('leaving a stop', () => {
    beforeEach(async () => {
      await seedStops({ started: true });
      await env.withSecurityRulesDisabled(async (ctx) => {
        const f = ctx.firestore();
        await setDoc(doc(f, `trips/${T}/members/lead`), memberDoc({ displayName: 'Lead', carId: 'carL' }));
        await setDoc(doc(f, `trips/${T}/cars/carL`), carDoc({ name: 'Car L', isLead: true, trackerUserId: 'lead' }));
      });
    });
    const leave = (uid = 'org', over = {}) => ({ leftAt: serverTimestamp(), leftBy: uid, ...over });
    const arrive = (over = {}) => ({ arrivedAt: serverTimestamp(), ...over });
    const seedLeft = () => env.withSecurityRulesDisabled((ctx) =>
      updateDoc(doc(ctx.firestore(), stopPath('s1')), { leftAt: Timestamp.now(), leftBy: 'org' }));

    it('the organizer leaves a stop', () => assertSucceeds(updateDoc(doc(db('org'), stopPath('s1')), leave())));
    it('the lead car\'s tracker leaves a stop', () => assertSucceeds(updateDoc(doc(db('lead'), stopPath('s1')), leave('lead'))));
    it('another car cannot leave', () => assertFails(updateDoc(doc(db('mem'), stopPath('s1')), leave('mem'))));
    it('a member of the lead car who is not its tracker cannot leave', async () => {
      await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), `trips/${T}/members/pass`),
        memberDoc({ displayName: 'Pass', carId: 'carL' })));
      await assertFails(updateDoc(doc(db('pass'), stopPath('s1')), leave('pass')));
    });
    it('a stranger cannot leave', () => assertFails(updateDoc(doc(db('stranger'), stopPath('s1')), leave('stranger'))));
    it('leave must name the caller and use server time', async () => {
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), leave('org', { leftBy: 'lead' })));
      await assertFails(updateDoc(doc(db('lead'), stopPath('s1')), leave('lead', { leftBy: 'org' })));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), leave('org', { leftAt: ts() })));
    });
    it('leave needs both fields and nothing else', async () => {
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), { leftAt: serverTimestamp() }));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), { leftBy: 'org' }));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), leave('org', { order: 5 })));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), leave('org', { routeOffset: 1 })));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), leave('org', { skipped: true })));
    });
    it('a stop is left once', async () => {
      await seedLeft();
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), leave()));
      await assertFails(updateDoc(doc(db('lead'), stopPath('s1')), leave('lead')));
    });
    it('a stop skipped for everyone cannot be left', async () => {
      await env.withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), stopPath('s1')), { skipped: true, skippedBy: 'org', skippedAt: Timestamp.now() }));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), leave()));
    });
    it('a stop that was left cannot be skipped for everyone', async () => {
      await seedLeft();
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), {
        skipped: true, skippedBy: 'org', skippedAt: serverTimestamp() }));
    });
    it('a left stop cannot be taken back', async () => {
      await seedLeft();
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), { leftAt: deleteField(), leftBy: deleteField() }));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), { leftBy: 'lead' }));
    });
    it('before the start nobody can leave', async () => {
      await seedStops({ started: false });
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), leave()));
    });
    it('the organizer cannot plan a stop as already left', async () => {
      await seedStops({ started: false });
      await assertFails(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ order: 2, leftAt: Timestamp.now(), leftBy: 'org' })));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), stopDoc({ leftAt: Timestamp.now(), leftBy: 'org' })));
    });
    it('on an ended trip nobody leaves', async () => {
      await env.withSecurityRulesDisabled((ctx) => updateDoc(doc(ctx.firestore(), `trips/${T}`), { status: 'ended' }));
      await assertFails(updateDoc(doc(db('org'), stopPath('s1')), leave()));
    });

    it('the lead car\'s tracker writes arrivedAt', () =>
      assertSucceeds(updateDoc(doc(db('lead'), stopPath('s1')), arrive())));
    it('the organizer writes arrivedAt', () => assertSucceeds(updateDoc(doc(db('org'), stopPath('s1')), arrive())));
    it('another car cannot write arrivedAt', () => assertFails(updateDoc(doc(db('mem'), stopPath('s1')), arrive())));
    it('arrivedAt is written once, in server time, alone', async () => {
      await assertFails(updateDoc(doc(db('lead'), stopPath('s1')), arrive({ arrivedAt: ts() })));
      await assertFails(updateDoc(doc(db('lead'), stopPath('s1')), arrive({ order: 3 })));
      await assertFails(updateDoc(doc(db('lead'), stopPath('s1')), { arrivedAt: serverTimestamp(), leftAt: serverTimestamp(), leftBy: 'lead' }));
      await assertSucceeds(updateDoc(doc(db('lead'), stopPath('s1')), arrive()));
      await assertFails(updateDoc(doc(db('lead'), stopPath('s1')), arrive()));
      await assertFails(updateDoc(doc(db('lead'), stopPath('s1')), { arrivedAt: deleteField() }));
    });
    it('arrivedAt is not written before the start, on a skipped stop or on a left stop', async () => {
      await seedLeft();
      await assertFails(updateDoc(doc(db('lead'), stopPath('s1')), arrive()));
      await env.withSecurityRulesDisabled((ctx) =>
        updateDoc(doc(ctx.firestore(), stopPath('s2')), { skipped: true, skippedBy: 'org', skippedAt: Timestamp.now() }));
      await assertFails(updateDoc(doc(db('lead'), stopPath('s2')), arrive()));
      await seedStops({ started: false });
      await assertFails(updateDoc(doc(db('lead'), stopPath('s1')), arrive()));
    });
    it('the organizer cannot plan a stop with an arrivedAt', async () => {
      await seedStops({ started: false });
      await assertFails(setDoc(doc(db('org'), stopPath('s3')), stopDoc({ order: 2, arrivedAt: Timestamp.now() })));
    });
    it('a left stop takes no more skip answers', async () => {
      await seedLeft();
      await assertFails(setDoc(doc(db('mem'), `trips/${T}/stops/s1/answers/carA`),
        { answer: 'skip', userId: 'mem', at: serverTimestamp() }));
      // Another stop still does.
      await assertSucceeds(setDoc(doc(db('mem'), `trips/${T}/stops/s2/answers/carA`),
        { answer: 'skip', userId: 'mem', at: serverTimestamp() }));
    });
  });
});

// A car's answer about a planned stop (D25 5a): trips/T/stops/s1/answers/{carId}.
describe('a car\'s skip answer', () => {
  const stopDoc = (over = {}) => ({
    name: 'R&R Tapah', coordinate: pt, routeOffset: 62000, kind: 'fuel', minutes: 20, order: 0, ...over,
  });
  const ansPath = (carId = 'carA', stopId = 's1') => `trips/${T}/stops/${stopId}/answers/${carId}`;
  const skipAns = (uid = 'mem', over = {}) => ({ answer: 'skip', userId: uid, at: serverTimestamp(), ...over });
  const seedAnswers = async ({ started = true, posOffset = 100, skipped = false } = {}) => {
    await seed();
    await env.withSecurityRulesDisabled(async (ctx) => {
      const f = ctx.firestore();
      await setDoc(doc(f, `trips/${T}`), tripDoc(started ? { startedAt: ts(60000) } : {}));
      await setDoc(doc(f, `trips/${T}/stops/s1`), stopDoc(skipped ? { skipped: true, skippedBy: 'org', skippedAt: Timestamp.now() } : {}));
      await setDoc(doc(f, `trips/${T}/stops/s2`), stopDoc({ name: 'Kopitiam', kind: 'food', order: 1, routeOffset: 90000 }));
      await setDoc(doc(f, `trips/${T}/positions/carA`), position({ routeOffset: 100, convoyOffset: posOffset, updatedAt: Timestamp.now() }));
    });
  };
  beforeEach(() => seedAnswers());

  it('a member skips the stop for their own car', () => assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns())));
  it('the car can change its mind again and again (a second phone writes the same document)', async () => {
    await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
    await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
  });
  it('a car with no position yet can skip', async () => {
    await env.withSecurityRulesDisabled((ctx) => deleteDoc(doc(ctx.firestore(), `trips/${T}/positions/carA`)));
    await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
  });
  it('undo deletes the car\'s own answer', async () => {
    await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
    await assertSucceeds(deleteDoc(doc(db('mem'), ansPath())));
    assert.equal((await getDoc(doc(db('mem'), ansPath()))).exists(), false);
  });
  it('undoing an answer that is not there is harmless', () => assertSucceeds(deleteDoc(doc(db('mem'), ansPath()))));
  it('a member answers for another car: denied', () => assertFails(setDoc(doc(db('mem'), ansPath('carB')), skipAns())));
  it('the other car\'s member can answer for their own car, so the denial above is about the car', () =>
    assertSucceeds(setDoc(doc(db('other'), ansPath('carB')), skipAns('other'))));
  it('a member cannot undo another car\'s answer', async () => {
    await env.withSecurityRulesDisabled((ctx) =>
      setDoc(doc(ctx.firestore(), ansPath('carB')), { answer: 'skip', userId: 'other', at: Timestamp.now() }));
    await assertFails(deleteDoc(doc(db('mem'), ansPath('carB'))));
    await assertSucceeds(deleteDoc(doc(db('other'), ansPath('carB'))));
  });
  it('the lead car cannot skip', async () => {
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), `trips/${T}/members/lead`),
      memberDoc({ displayName: 'Lead', carId: 'carO', role: 'member' })));
    await assertFails(setDoc(doc(db('lead'), ansPath('carO')), skipAns('lead')));
    await assertFails(setDoc(doc(db('org'), ansPath('carO')), skipAns('org')));
  });
  it('before the trip starts: denied', async () => {
    await seedAnswers({ started: false });
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns()));
  });
  it('a stop the organizer skipped for everyone takes no answer', async () => {
    await seedAnswers({ skipped: true });
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns()));
  });
  it('another stop on the same trip still takes it', () => assertSucceeds(setDoc(doc(db('mem'), ansPath('carA', 's2')), skipAns())));
  it('a car that has not merged onto the main route yet can skip, whatever its own offset', async () => {
    await env.withSecurityRulesDisabled((ctx) =>
      setDoc(doc(ctx.firestore(), `trips/${T}/positions/carA`), position({ routeOffset: 99999, updatedAt: Timestamp.now() })));
    await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
  });
  it('a car within 150 m of the stop is there, and cannot skip it', async () => {
    await seedAnswers({ posOffset: 61851 });
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns()));
    await seedAnswers({ posOffset: 61849 });
    await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
  });
  it('exactly 150 m short of the stop is there: denied; just over 150 m short can skip', async () => {
    await seedAnswers({ posOffset: 61850 });
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns()));
    await seedAnswers({ posOffset: 61849.5 });
    await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
  });
  describe('a meeting point', () => {
    const seedMeet = async (carState, posOffset) => {
      await seedAnswers({ posOffset });
      await env.withSecurityRulesDisabled(async (ctx) => {
        const f = ctx.firestore();
        await setDoc(doc(f, `trips/${T}/stops/s1`), { name: 'Petronas', coordinate: pt, routeOffset: 5000, kind: 'meet', order: 0 });
        await setDoc(doc(f, `trips/${T}/cars/carA`), carDoc({ trackerUserId: 'mem', state: carState }));
      });
    };
    it('a car still joining (on its own way in) can skip it', async () => {
      await seedMeet('joining', 100);
      await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
    });
    it('a car already on the main route cannot skip it, however short of it', async () => {
      await seedMeet('convoy', 100);
      await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns()));
    });
    it('at routeOffset 0, a joining car whose own offset is 0 can skip it; a convoy car cannot', async () => {
      await seedMeet('joining', 0);
      await env.withSecurityRulesDisabled((ctx) =>
        setDoc(doc(ctx.firestore(), `trips/${T}/stops/s1`), { name: 'Petronas', coordinate: pt, routeOffset: 0, kind: 'meet', order: 0 }));
      await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
      await env.withSecurityRulesDisabled((ctx) =>
        setDoc(doc(ctx.firestore(), `trips/${T}/cars/carA`), carDoc({ trackerUserId: 'mem', state: 'convoy' })));
      await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns()));
    });
    it('another kind of stop does not ask for a joining car', async () => {
      await seedMeet('convoy', 100);
      await env.withSecurityRulesDisabled((ctx) =>
        setDoc(doc(ctx.firestore(), `trips/${T}/stops/s1`), stopDoc({ routeOffset: 5000 })));
      await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
    });
  });
  it('a car that has reached the stop cannot skip it', async () => {
    await seedAnswers({ posOffset: 62000 });
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns()));
  });
  it('a car that has passed the stop cannot skip it', async () => {
    await seedAnswers({ posOffset: 70000 });
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns()));
    await assertSucceeds(setDoc(doc(db('mem'), ansPath('carA', 's2')), skipAns()));
  });
  it('a car 200 m short of the stop can still skip it', async () => {
    await seedAnswers({ posOffset: 61800 });
    await assertSucceeds(setDoc(doc(db('mem'), ansPath()), skipAns()));
  });
  it('a non-member cannot write or undo', async () => {
    await assertFails(setDoc(doc(db('stranger'), ansPath()), skipAns('stranger')));
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), ansPath()), { answer: 'skip', userId: 'mem', at: Timestamp.now() }));
    await assertFails(deleteDoc(doc(db('stranger'), ansPath())));
    await assertFails(deleteDoc(doc(db(null), ansPath())));
  });
  it('a non-member reads nothing, a member reads the answers', async () => {
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), ansPath()), { answer: 'skip', userId: 'mem', at: Timestamp.now() }));
    await assertFails(getDoc(doc(db('stranger'), ansPath())));
    await assertFails(getDocs(collection(db('stranger'), `trips/${T}/stops/s1/answers`)));
    await assertSucceeds(getDoc(doc(db('other'), ansPath())));
    await assertSucceeds(getDocs(collection(db('other'), `trips/${T}/stops/s1/answers`)));
  });
  it('only answer, userId and at, with the caller\'s id, server time and "skip"', async () => {
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns('mem', { extra: 1 })));
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns('other')));
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns('mem', { at: ts() })));
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns('mem', { answer: 'sulk' })));
    await assertFails(setDoc(doc(db('mem'), ansPath()), { answer: 'skip', userId: 'mem' }));
  });
  it('an ended trip takes no answer and no undo', async () => {
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), `trips/${T}`), tripDoc({ startedAt: ts(60000), status: 'ended' })));
    await assertFails(setDoc(doc(db('mem'), ansPath()), skipAns()));
    await assertFails(deleteDoc(doc(db('mem'), ansPath())));
  });
  it('a stop that is not there takes no answer', () => assertFails(setDoc(doc(db('mem'), ansPath('carA', 'nope')), skipAns())));
  it('answers cannot be made through the stop document', () =>
    assertFails(updateDoc(doc(db('mem'), `trips/${T}/stops/s1`), { answers: { carA: 'skip' } })));
});

describe('a trip with stops keeps its route once it has started', () => {
  const seedTrip = async (over) => {
    await seed();
    await env.withSecurityRulesDisabled((ctx) => setDoc(doc(ctx.firestore(), `trips/${T}`), tripDoc(over)));
  };
  const newDestination = { name: 'Ipoh', coordinate: new GeoPoint(4.6, 101.1) };
  describe('started, with stops', () => {
    beforeEach(() => seedTrip({ startedAt: ts(60000), stopCount: 2 }));
    // D25 4d: the organizer rebuilds the route mid-trip (a new destination, or a stop skipped for everyone).
    it('the organizer can change the route and the destination', async () => {
      await assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { route: '_p~iF~ps|U_ulLnnqC', routeSeconds: 100 }));
      await assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { destination: newDestination, route: '_ulLnnqC_p~iF~ps|U' }));
    });
    it('a member who is not the organizer cannot change the route or the destination', async () => {
      await assertFails(updateDoc(doc(db('mem'), `trips/${T}`), { route: '_p~iF~ps|U_ulLnnqC' }));
      await assertFails(updateDoc(doc(db('mem'), `trips/${T}`), { destination: newDestination }));
    });
    it('the organizer cannot change the stop count', async () => {
      await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { stopCount: 0 }));
      await assertFails(updateDoc(doc(db('org'), `trips/${T}`), { route: '_p~iF~ps|U_ulLnnqC', stopCount: 3 }));
    });
    it('the organizer can still rename and end the trip', async () => {
      await assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { name: 'New name' }));
      await assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { status: 'ended', endedAt: serverTimestamp() }));
    });
  });
  describe('started, without stops', () => {
    it('the destination can still change (stopCount 0 or absent)', async () => {
      await seedTrip({ startedAt: ts(60000), stopCount: 0 });
      await assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { destination: newDestination, route: '_p~iF~ps|U_ulLnnqC' }));
      await seedTrip({ startedAt: ts(60000) });
      await assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { destination: newDestination }));
    });
  });
  describe('not started, with stops', () => {
    beforeEach(() => seedTrip({ stopCount: 2 }));
    it('the route, destination and stop count can change', async () => {
      await assertSucceeds(updateDoc(doc(db('org'), `trips/${T}`), { destination: newDestination, route: '_p~iF~ps|U_ulLnnqC', stopCount: 3 }));
    });
    it('the stop count must be a whole number', () =>
      assertFails(updateDoc(doc(db('org'), `trips/${T}`), { stopCount: 'two' })));
    it('a member who is not the organizer cannot set it', () =>
      assertFails(updateDoc(doc(db('mem'), `trips/${T}`), { stopCount: 0 })));
  });
});
