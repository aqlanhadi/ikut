// The convoy's stopped phase (D122) and what a tracker phone does in it (D124), ported from the app.
//
//   CAP, current, MoveOff <- ios/ikut/Stops/ConvoyStop.swift            (90 minute cap, lead car moves off)
//   RestTracker           <- ios/ikut/Tracking/TrackingService.swift    (handle, noteMovement, armRestTimer: low power after
//                                                                        120 s at rest in a stopped phase, full on a move)
//
// Time is in seconds on the scenario clock (`at`); a trip's `stoppedAt` is in the same unit here.

import { haversine } from './route.mjs';

export const CAP = 90 * 60; // ConvoyStop.cap
export const MOVE_OFF_DISTANCE = 500;
export const SETTLE_TIME = 120;
export const REST_RADIUS = 100;
export const UNSETTLED_MOVE_OFF = 2_000;
export const PARKED_SPEED = 20 / 3.6; // ConvoyOrdering.Config.default.parkedSpeed

/** ConvoyStop.current: the phase in effect at `now`, null when none (never stopped, Continue, ended trip, or past the cap). */
export function current(trip, now) {
  if (!trip || trip.status !== 'active' || trip.stoppedAt == null || now - trip.stoppedAt >= CAP) return null;
  return { since: trip.stoppedAt, by: trip.stoppedBy ?? null, eventId: trip.stoppedEventId ?? null };
}

/** Who may start and end it (ConvoyStop.mayStartOrEnd). */
export const mayStartOrEnd = ({ isLeadTracker, isOrganizer }) => Boolean(isLeadTracker || isOrganizer);

/** ConvoyStop.MoveOff: says true once when the lead car has moved off; see the Swift doc comment. */
export class MoveOff {
  constructor() { this.reset(); }

  reset() {
    this.phase = null; this.first = null; this.rest = null; this.anchor = null; this.fired = false;
  }

  /** phase: the trip's stoppedAt or null; here {latitude, longitude}; moving: a fresh fix faster than PARKED_SPEED. */
  check({ phase, here, at, moving }) {
    if (phase == null) { this.reset(); return false; }
    if (this.phase !== phase) { this.reset(); this.phase = phase; }
    this.first ??= here;
    if (!moving) {
      if (this.rest && haversine(this.rest.at, here) <= REST_RADIUS) {
        if (at - this.rest.since >= SETTLE_TIME) this.anchor = this.rest.at;
      } else {
        this.rest = { at: here, since: at };
      }
      return false;
    }
    this.rest = null;
    const from = this.anchor ?? this.first;
    if (this.fired || !from) return false;
    const limit = this.anchor ? MOVE_OFF_DISTANCE : UNSETTLED_MOVE_OFF;
    this.fired = haversine(from, here) > limit;
    return this.fired;
  }
}

/**
 * The tracker's power while a stopped phase is on (TrackingService): at rest `SETTLE_TIME` after the phase began, or after
 * the last move, it drops to low power; a fix that moved, or Continue, brings full back at once. `onPower(low)` is called
 * on each change (the publisher's setLowPower). `urgent` for the publisher is what `fix()` returns.
 */
export class RestTracker {
  constructor({ onPower }) {
    this.onPower = onPower;
    this.stopped = false;
    this.low = false;
    this.anchor = null;
    this.deadline = null;
  }

  setConvoyStopped(stopped, now) {
    if (stopped === this.stopped) return;
    this.stopped = stopped;
    if (stopped) this.deadline = now + SETTLE_TIME;
    else { this.deadline = null; this.#set(false, now); }
  }

  /** A fix at `now`; returns `urgent` for PositionPublisher.submit (TrackingService.handle). */
  fix({ latitude, longitude, speed }, now) {
    this.tick(now);
    const here = { latitude, longitude };
    if (!this.stopped) { this.anchor = here; return true; }
    const speeding = speed >= PARKED_SPEED;
    let moved;
    if (!this.anchor) { this.anchor = here; moved = speeding; }
    else if (!speeding && haversine(this.anchor, here) <= REST_RADIUS) moved = false;
    else { this.anchor = here; if (!this.low) this.deadline = now + SETTLE_TIME; moved = true; }
    const urgent = !this.low || moved;
    if (moved && this.low) this.#set(false, now);
    return urgent;
  }

  /** The rest timer (armRestTimer / restTimerFired). */
  tick(now) {
    if (this.stopped && !this.low && this.deadline !== null && now >= this.deadline) this.#set(true, now);
  }

  #set(low, now) {
    if (low === this.low) return;
    this.low = low;
    this.onPower(low);
    this.deadline = !low && this.stopped ? now + SETTLE_TIME : null; // full again in a phase: the timer is re-armed
  }
}

/**
 * A car that drives from `startOffset` at `speed` m/s to `parkAt`, sits there until `resumeAt`, then drives on at the same
 * speed; 1 Hz, as readGpx gives it: [{latitude, longitude, t}].
 */
export function stopAndGoTrack(line, { startOffset, speed, parkAt, resumeAt, seconds }) {
  return Array.from({ length: seconds + 1 }, (_, t) => {
    const offset = t < resumeAt ? Math.min(parkAt, startOffset + speed * t) : parkAt + speed * (t - resumeAt);
    return { ...line.coordinateAtOffset(Math.min(line.length, offset)), t };
  });
}
