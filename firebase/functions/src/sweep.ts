import { FieldPath, FieldValue, Timestamp, type Firestore, type Query, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";

/**
 * Where a sweep stopped: the sort key of the last trip it handled, in whole seconds and nanoseconds (Firestore keeps
 * microseconds, so milliseconds would round a trip's time down and sort the trip after its own cursor), and that
 * trip's id to break ties.
 */
export interface SweepCursor {
  seconds: number;
  nanos: number;
  id: string;
}

export interface SweepItem<T> {
  id: string;
  seconds: number;
  nanos: number;
  item: T;
}

/** Orders (seconds, nanos, id) keys. */
export function compareKeys(a: { seconds: number; nanos: number; id: string }, b: { seconds: number; nanos: number; id: string }): number {
  return a.seconds - b.seconds || a.nanos - b.nanos || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

export interface SweepOptions<T> {
  /** Items strictly after `after` in (ms, id) order; the oldest first. `null` means from the start. */
  list: (after: SweepCursor | null, limit: number) => Promise<SweepItem<T>[]>;
  /** Handles one item; may throw (counted as failed, the sweep carries on). */
  handle: (item: SweepItem<T>) => Promise<void>;
  cursor: SweepCursor | null;
  /** At most this many items per run, so a long backlog is finished over several runs. */
  maxItems: number;
  /** Items fetched per query. */
  pageSize: number;
  /** The run stops starting new items once this returns true (a time budget well inside the function timeout). */
  outOfTime: () => boolean;
  /** Called with the cursor after each page, so a run that is killed keeps the progress it made. */
  save?: (cursor: SweepCursor | null) => Promise<void>;
  /** When the list runs dry, start the next run from the beginning (for a sweep that re-checks items that stay). */
  wrap?: boolean;
  /** Called with the id of each item that threw. */
  onFailure?: (id: string, err: unknown) => void;
  /**
   * Asked after `onFailure`: true means the failure could not be kept for a retry, so the sweep stops with the cursor
   * still before that item and the next run meets it again, instead of moving past it for good.
   */
  holdOnFailure?: () => boolean;
}

export interface SweepOutcome {
  cursor: SweepCursor | null;
  handled: number;
  failed: number;
  /** Stopped because of maxItems or the time budget; more is waiting for the next run. */
  more: boolean;
  /** The list ran dry and the cursor went back to the start (wrap only). */
  wrapped: boolean;
}

/**
 * Walks a list oldest first from a stored cursor, at most `maxItems` per run. Handled items are never read again:
 * the cursor moves past them and is saved, so one slow or huge backlog cannot starve the trips behind it.
 */
export async function runSweep<T>(o: SweepOptions<T>): Promise<SweepOutcome> {
  let cursor = o.cursor;
  let handled = 0;
  let failed = 0;
  for (;;) {
    if (handled >= o.maxItems || o.outOfTime()) return { cursor, handled, failed, more: true, wrapped: false };
    const page = await o.list(cursor, Math.min(o.pageSize, o.maxItems - handled));
    if (page.length === 0) {
      if (o.wrap && cursor !== null) {
        await o.save?.(null);
        return { cursor: null, handled, failed, more: false, wrapped: true };
      }
      return { cursor, handled, failed, more: false, wrapped: false };
    }
    for (const it of page) {
      if (o.outOfTime()) {
        if (handled > 0) await o.save?.(cursor);
        return { cursor, handled, failed, more: true, wrapped: false };
      }
      try {
        await o.handle(it);
      } catch (err) {
        failed++;
        o.onFailure?.(it.id, err);
        if (o.holdOnFailure?.()) {
          await o.save?.(cursor);
          return { cursor, handled, failed, more: true, wrapped: false };
        }
      }
      handled++;
      cursor = { seconds: it.seconds, nanos: it.nanos, id: it.id };
    }
    await o.save?.(cursor);
  }
}

/** A Firestore trips query as a sweep list, ordered by `field` (a timestamp) then document id. */
export function tripsList(base: Query, field: string): (after: SweepCursor | null, limit: number) => Promise<SweepItem<QueryDocumentSnapshot>[]> {
  return async (after, limit) => {
    let q = base.orderBy(field).orderBy(FieldPath.documentId()).limit(limit);
    if (after) q = q.startAfter(new Timestamp(after.seconds, after.nanos), after.id);
    const snap = await q.get();
    return snap.docs.map((d) => {
      const at = d.get(field) as Timestamp;
      return { id: d.id, seconds: at.seconds, nanos: at.nanoseconds, item: d };
    });
  };
}

/** Job progress lives in `jobState/<job>`: not reachable by clients (the rules deny everything but the listed paths). */
export async function loadState<S extends object>(db: Firestore, job: string): Promise<Partial<S>> {
  const snap = await db.collection("jobState").doc(job).get();
  return snap.exists ? (snap.data() as Partial<S>) : {};
}

export async function saveState(db: Firestore, job: string, state: object): Promise<void> {
  await db.collection("jobState").doc(job).set(state, { merge: true });
}

/**
 * The saved place, or null to start from the beginning. A place later than `notAfter` (the query's own bound) cannot
 * have come from this query, so it is ignored, as is anything that is not a seconds/nanos/id triple. Starting from the
 * beginning because the place is missing or unusable is logged; an explicit null is a finished walk that wrapped.
 */
export function cursorFromState(
  s: { cursorSeconds?: number | null; cursorNanos?: number | null; cursorId?: string | null },
  job: string,
  notAfter: Timestamp,
): SweepCursor | null {
  if (s.cursorSeconds === null && s.cursorNanos === null && s.cursorId === null) return null;
  const valid =
    Number.isInteger(s.cursorSeconds) && Number.isInteger(s.cursorNanos) && typeof s.cursorId === "string"
    && s.cursorNanos! >= 0 && s.cursorNanos! < 1e9;
  if (valid) {
    const c = { seconds: s.cursorSeconds!, nanos: s.cursorNanos!, id: s.cursorId! };
    if (compareKeys(c, { seconds: notAfter.seconds, nanos: notAfter.nanoseconds, id: "\uffff" }) <= 0) return c;
    logger.warn(`${job}: saved place is later than the query's bound; starting from the beginning`, { cursor: c });
    return null;
  }
  logger.warn(`${job}: no usable saved place; starting from the beginning`, { saved: s });
  return null;
}

export const cursorToState = (c: SweepCursor | null) => ({
  cursorSeconds: c?.seconds ?? null,
  cursorNanos: c ? c.nanos : null,
  cursorId: c?.id ?? null,
  // The old millisecond place, from before the timestamps were exact.
  cursorMs: FieldValue.delete(),
});
