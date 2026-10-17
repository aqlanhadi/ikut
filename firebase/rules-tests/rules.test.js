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
  deleteField,
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

// Stop requests: votes per car, pinned place, resolve. Seed: 'mem' is on carA (author),
// 'other' on carB, 'org' (organizer) on carO. Lead car is carO, tracked by 'lead' (a member of carO's
// trip with their own member doc pointing at carO) unless a test says otherwise.
describe('stop requests', () => {
  const stop = (over = {}) => event({ type: 'stopFuel', category: 'stopRequest', severity: 'medium', ...over });
  const place = (over = {}) => ({ name: 'R&R Tapah', coordinate: pt, routeOffset: 18000, pinnedBy: 'lead', ...over });
  const evRef = (uid, id = 'stop1') => doc(db(uid), `trips/${T}/events/${id}`);
  const voteRef = (uid, carId, id = 'stop1') => doc(db(uid), `trips/${T}/events/${id}/votes/${carId}`);
  const vote = (uid, over = {}) => ({ userId: uid, agree: true, at: serverTimestamp(), ...over });

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

  describe('votes', () => {
    it('member votes for own car', () => assertSucceeds(setDoc(voteRef('mem', 'carA'), vote('mem'))));
    it('member can change own car vote', async () => {
      await assertSucceeds(setDoc(voteRef('mem', 'carA'), vote('mem')));
      await assertSucceeds(setDoc(voteRef('mem', 'carA'), vote('mem', { agree: false })));
    });
    it('another member of the same car can update the car vote', async () => {
      await env.withSecurityRulesDisabled(async (c) => {
        await setDoc(doc(c.firestore(), `trips/${T}/members/mate`), memberDoc({ displayName: 'Mate' }));
      });
      await assertSucceeds(setDoc(voteRef('mem', 'carA'), vote('mem')));
      await assertSucceeds(setDoc(voteRef('mate', 'carA'), vote('mate', { agree: false })));
    });
    it('member cannot vote for another car', () => assertFails(setDoc(voteRef('mem', 'carB'), vote('mem'))));
    it('userId must be the caller', () => assertFails(setDoc(voteRef('mem', 'carA'), vote('other'))));
    it('agree must be a bool', () => assertFails(setDoc(voteRef('mem', 'carA'), vote('mem', { agree: 'yes' }))));
    it('extra field fails', () => assertFails(setDoc(voteRef('mem', 'carA'), vote('mem', { weight: 5 }))));
    it('missing field fails', () => {
      const v = vote('mem');
      delete v.agree;
      return assertFails(setDoc(voteRef('mem', 'carA'), v));
    });
    it('client timestamp fails', () => assertFails(setDoc(voteRef('mem', 'carA'), vote('mem', { at: ts() }))));
    it('non-member cannot vote', () => assertFails(setDoc(voteRef('stranger', 'carA'), vote('stranger'))));
    it('cannot vote on a resolved stop', () => assertFails(setDoc(voteRef('mem', 'carA', 'stopDone'), vote('mem'))));
    it('cannot vote on a non-stop event', () => assertFails(setDoc(voteRef('mem', 'carA', 'ev1'), vote('mem'))));
    it('cannot vote on a missing event', () => assertFails(setDoc(voteRef('mem', 'carA', 'nope'), vote('mem'))));
    it('cannot vote on an ended trip', async () => {
      await seed({ ended: true });
      await env.withSecurityRulesDisabled(async (c) => {
        await setDoc(doc(c.firestore(), `trips/${T}/events/stop1`), stop());
      });
      await assertFails(setDoc(voteRef('mem', 'carA'), vote('mem')));
    });
    it('vote may carry a suggested place', () =>
      assertSucceeds(setDoc(voteRef('mem', 'carA'), vote('mem', { suggestion: { name: 'Petronas', coordinate: pt, routeOffset: 1000 } }))));
    it('suggestion with pinnedBy fails', () =>
      assertFails(setDoc(voteRef('mem', 'carA'), vote('mem', { suggestion: { name: 'P', coordinate: pt, routeOffset: 1, pinnedBy: 'mem' } }))));
    it('suggestion with empty name fails', () =>
      assertFails(setDoc(voteRef('mem', 'carA'), vote('mem', { suggestion: { name: '', coordinate: pt, routeOffset: 1 } }))));
    it('suggestion with bad coordinate fails', () =>
      assertFails(setDoc(voteRef('mem', 'carA'), vote('mem', { suggestion: { name: 'P', coordinate: 'here', routeOffset: 1 } }))));
    it('member can read votes', async () => {
      await assertSucceeds(setDoc(voteRef('mem', 'carA'), vote('mem')));
      await assertSucceeds(getDocs(collection(db('other'), `trips/${T}/events/stop1/votes`)));
    });
    it('non-member cannot read votes', () =>
      assertFails(getDocs(collection(db('stranger'), `trips/${T}/events/stop1/votes`))));
    it('votes cannot be deleted', async () => {
      await assertSucceeds(setDoc(voteRef('mem', 'carA'), vote('mem')));
      await assertFails(deleteDoc(voteRef('mem', 'carA')));
    });
  });

  describe('pinned place', () => {
    it('lead car tracker can pin', () => assertSucceeds(updateDoc(evRef('lead'), { place: place() })));
    it('organizer can pin', () => assertSucceeds(updateDoc(evRef('org'), { place: place({ pinnedBy: 'org' }) })));
    it('lead can re-pin a different place', async () => {
      await assertSucceeds(updateDoc(evRef('lead'), { place: place() }));
      await assertSucceeds(updateDoc(evRef('lead'), { place: place({ name: 'Other R&R' }) }));
    });
    it('non-lead member cannot pin', () => assertFails(updateDoc(evRef('other'), { place: place({ pinnedBy: 'other' }) })));
    it('stop author who is not lead cannot pin', () => assertFails(updateDoc(evRef('mem'), { place: place({ pinnedBy: 'mem' }) })));
    it('non-member cannot pin', () => assertFails(updateDoc(evRef('stranger'), { place: place({ pinnedBy: 'stranger' }) })));
    it('a lead flag on a car someone else tracks does not grant pinning', async () => {
      await env.withSecurityRulesDisabled(async (c) => {
        await setDoc(doc(c.firestore(), `trips/${T}/cars/carO`), carDoc({ isLead: true, trackerUserId: 'someoneElse' }));
      });
      await assertFails(updateDoc(evRef('lead'), { place: place() }));
    });
    it('pinnedBy must be the caller', () => assertFails(updateDoc(evRef('lead'), { place: place({ pinnedBy: 'org' }) })));
    it('empty name fails', () => assertFails(updateDoc(evRef('lead'), { place: place({ name: '' }) })));
    it('name over 100 chars fails', () => assertFails(updateDoc(evRef('lead'), { place: place({ name: 'x'.repeat(101) }) })));
    it('coordinate must be a geopoint', () =>
      assertFails(updateDoc(evRef('lead'), { place: place({ coordinate: { lat: 1, lng: 2 } }) })));
    it('negative routeOffset fails', () => assertFails(updateDoc(evRef('lead'), { place: place({ routeOffset: -1 }) })));
    it('extra place field fails', () => assertFails(updateDoc(evRef('lead'), { place: place({ rating: 5 }) })));
    it('place with missing field fails', () => {
      const p = place();
      delete p.routeOffset;
      return assertFails(updateDoc(evRef('lead'), { place: p }));
    });
    it('place must be a map', () => assertFails(updateDoc(evRef('lead'), { place: 'Tapah' })));
    it('cannot pin and change another field in one write', () =>
      assertFails(updateDoc(evRef('lead'), { place: place(), message: 'hi' })));
    it('cannot pin a resolved stop', () => assertFails(updateDoc(evRef('lead', 'stopDone'), { place: place() })));
    it('cannot pin a hazard event', () => assertFails(updateDoc(evRef('lead', 'ev1'), { place: place() })));
    it('cannot pin on an ended trip', async () => {
      await seed({ ended: true });
      await env.withSecurityRulesDisabled(async (c) => {
        const f = c.firestore();
        await setDoc(doc(f, `trips/${T}/members/lead`), memberDoc({ carId: 'carO' }));
        await setDoc(doc(f, `trips/${T}/cars/carO`), carDoc({ isLead: true, trackerUserId: 'lead' }));
        await setDoc(doc(f, `trips/${T}/events/stop1`), stop());
      });
      await assertFails(updateDoc(evRef('lead'), { place: place() }));
    });
    it('place cannot be supplied when creating the stop', () =>
      assertFails(setDoc(evRef('mem', 'new'), stop({ place: place({ pinnedBy: 'mem' }) }))));
    it('member can create a stop request', () => assertSucceeds(setDoc(evRef('mem', 'new'), stop())));
  });

  describe('resolve', () => {
    it('author can resolve', () => assertSucceeds(updateDoc(evRef('mem'), { expiresAt: ts() })));
    it('organizer can resolve', () => assertSucceeds(updateDoc(evRef('org'), { expiresAt: ts() })));
    it('lead car tracker can resolve', () => assertSucceeds(updateDoc(evRef('lead'), { expiresAt: ts() })));
    it('other member cannot resolve', () => assertFails(updateDoc(evRef('other'), { expiresAt: ts() })));
    it('non-member cannot resolve', () => assertFails(updateDoc(evRef('stranger'), { expiresAt: ts() })));
    it('organizer cannot expire a hazard they did not author', () =>
      assertFails(updateDoc(evRef('org', 'ev1'), { expiresAt: ts() })));
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
