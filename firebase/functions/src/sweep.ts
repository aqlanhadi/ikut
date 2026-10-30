import { FieldPath, Timestamp, type Firestore, type Query, type QueryDocumentSnapshot } from "firebase-admin/firestore";

/** Where a sweep stopped: the sort key (milliseconds) of the last trip it handled, and that trip's id to break ties. */
export interface SweepCursor {
  ms: number;
  id: string;
}

export interface SweepItem<T> {
  id: string;
  ms: number;
  item: T;
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
      }
      handled++;
      cursor = { ms: it.ms, id: it.id };
    }
    await o.save?.(cursor);
  }
}

/** A Firestore trips query as a sweep list, ordered by `field` (a timestamp) then document id. */
export function tripsList(base: Query, field: string): (after: SweepCursor | null, limit: number) => Promise<SweepItem<QueryDocumentSnapshot>[]> {
  return async (after, limit) => {
    let q = base.orderBy(field).orderBy(FieldPath.documentId()).limit(limit);
    if (after) q = q.startAfter(Timestamp.fromMillis(after.ms), after.id);
    const snap = await q.get();
    return snap.docs.map((d) => ({ id: d.id, ms: (d.get(field) as Timestamp).toMillis(), item: d }));
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

export const cursorFromState = (s: { cursorMs?: number | null; cursorId?: string | null }): SweepCursor | null =>
  typeof s.cursorMs === "number" && typeof s.cursorId === "string" ? { ms: s.cursorMs, id: s.cursorId } : null;

export const cursorToState = (c: SweepCursor | null) => ({ cursorMs: c?.ms ?? null, cursorId: c?.id ?? null });
