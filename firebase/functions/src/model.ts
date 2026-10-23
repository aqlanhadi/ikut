import type { GeoPoint, Timestamp } from "firebase-admin/firestore";

/** What the idle and retention checks need from a Timestamp, so tests can pass plain stand-ins. */
export interface TimestampLike {
  toMillis(): number;
}

/** Firestore document shapes. Mirrors ios/ikut/Model. Routes are encoded polylines (precision 5). */

export type TripStatus = "active" | "ended";
export type CarState = "joining" | "convoy";
export type MemberRole = "organizer" | "member";
export type EventCategory = "hazard" | "condition" | "stopRequest" | "status" | "message";
export type Severity = "high" | "medium" | "low";

export type KnownEventType =
  | "debris" | "accident" | "pothole" | "animal" | "stoppedVehicle" | "roadworks"
  | "heavyRain" | "trafficJam"
  | "stopRest" | "stopFuel" | "stopFood" | "stopToilet"
  | "pullingOver" | "carTrouble" | "runningLate"
  | "message";

/** Unknown strings are allowed: new types may be added via config. */
export type EventType = KnownEventType | (string & {});

export interface Destination {
  name: string;
  coordinate: GeoPoint;
}

/** trips/{tripId} */
export interface Trip {
  name: string;
  /** 6-character join code. */
  code: string;
  organizerId: string;
  route: string;
  destination: Destination;
  /** Driving time in seconds along `route`, the legs added up when it goes through stops; absent on older trips. */
  routeSeconds?: number;
  /** How many planned stops the trip has (the stops subcollection can't be counted in rules). Absent means none. */
  stopCount?: number;
  status: TripStatus;
  createdAt: Timestamp;
  lastActivityAt?: Timestamp;
  /** First Start Trip by any member; absent until the trip is underway. */
  startedAt?: Timestamp;
  endedAt?: Timestamp;
}

export type PlannedStopKind = "meet" | "fuel" | "food" | "rest" | "toilet" | "sight";

/**
 * trips/{tripId}/stops/{stopId}: a place on the main route that cars arrive at and leave.
 * The organizer writes them before `startedAt`; afterwards only `skipped`, `skippedBy`, `skippedAt` change.
 * A stop chosen mid-trip (D4) is meant to be a document of the same shape.
 */
export interface PlannedStop {
  name: string;
  coordinate: GeoPoint;
  /** Meters along the trip's main route. */
  routeOffset: number;
  kind: PlannedStopKind;
  /** Planned length in minutes; never on a meeting point. */
  minutes?: number;
  /** When to meet; only on a `meet` stop. */
  meetAt?: Timestamp;
  note?: string;
  /** 0-based place in the list; a `meet` stop is always 0. */
  order: number;
  skipped?: boolean;
  skippedBy?: string;
  skippedAt?: Timestamp;
}

/** What a car said about a stop. D25 5a writes 'skip' ("we'll skip this stop"); D4 adds 'carryOn' to the same document. */
export type StopAnswerKind = 'skip';

/**
 * trips/{tripId}/stops/{stopId}/answers/{carId}: a car's answer about one stop; one per car (the id is the car id,
 * so a second phone in the car writes the same document). Undo deletes it. Same shape as a stop vote.
 */
export interface StopAnswer {
  answer: StopAnswerKind;
  /** Who tapped it for the car. */
  userId: string;
  /** Server time. */
  at: Timestamp;
}

/** trips/{tripId}/cars/{carId} */
export interface Car {
  name: string;
  color: string;
  trackerUserId?: string;
  isLead: boolean;
  route?: string;
  /** Meters along the main route where this car joins it. */
  mergeOffset?: number;
  state: CarState;
  /** Badge number shown on the map and in lists; 1 is the organizer's car, then highest existing + 1. */
  number?: number;
  /** When the tracker paused sharing; absent when sharing. */
  pausedAt?: Timestamp;
}

/** trips/{tripId}/members/{userId} */
export interface Member {
  displayName: string;
  carId: string;
  role: MemberRole;
  pushToken?: string;
}

/** trips/{tripId}/positions/{carId} */
export interface Position {
  location: GeoPoint;
  /** m/s */
  speed: number;
  /** degrees */
  heading: number;
  /** Meters along the car's own route. */
  routeOffset: number;
  /** Meters along the main route; absent until merged. */
  convoyOffset?: number;
  /** 0..1 */
  battery?: number;
  updatedAt: Timestamp;
}

/** trips/{tripId}/events/{eventId} */
export interface TripEvent {
  type: EventType;
  category: EventCategory;
  severity: Severity;
  location: GeoPoint;
  heading: number;
  /** Meters along the reporting car's route. */
  routeOffset: number;
  authorId: string;
  carId: string;
  createdAt: Timestamp;
  /** Absent means it lasts until resolved or cleared. A stop request is written with createdAt + 30 min. */
  expiresAt?: Timestamp;
  /** A stop request's optional note from a passenger (0 to 280 characters). */
  message?: string;
  /** Stop requests only. Absent (an old event) reads as open. */
  status?: StopStatus;
  /** Set only when a stop request closes, with closedBy (a user id) and expiresAt = now. */
  closedReason?: StopClosedReason;
  closedBy?: string;
}

export type StopStatus = 'open' | 'closed';
/** The asker, the lead car or the organizer says the convoy has stopped; or the asker cancels. */
export type StopClosedReason = 'stopped' | 'cancelled';

/** trips/{tripId}/events/{eventId}/votes/{carId}: a car's OK; one per car. */
export interface StopVote {
  /** Who tapped OK for the car. */
  userId: string;
  at: Timestamp;
}

/** previewTrip callable result: what a non-member may see before joining. */
export interface PreviewCar {
  id: string;
  name: string;
  color: string;
  hasTracker: boolean;
  number?: number;
}

/** One planned stop on the ticket: only what a stranger with the code needs. Never ids, coordinates, offsets, notes or skipped fields. */
export interface PreviewStop {
  name: string;
  kind: PlannedStopKind;
  minutes?: number;
}

export interface PreviewTripResult {
  tripId: string;
  name: string;
  destinationName: string;
  /** Where the trip ends, so a stranger's phone can work out its own drive time; the only coordinate a stranger gets (never the route or the start). */
  destinationCoordinate?: { latitude: number; longitude: number };
  cars: PreviewCar[];
  /** Planned stops in order, skipped ones left out; absent when there are none. */
  stops?: PreviewStop[];
}
