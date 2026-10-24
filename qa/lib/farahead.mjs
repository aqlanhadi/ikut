// A car far ahead on the route (D26), ported from the app. Everyone on the route is in the convoy however far
// ahead; distance only changes the words.
//
//   referenceId        <- ios/ikut/Convoy/ConvoyOrdering.swift  (referenceIndex: who the arrival time comes from)
//   togetherPairs      <- ios/ikut/Convoy/ConvoyOrdering.swift  (togetherPairs: cars within 5 km and 5 min)
//   driftedGaps        <- ios/ikut/Convoy/ConvoyOrdering.swift  (order: Gap.hasDrifted, the separation warning)
//   CatchUpHeadsUp     <- ios/ikut/Alerts/CatchUpHeadsUp.swift  (a car parked ahead hears ~2 min before the next car;
//                                                               phrase uses shortName from Map/MapLogic.swift)
//   relativeDistance   <- ios/ikut/Convoy/ConvoyFormat.swift    ("40 km behind", over 2 km only)
//   kmText             <- ios/ikut/Convoy/ConvoyFormat.swift    (distance)
//   spokenStopRequest  <- ios/ikut/Alerts/AlertWording.swift    (spokenStopRequest with far)
//   catchUpSpoken      <- ios/ikut/Alerts/AlertWording.swift    (catchUp spoken line)
//
// Speeds: the app smooths each car's speed (SpeedSmoother); the sim uses the position's own speed, which its
// PositionBuilder already smooths over the last fixes.

import { distanceText } from './tracking.mjs';

export const CONFIG = {
  minSpeed: 5, // ConvoyOrdering.Config.minSpeed, m/s
  staleAfter: 60, // s
  separationDistance: 5000, // m
  separationTime: 300, // s
  groupRadius: 2000, // m
  parkedSpeed: 20 / 3.6, // m/s
};
export const LEAD_TIME = 120; // CatchUpHeadsUp.leadTime, s
export const REARM_DISTANCE = 1000; // CatchUpHeadsUp.rearmDistance, m

const pairKey = (a, b) => (a < b ? `${a}|${b}` : `${b}|${a}`);

/**
 * The convoy as ConvoyOrdering.order builds it, front first. cars: [{id, name, isLead, offset, speed, age,
 * paused, arrived}] (speed m/s unfloored, age s since the server time). Returns entries with movingSpeed, speed
 * (floored), isFresh, isParked.
 */
export function entries(cars, config = CONFIG) {
  return cars
    .map((c) => {
      const moving = Math.max(0, Number.isFinite(c.speed) ? c.speed : 0);
      return {
        ...c,
        movingSpeed: moving,
        speed: Math.max(config.minSpeed, moving),
        isFresh: !c.paused && (c.age ?? 0) <= config.staleAfter,
        isParked: moving < config.parkedSpeed,
      };
    })
    .sort((a, b) => b.offset - a.offset || (a.id < b.id ? -1 : 1));
}

/** ConvoyOrdering.togetherPairs: pairs (as keys) of fresh cars within the separation threshold right now. */
export function togetherPairs(convoy, config = CONFIG) {
  const pairs = new Set();
  const fresh = convoy.filter((e) => e.isFresh);
  for (let i = 0; i < fresh.length; i++) {
    for (let j = i + 1; j < fresh.length; j++) {
      const distance = fresh[i].offset - fresh[j].offset;
      if (distance > config.separationDistance) break;
      if (distance / fresh[j].speed <= config.separationTime) pairs.add(pairKey(fresh[i].id, fresh[j].id));
    }
  }
  return pairs;
}

/** ConvoyOrdering.isApart: `behind` over the threshold from `ahead`. */
const isApart = (ahead, behind, config) => {
  const distance = ahead.offset - behind.offset;
  return distance > config.separationDistance || distance / behind.speed > config.separationTime;
};

/**
 * ConvoyOrdering.order, the separation part: the ids of cars behind a gap over the threshold where a car ahead of
 * the gap and a car behind it are in `together` (kept across refreshes, this one included) and apart now.
 */
export function driftedGaps(convoy, together, config = CONFIG) {
  const out = [];
  for (let i = 1; i < convoy.length; i++) {
    const distance = convoy[i - 1].offset - convoy[i].offset;
    const separated = distance > config.separationDistance || distance / convoy[i].speed > config.separationTime;
    if (!separated) continue;
    const drifted = convoy.slice(0, i).some((a) =>
      convoy.slice(i).some((b) => together.has(pairKey(a.id, b.id)) && isApart(a, b, config)));
    if (drifted) out.push(convoy[i].id);
  }
  return out;
}

