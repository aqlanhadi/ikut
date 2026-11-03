import { randomInt } from "node:crypto";
import { FieldValue, GeoPoint, type Firestore, type Transaction } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { HttpsError } from "firebase-functions/v2/https";
import type { Member, Trip } from "./model.js";

// Not imported from joinTrip.ts: the unit tests load this file as plain TypeScript, which cannot follow ".js" imports
// at run time (only type imports, erased, are fine).

/** The same 31 characters the app drew codes from (A-Z and 2-9 without O, I, L). */
export const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
export const CODE_LENGTH = 6;
/** Codes the picker tries before giving up; each try is one transaction. A miss needs a claimed code or a live trip with it. */
export const MAX_PICK_TRIES = 20;

export const TRIP_NAME_MAX = 200;
export const DESTINATION_NAME_MAX = 300;
export const ROUTE_MAX = 200_000;
const MEMBER_NAME_MAX = 30;
const CAR_ID_MAX = 128;

/** What the app sends: the trip's own fields and the organizer's name and car id (the car itself is written by the app). */
export interface CreateTripInput {
  name: string;
  destination: { name: string; latitude: number; longitude: number };
  route: string;
  routeSeconds?: number;
  organizerName: string;
  carId: string;
}

/** What comes back: nothing else, so a caller learns only its own trip. */
export interface CreateTripResult {
  tripId: string;
  code: string;
}

function invalid(message: string): never {
  throw new HttpsError("invalid-argument", message);
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/**
 * One random code. The default draw is `crypto.randomInt` (not predictable from earlier codes, unlike Math.random,
 * whose state leaks from codes handed out); `random` returns a number in [0, 1) and is only for tests that need a fixed draw.
 */
export function generateCode(random?: () => number): string {
  let code = "";
  for (let i = 0; i < CODE_LENGTH; i++) {
    const at = random ? Math.floor(random() * CODE_ALPHABET.length) : randomInt(CODE_ALPHABET.length);
    code += CODE_ALPHABET[at];
  }
  return code;
}

/** The same limits the rules had for a client create (D98), plus the organizer's name as joinTrip takes it (1-30). */
export function parseCreateInput(data: unknown): CreateTripInput {
  if (!isRecord(data)) invalid("Invalid request.");
  const { name, destination, route, routeSeconds, organizerName, carId } = data;
  if (typeof name !== "string" || name.length > TRIP_NAME_MAX) invalid(`A trip name is up to ${TRIP_NAME_MAX} characters.`);
  if (!isRecord(destination)) invalid("Choose a destination.");
  const { name: place, latitude, longitude } = destination;
  if (typeof place !== "string" || place.length > DESTINATION_NAME_MAX) invalid("Choose a destination.");
  if (typeof latitude !== "number" || !(latitude >= -90 && latitude <= 90)) invalid("Choose a destination.");
  if (typeof longitude !== "number" || !(longitude >= -180 && longitude <= 180)) invalid("Choose a destination.");
  if (typeof route !== "string" || route.length > ROUTE_MAX) invalid("That route is too long.");
  if (routeSeconds !== undefined && routeSeconds !== null
      && (typeof routeSeconds !== "number" || !Number.isFinite(routeSeconds) || routeSeconds < 0)) invalid("That route time is not valid.");
  if (typeof organizerName !== "string") invalid("Enter your name.");
  const cleanName = organizerName.trim().replace(/\s+/g, " ");
  // Counted in characters ([...name]), as the app does (DisplayName.swift), so an emoji is one. joinTrip still counts
  // UTF-16 units (known gap, left as it is).
  const chars = [...cleanName].length;
  if (chars < 1 || chars > MEMBER_NAME_MAX) invalid(`Your name is 1 to ${MEMBER_NAME_MAX} characters.`);
  // Ids that could escape the cars collection path are refused.
  if (typeof carId !== "string" || carId.length < 1 || carId.length > CAR_ID_MAX || carId.includes("/")) invalid("Choose a car.");
  return {
    name, destination: { name: place, latitude, longitude }, route,
    ...(typeof routeSeconds === "number" ? { routeSeconds } : {}),
    organizerName: cleanName, carId,
  };
}

/**
 * Picks a code nobody holds and writes the trip, the organizer's member doc and the code claim in one transaction, so
 * either all three exist or none does. A code is taken when `codes/{code}` exists (an active trip, or one ended less
 * than 7 days ago) or an older trip, made before claims, is active with it. A taken code is never reported: the next
 * random code is tried, up to `maxTries`, then a plain "try again" (`aborted`). Returns the trip id and its code.
 *
 * D104 (code rotation) is meant to draw with `generateCode` and test with `isCodeFree` the same way.
 */
export async function createTripWithFreeCode(
  db: Firestore,
  uid: string,
  input: CreateTripInput,
  opts: { random?: () => number; maxTries?: number } = {},
): Promise<CreateTripResult> {
  const tripRef = db.collection("trips").doc();
  for (let i = 0; i < (opts.maxTries ?? MAX_PICK_TRIES); i++) {
    const code = generateCode(opts.random);
    const done = await db.runTransaction(async (tx) => {
      if (!(await isCodeFree(tx, db, code))) return false;
      const trip: Omit<Trip, "createdAt"> & { createdAt: FieldValue } = {
        name: input.name, code, organizerId: uid, route: input.route,
        destination: { name: input.destination.name, coordinate: new GeoPoint(input.destination.latitude, input.destination.longitude) },
        ...(input.routeSeconds !== undefined ? { routeSeconds: input.routeSeconds } : {}),
        status: "active", createdAt: FieldValue.serverTimestamp(),
      };
      const member: Member = { displayName: input.organizerName, carId: input.carId, role: "organizer", userId: uid };
      tx.create(tripRef, trip);
      tx.create(db.collection("codes").doc(code), { tripId: tripRef.id, organizerId: uid, createdAt: FieldValue.serverTimestamp() });
      tx.create(tripRef.collection("members").doc(uid), member);
      return true;
    });
    if (done) return { tripId: tripRef.id, code };
  }
  logger.error("createTrip: no free code found", { tries: opts.maxTries ?? MAX_PICK_TRIES });
  // `aborted`, not `unavailable`: the app reads unavailable as "no signal".
  throw new HttpsError("aborted", "Couldn’t set up your trip just now. Please try again.");
}

/** True when no claim holds `code` and no active trip uses it. Reads only, inside the transaction. */
export async function isCodeFree(tx: Transaction, db: Firestore, code: string): Promise<boolean> {
  if ((await tx.get(db.collection("codes").doc(code))).exists) return false;
  const live = await tx.get(db.collection("trips").where("code", "==", code).where("status", "==", "active").limit(1));
  return live.empty;
}
