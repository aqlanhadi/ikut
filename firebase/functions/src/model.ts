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
  status: TripStatus;
  createdAt: Timestamp;
  lastActivityAt?: Timestamp;
  /** First Start Trip by any member; absent until the trip is underway. */
  startedAt?: Timestamp;
  endedAt?: Timestamp;
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

/** A pinned stop on a stop request, or a proposal on a vote. */
export interface StopPlace {
  name: string;
  coordinate: GeoPoint;
  /** Meters along the main route. */
  routeOffset: number;
  /** Set on a pinned stop; absent on a proposal. */
  pinnedBy?: string;
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
  /** Absent means it lasts until resolved or cleared. */
  expiresAt?: Timestamp;
  message?: string;
  /** The pinned stop; only ever set on stop requests. */
  place?: StopPlace;
  /** Stop requests only. Absent (an old event) reads as open. */
  status?: StopStatus;
  /** Set only when a stop request closes, with closedBy (a user id) and expiresAt = now. */
  closedReason?: StopClosedReason;
  closedBy?: string;
}

export type StopStatus = 'open' | 'pinned' | 'closed';
export type StopClosedReason = 'left' | 'cancelled' | 'noAnswer';

export type StopAnswer = 'yes' | 'notNow';

/** trips/{tripId}/events/{eventId}/votes/{carId}: one vote per car. */
export interface StopVote {
  userId: string;
  /** true for yes, false for not now; kept so old builds still count the vote. */
  agree: boolean;
  /** Absent on votes from old builds. */
  answer?: StopAnswer;
  at: Timestamp;
  /** Another place this car would rather stop at; the requesting car proposes its place this way. */
  suggestion?: Omit<StopPlace, 'pinnedBy'>;
}

/** previewTrip callable result: what a non-member may see before joining. */
export interface PreviewCar {
  id: string;
  name: string;
  color: string;
  hasTracker: boolean;
  number?: number;
}

export interface PreviewTripResult {
  tripId: string;
  name: string;
  destinationName: string;
  cars: PreviewCar[];
}
