// What a tracker phone does with a fix, ported from the app.
//
//   PositionBuilder   <- ios/ikut/Tracking/PositionBuilder.swift   (routeOffset, convoyOffset, heading, speed, battery)
//   PositionPublisher <- ios/ikut/Tracking/PositionPublisher.swift (5 s throttle, one write in flight, latest-only, heartbeat)
//   ApproachCore      <- ios/ikut/Hazards/ApproachMonitor.swift    (500 m approach alert, once per event)
//   hazard visibility <- ios/ikut/Hazards/HazardLogic.swift        (isPassedByAll, for expectations only)
//
// Time is injected (`now` in seconds on the scenario clock), so the same code runs at 1x or 10x.

import { RouteLine } from './route.mjs';

// ---------------------------------------------------------------- PositionBuilder

export class PositionBuilder {
  /** @param main RouteLine, @param own RouteLine|null (the car's own route, nil when on the main route) */
  constructor(main, own = null) {
    this.main = main;
    this.lastValidHeading = 0;
    this.ownHint = null;
    this.mainHint = null;
    if (own && !own.isEmpty) {
      this.own = own;
      const m = main.mergeOffset(own);
      this.ownMergeOffset = m ? m.otherOffset : null;
      this.hasMerged = false;
    } else {
      this.own = null;
      this.ownMergeOffset = null;
      this.hasMerged = true;
    }
  }

  /** fix: {latitude, longitude, speed, course}. Returns the Position fields (no updatedAt; the writer adds the server timestamp). */
  build(fix, battery = null) {
    let routeOffset;
    let convoyOffset = null;
    if (this.own) {
      const p = this.own.project(fix, { hint: this.ownHint });
      this.ownHint = p ? p.segmentIndex : null;
      routeOffset = p ? p.offset : 0;
      if (!this.hasMerged && this.ownMergeOffset !== null && routeOffset >= this.ownMergeOffset) this.hasMerged = true;
      if (this.hasMerged) convoyOffset = this.#projectMain(fix);
    } else {
      const offset = this.#projectMain(fix);
      routeOffset = offset;
      convoyOffset = offset;
    }
    const position = {
      latitude: fix.latitude,
      longitude: fix.longitude,
      speed: PositionBuilder.speed(fix.speed),
      heading: this.#heading(fix.course),
      routeOffset: Math.max(0, routeOffset),
      battery,
    };
    if (convoyOffset !== null) position.convoyOffset = Math.max(0, convoyOffset);
    return position;
  }

  #projectMain(c) {
    const p = this.main.project(c, { hint: this.mainHint });
    this.mainHint = p ? p.segmentIndex : null;
    return p ? p.offset : 0;
  }

  static speed(raw) {
    return Number.isFinite(raw) ? Math.max(0, raw) : 0;
  }

  #heading(course) {
    if (Number.isFinite(course) && course >= 0) this.lastValidHeading = course % 360;
    return this.lastValidHeading;
  }
}

// ---------------------------------------------------------------- PositionPublisher

export const DEFAULT_TIMING = { minInterval: 5, movingInterval: 10, heartbeatInterval: 30, movingSpeed: 1 };

/**
 * Decides when positions are written. Same state machine as the Swift class:
 * one write in flight (a write is "in flight" until its promise resolves, which for the Firestore
 * client means the server acknowledged it, so it stays in flight while the network is off),
 * latest-only, at most one write per minInterval for a new fix, a heartbeat re-write otherwise.
 */
export class PositionPublisher {
  /** @param write async (position) => void   @param now () => seconds on the scenario clock */
  constructor({ write, now, timing = DEFAULT_TIMING }) {
    this.write = write;
    this.now = now;
    this.timing = timing;
    this.latest = null;
    this.dirty = false;
    this.lastSendAt = null;
    this.inFlight = false;
    this.writeCount = 0;
    this.stopped = false;
  }

  submit(position) {
    if (this.stopped) return;
    this.latest = position;
    this.dirty = true;
    this.evaluate();
  }

  /** Call on every scenario tick: replaces the Swift wake-up task. */
  tick() { this.evaluate(); }

  stop() {
    this.stopped = true;
    this.latest = null;
    this.dirty = false;
  }

  evaluate() {
    if (this.stopped || this.inFlight || !this.latest) return;
    const now = this.now();
    let due;
    if (this.lastSendAt !== null) {
      if (this.dirty) {
        due = this.lastSendAt + this.timing.minInterval;
      } else {
        const moving = this.latest.speed >= this.timing.movingSpeed;
        due = this.lastSendAt + (moving ? this.timing.movingInterval : this.timing.heartbeatInterval);
      }
    } else {
      due = now;
    }
    if (now >= due) this.#send(this.latest, now);
  }

  #send(position, now) {
    this.inFlight = true;
    this.dirty = false;
    this.lastSendAt = now;
    this.writeCount += 1;
    this.write(position).then(
      () => this.#finished(false),
      (error) => { this.lastError = error; this.#finished(true); },
    );
  }

  #finished(failed) {
    this.inFlight = false;
    if (this.stopped) return;
    if (failed) this.dirty = true;
    this.evaluate();
  }
}

// ---------------------------------------------------------------- ApproachCore

/** One alert per event per stage, fired when the event is within `alertDistance` ahead. */
export class ApproachCore {
  constructor({ alertDistance = 500, nowDistance = null } = {}) {
    this.alertDistance = alertDistance;
    this.nowDistance = nowDistance;
    this.fired = new Map();
  }

  /** candidates: [{id, offset}]. Returns [{id, stage, distance}]. */
  evaluate(candidates, myOffset) {
    const result = [];
    for (const c of candidates) {
      const distance = c.offset - myOffset;
      if (!(distance > 0)) continue;
      const done = this.fired.get(c.id) ?? new Set();
      if (this.nowDistance !== null && distance <= this.nowDistance && !done.has('now')) {
        done.add('now');
        done.add('approach');
        result.push({ id: c.id, stage: 'now', distance });
      } else if (distance <= this.alertDistance && !done.has('approach')) {
        done.add('approach');
        result.push({ id: c.id, stage: 'approach', distance });
      }
      this.fired.set(c.id, done);
    }
    return result;
  }
}

/** AlertWording.distanceText: rounded to 50 m below a km. */
export function distanceText(meters) {
  if (meters >= 1000) {
    const km = Math.round(meters / 100) / 10;
    return km === Math.round(km) ? `${Math.round(km)} km` : `${km} km`;
  }
  const rounded = Math.max(50, Math.round(meters / 50) * 50);
  return `${rounded} meters`;
}

export { RouteLine };
