import { FieldValue, type Firestore, type Transaction } from "firebase-admin/firestore";
import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import type { Car, Member, Trip } from "./model.js";

export const MAX_MEMBERS = 20;
export const MAX_CARS = 10;
const NAME_MAX = 30;
const COLOR_MAX = 20;

export type CarChoice =
  | { kind: "existing"; carId: string }
  | { kind: "new"; name: string; color: string };

export interface JoinInput {
  code: string;
  displayName: string;
  car: CarChoice;
  tracker: boolean;
}

export interface JoinResult {
  tripId: string;
  carId: string;
  trackerTaken: boolean;
}

function invalid(message: string): never {
  throw new HttpsError("invalid-argument", message);
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Uppercase and strip spaces/dashes; must then be 6 chars of A-Z0-9. */
export function normalizeCode(raw: unknown): string {
  if (typeof raw !== "string") invalid("Enter the 6-character trip code.");
  const code = raw.toUpperCase().replace(/[\s-]/g, "");
  if (!/^[A-Z0-9]{6}$/.test(code)) invalid("Trip codes are 6 letters or numbers.");
  return code;
}

/** Trim, collapse whitespace, require 1-30 chars. */
export function normalizeName(raw: unknown, what: string): string {
  if (typeof raw !== "string") invalid(`Enter ${what}.`);
  const name = raw.trim().replace(/\s+/g, " ");
  if (name.length < 1) invalid(`Enter ${what}.`);
  if (name.length > NAME_MAX) invalid(`${what[0]!.toUpperCase()}${what.slice(1)} must be ${NAME_MAX} characters or fewer.`);
  return name;
}

export function parseJoinInput(data: unknown): JoinInput {
  if (!isRecord(data)) invalid("Invalid request.");
  const code = normalizeCode(data.code);
  const displayName = normalizeName(data.displayName, "your name");

  const rawCar = data.car;
  if (!isRecord(rawCar)) invalid("Choose a car.");
  let car: CarChoice;
  if (rawCar.existingCarId !== undefined) {
    const id = rawCar.existingCarId;
    // Reject ids that could escape the cars collection path.
    if (typeof id !== "string" || id.length < 1 || id.length > 128 || id.includes("/")) {
      invalid("Choose a car.");
    }
    car = { kind: "existing", carId: id };
  } else if (rawCar.newCar !== undefined) {
    const nc = rawCar.newCar;
    if (!isRecord(nc)) invalid("Enter a car name and color.");
    const name = normalizeName(nc.name, "the car name");
    if (typeof nc.color !== "string" || nc.color.length > COLOR_MAX) invalid("Invalid car color.");
    car = { kind: "new", name, color: nc.color };
  } else {
    invalid("Choose a car.");
  }

  if (typeof data.tracker !== "boolean") invalid("Invalid request.");
  return { code, displayName, car, tracker: data.tracker };
}

/** Transaction body. Throws HttpsError on business-rule failures. */
export async function joinTripTransaction(
  db: Firestore,
  uid: string,
  tripId: string,
  input: JoinInput,
): Promise<JoinResult> {
  const tripRef = db.collection("trips").doc(tripId);
  const membersCol = tripRef.collection("members");
  const carsCol = tripRef.collection("cars");
  const memberRef = membersCol.doc(uid);
  // Allocated outside the callback so transaction retries reuse the same id.
  const newCarRef = input.car.kind === "new" ? carsCol.doc() : null;

  return db.runTransaction(async (tx: Transaction): Promise<JoinResult> => {
    // All reads first.
    const tripSnap = await tx.get(tripRef);
    const trip = tripSnap.data() as Trip | undefined;
    if (!tripSnap.exists || !trip || trip.status !== "active") {
      throw new HttpsError("not-found", "No active trip with that code");
    }
    const memberSnap = await tx.get(memberRef);
    const existing = memberSnap.exists ? (memberSnap.data() as Member) : null;

    let carRef = newCarRef;
    let existingCar: Car | null = null;
    if (input.car.kind === "existing") {
      carRef = carsCol.doc(input.car.carId);
      const carSnap = await tx.get(carRef);
      if (!carSnap.exists) throw new HttpsError("invalid-argument", "That car is not part of this trip.");
      existingCar = carSnap.data() as Car;
    }
    if (!carRef) throw new HttpsError("internal", "No car resolved.");

    if (!existing) {
      const n = (await tx.get(membersCol.count())).data().count;
      if (n >= MAX_MEMBERS) {
        throw new HttpsError("resource-exhausted", `This trip is full (${MAX_MEMBERS} people).`);
      }
    }
    if (input.car.kind === "new") {
      const n = (await tx.get(carsCol.count())).data().count;
      if (n >= MAX_CARS) {
        throw new HttpsError("resource-exhausted", `This trip already has ${MAX_CARS} cars.`);
      }
    }

    // Previous car, to release tracker duty if the member moves.
    let oldCarRef: FirebaseFirestore.DocumentReference | null = null;
    if (existing && existing.carId !== carRef.id) {
      const ref = carsCol.doc(existing.carId);
      const oldSnap = await tx.get(ref);
      if (oldSnap.exists && (oldSnap.data() as Car).trackerUserId === uid) oldCarRef = ref;
    }

    // Writes.
    let trackerTaken = false;
    let carTracker: string | undefined = existingCar?.trackerUserId;
    if (input.tracker) {
      if (carTracker === undefined || carTracker === null || carTracker === uid) {
        carTracker = uid;
      } else {
        trackerTaken = true;
      }
    }

    if (input.car.kind === "new") {
      const car: Car = {
        name: input.car.name,
        color: input.car.color,
        isLead: false,
        state: "joining",
        ...(input.tracker ? { trackerUserId: uid } : {}),
      };
      tx.create(carRef, car);
    } else if (input.tracker && !trackerTaken && existingCar?.trackerUserId !== uid) {
      tx.update(carRef, { trackerUserId: uid });
    }

    if (oldCarRef) tx.update(oldCarRef, { trackerUserId: FieldValue.delete() });

    if (existing) {
      tx.update(memberRef, { displayName: input.displayName, carId: carRef.id });
    } else {
      const member: Member = { displayName: input.displayName, carId: carRef.id, role: "member" };
      tx.create(memberRef, member);
    }
    tx.update(tripRef, { lastActivityAt: FieldValue.serverTimestamp() });

    return { tripId, carId: carRef.id, trackerTaken };
  });
}

/** Look up the single active trip with this code. */
export async function findActiveTripId(db: Firestore, code: string): Promise<string> {
  const snap = await db
    .collection("trips")
    .where("code", "==", code)
    .where("status", "==", "active")
    .limit(2)
    .get();
  if (snap.empty) throw new HttpsError("not-found", "No active trip with that code");
  if (snap.size > 1) {
    logger.error("joinTrip: multiple active trips share a code", { code, tripIds: snap.docs.map((d) => d.id) });
    throw new HttpsError("failed-precondition", "That code is ambiguous. Ask the organizer for a new trip.");
  }
  return snap.docs[0]!.id;
}

export const joinTrip = onCall(async (request): Promise<JoinResult> => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to join a trip.");
  const input = parseJoinInput(request.data);
  const db = getFirestore();
  const tripId = await findActiveTripId(db, input.code);
  return joinTripTransaction(db, uid, tripId, input);
});
