// Battery drain and tracking gaps from a tracker phone's position writes (battery-watch.mjs).

/** The tracker re-sends at least every 30 s when parked (PositionPublisher), so 60 s of silence is a gap. */
export const GAP_SECONDS = 60;

/**
 * updates: [{ t: ms, battery: 0..1 | null }] in time order, one per position write.
 * now: ms; silence from the last write until now counts as an open gap.
 */
export function summarize(updates, now = updates.at(-1)?.t, gapSeconds = GAP_SECONDS) {
  const gaps = [];
  for (let i = 1; i < updates.length; i++) {
    const seconds = (updates[i].t - updates[i - 1].t) / 1000;
    if (seconds > gapSeconds) gaps.push({ from: updates[i - 1].t, to: updates[i].t, seconds, open: false });
  }
  const last = updates.at(-1);
  if (last && (now - last.t) / 1000 > gapSeconds) {
    gaps.push({ from: last.t, to: now, seconds: (now - last.t) / 1000, open: true });
  }

  const readings = updates.filter((u) => u.battery != null);
  const first = readings[0];
  const end = readings.at(-1);
  const hours = first && end ? (end.t - first.t) / 3_600_000 : 0;
  const drop = first && end ? (first.battery - end.battery) * 100 : 0;
  return {
    writes: updates.length,
    startPct: first ? Math.round(first.battery * 100) : null,
    endPct: end ? Math.round(end.battery * 100) : null,
    hours,
    // Under 15 minutes the 1–5% steps of UIDevice.batteryLevel swamp the rate.
    drainPerHour: hours >= 0.25 ? drop / hours : null,
    gaps,
    gapSeconds: gaps.reduce((s, g) => s + g.seconds, 0),
  };
}

const clock = (ms) => new Date(ms).toLocaleTimeString('en-GB', { hour12: false });

export function formatSummary(s) {
  const lines = [`writes            ${s.writes}`];
  if (s.startPct == null) {
    lines.push('battery           no readings');
  } else {
    const mins = Math.round(s.hours * 60);
    lines.push(`battery           ${s.startPct}% → ${s.endPct}% over ${mins} min`);
    lines.push(s.drainPerHour == null
      ? 'drain             need 15+ min of readings'
      : `drain             ${s.drainPerHour.toFixed(1)}% per hour (target under 10)`);
  }
  lines.push(`gaps over ${GAP_SECONDS} s     ${s.gaps.length}${s.gaps.length ? ` (${Math.round(s.gapSeconds)} s total)` : ''}`);
  for (const g of s.gaps) {
    lines.push(`  ${clock(g.from)} → ${g.open ? 'still silent' : clock(g.to)}  ${Math.round(g.seconds)} s`);
  }
  return lines.join('\n');
}