/** ConvoyOrdering.referenceIndex: the fresh lead, else the fresh car with most fresh cars within 2 km (further back on a tie). */
export function referenceId(convoy, config = CONFIG) {
  const candidates = convoy.filter((e) => e.isFresh && !e.arrived);
  const lead = candidates.find((e) => e.isLead);
  if (lead) return lead.id;
  let best = null;
  for (const e of candidates) {
    const count = candidates.filter((o) => o !== e && Math.abs(o.offset - e.offset) <= config.groupRadius).length;
    if (count >= (best?.count ?? -1)) best = { id: e.id, count };
  }
  return best?.id ?? null;
}

/** ConvoyFormat.distance: "850 m", "1.8 km", "84 km". */
export function kmText(meters) {
  const m = Math.max(0, Number.isFinite(meters) ? meters : 0);
  if (m < 1000) return `${Math.round(m / 10) * 10} m`;
  const km = m / 1000;
  if (km < 10) return `${(Math.round(km * 10) / 10).toFixed(1)} km`;
  return `${Math.round(km)} km`;
}

/** ConvoyFormat.relativeDistance: "38 km ahead" / "40 km behind" over `beyond`, else null. */
export function relativeDistance(meters, beyond = 2000) {
  if (!Number.isFinite(meters) || Math.abs(meters) <= beyond) return null;
  return `${kmText(Math.abs(meters))} ${meters > 0 ? 'ahead' : 'behind'}`;
}

const NEED = { stopFuel: 'needs fuel', stopFood: 'needs food', stopToilet: 'needs a toilet break' };

/** AlertWording.spokenStopRequest: "Hafiz needs fuel, 17 km behind. Tap OK." */
export function spokenStopRequest(type, authorName, far = null) {
  const who = authorName?.trim() || 'Another car';
  return `${who} ${NEED[type] ?? 'needs a rest'}${far ? `, ${far}` : ''}. Tap OK.`;
}

/** CatchUpHeadsUp.phrase with MapMarkerBuilder.shortName (Map/MapLogic.swift): "Aisha’s car" for "Aisha’s Myvi". */
export function carPhrase(carName) {
  for (const marker of ['’s ', "'s "]) {
    const i = carName.indexOf(marker);
    const head = i >= 0 ? carName.slice(0, i).trim() : '';
    if (head) return `${head}’s car`;
  }
  return carName;
}

/** AlertWording.catchUp spoken line. */
export const catchUpSpoken = (due) => `${due.carPhrase} is ${distanceText(due.distance, true)} behind you.`;

/**
 * CatchUpHeadsUp: once per stop, after the car behind was seen more than LEAD_TIME away; re-armed once my car
 * has driven on more than REARM_DISTANCE from where it fired. One instance per phone (my car, one trip).
 */
export class CatchUpHeadsUp {
  constructor() {
    this.seenFar = new Set();
    this.firedAt = null;
    this.stops = 0;
  }

  /** CatchUpHeadsUp.nearestBehind. */
  static nearestBehind(convoy, myCarId, config = CONFIG) {
    const i = convoy.findIndex((e) => e.id === myCarId);
    if (i < 0) return null;
    const me = convoy[i];
    if (!me.isFresh || me.arrived || !me.isParked) return null;
    const behind = convoy.slice(i + 1).find((e) => e.isFresh && e.movingSpeed >= config.parkedSpeed);
    if (!behind) return null;
    const distance = Math.max(0, me.offset - behind.offset);
    return { carId: behind.id, carPhrase: carPhrase(behind.name), distance, seconds: distance / behind.movingSpeed };
  }

  check(convoy, myCarId, config = CONFIG) {
    if (this.firedAt !== null) {
      const me = convoy.find((e) => e.id === myCarId);
      if (!me || me.offset - this.firedAt <= REARM_DISTANCE) return null;
      this.firedAt = null;
      this.seenFar.clear();
    }
    const due = CatchUpHeadsUp.nearestBehind(convoy, myCarId, config);
    if (!due) return null;
    if (due.seconds > LEAD_TIME) {
      this.seenFar.add(due.carId);
      return null;
    }
    if (!this.seenFar.has(due.carId)) return null;
    this.firedAt = convoy.find((e) => e.id === myCarId).offset;
    this.stops += 1;
    return { ...due, stop: this.stops };
  }
}
