import { after, before, beforeEach, describe, it } from 'node:test';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  Timestamp,
  GeoPoint,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
  updateDoc,
  writeBatch,
} from 'firebase/firestore';

const here = dirname(fileURLToPath(import.meta.url));
const T = 'trip1';
let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-ikut-rules',
    firestore: {
      rules: readFileSync(join(here, '../firestore.rules'), 'utf8'),
      host: '127.0.0.1',
      port: 8080,
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
  it('delete always fails (organizer)', () => assertFails(deleteDoc(doc(db('org'), `trips/${T}`))));
  it('delete always fails (member)', () => assertFails(deleteDoc(doc(db('mem'), `trips/${T}`))));
});

describe('members', () => {
  beforeEach(() => seed());
  it('user cannot create member doc for someone else\'s trip', () =>
    assertFails(setDoc(doc(db('stranger'), `trips/${T}/members/stranger`), memberDoc())));
  it('user cannot self-join as organizer of someone else\'s trip', () =>
    assertFails(setDoc(doc(db('stranger'), `trips/${T}/members/stranger`), memberDoc({ role: 'organizer' }))));
  it('organizer cannot create a member doc for another user', () =>
    assertFails(setDoc(doc(db('org'), `trips/${T}/members/stranger`), memberDoc())));
  it('member can change displayName, carId, pushToken', () =>
    assertSucceeds(updateDoc(doc(db('mem'), `trips/${T}/members/mem`), { displayName: 'Sammy', carId: 'carB', pushToken: 'tok' })));
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
  it('claim tracker when free succeeds', () => assertSucceeds(updateDoc(car('carB'), { trackerUserId: 'mem' })));
  it('steal tracker when taken fails', () =>
    assertFails(updateDoc(doc(db('other'), `trips/${T}/cars/carA`), { trackerUserId: 'other' })));
  it('claim tracker for someone else fails', () => assertFails(updateDoc(car('carB'), { trackerUserId: 'other' })));
  it('tracker can release', () => assertSucceeds(updateDoc(car('carA'), { trackerUserId: null })));
  it('non-tracker cannot release', () =>
    assertFails(updateDoc(doc(db('other'), `trips/${T}/cars/carA`), { trackerUserId: null })));
  it('tracker can change route, mergeOffset, state', () =>
    assertSucceeds(updateDoc(car('carA'), { route: 'abc', mergeOffset: 12.5, state: 'convoy' })));
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
