import type { GeoPoint, Timestamp } from "firebase-admin/firestore";

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
  /** Absent means it lasts until resolved or cleared. */
  expiresAt?: Timestamp;
  message?: string;
}
