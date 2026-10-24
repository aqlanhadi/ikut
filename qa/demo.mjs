#!/usr/bin/env node
// Live demo 1 of 2, for people watching two simulators: THE ORGANIZER DEMO. About 9 minutes of real-time (1x) convoy.
//
//   node demo.mjs                 # build, then the show (phone 1 = "iPhone 17 #1", phone 2 = "iPhone 17 #2")
//   node demo.mjs --skip-build    # reuse the build in --derived-data (default /tmp/ikut-dd-q4)
//   node demo.mjs --dry-run       # no Firebase, no simulator: print the timeline, check the geometry
//   node demo.mjs --udid U1 --udid2 U2 --end-trip --derived-data DIR --host H
//
// Cast: phone 1 is Aisha, the organizer, driving the lead car (car 1): she creates the trip in the app ("Where to?
// Ipoh") from the start of a piece of the E1 and the script reads that route back from Firestore, so everyone drives
// the app's own route. Phone 2 is Faiz, a PASSENGER in Aisha's car (join with the code, her car tile, role Passenger):
// its simulator follows the same track. Scripted cars (Firebase clients) behind the lead: Daniel, and Hafiz, the
// slowest, who loses signal. The UI tests are in ios/ikutUITests/DemoUITests.swift (DemoOrganizerUITests,
// DemoPassengerUITests); the script and they take turns through marker files, see lib/demo-common.mjs.
//
// The highlight: Faiz (phone 2, a passenger in Aisha's car) taps Pit stop > Fuel, adds the message "Low on fuel, next
// R&R please" (the passenger check first) and taps Tell the convoy; Hafiz and Daniel tap OK; Aisha, whose car asked,
// opens the card on phone 1 and watches the OKs come in; after 45 s she taps We've stopped and the request closes on
// both phones.

import { STOP_OPEN_S, parseArgs, runDemo, stopStory } from './lib/demo-common.mjs';
import { holdSimulators } from './lib/shell.mjs';

const o = parseArgs(process.argv, 'See the header of demo.mjs (qa/README.md, "Live demo").');
// Both phones are held while the show runs (qa/simlock.sh): a second demo or UI test waits for it.
if (!o.dryRun && !o.describe) await holdSimulators([o.udid, o.udid2]);

const REPORT_AT = 75;
const DROP = { from: 150, to: 270 };
const STOP_AT = 300;
const END_AT = 560;

const cast = {
  lead: { displayName: 'Aisha', role: 'phone 1: organizer, lead car', motion: { start: 3000, speed: 26.4 } }, // phone 1, 95 km/h
  daniel: { displayName: 'Daniel', role: 'scripted car, taps OK to the stop', name: 'Daniel’s City', color: '#7C3AED', scripted: true, motion: { start: 1800, speed: 25.5, wobble: 20, period: 100, phase: 0.6 } },
  hafiz: { displayName: 'Hafiz', role: 'scripted car, slowest, loses signal, taps OK to the stop', name: 'Hafiz’s Hilux', color: '#0F766E', scripted: true, motion: { start: 600, speed: 24.5, wobble: 25, period: 110, phase: 1.3 } },
};

const timeline = (d) => {
  const w = d.world;
  // When a car reaches 500 m before the debris that Faiz reports about 3 s after REPORT_AT.
  const alertAt = (who) => {
    const hazard = w.offsetOf('lead', REPORT_AT + 3);
    for (let t = REPORT_AT; t < END_AT; t++) if (w.offsetOf(who, t) >= hazard - 500) return t;
    return END_AT;
  };
  return [
    { at: 0, text: () => `GO. Order: Aisha (phone 1, lead), Daniel ${w.gap('daniel', 0)}, Hafiz ${w.gap('hafiz', 0)}. Faiz rides in Aisha's car (phone 2)` },
    { at: 45, text: (t) => `convoy spread: Hafiz is ${((w.offsetOf('lead', t) - w.offsetOf('hafiz', t)) / 1000).toFixed(1)} km behind Aisha and falling back (Aisha fastest, Hafiz slowest)`, note: true },
    { at: REPORT_AT, who: 'phone2', text: () => 'Faiz (co-pilot, phone 2) opens Report and taps Debris', run: async (x) => x.sync.mark('report.b') },
    { at: REPORT_AT + 6, text: () => 'debris marker appears on both phones (and the toast "Reported debris" on phone 2)', note: true },
    { at: alertAt('daniel'), text: () => 'Daniel (behind) gets the approach alert, Hafiz later (see the "approach alert" lines of this log)', note: true },
    { at: DROP.from, text: (t) => `Hafiz loses signal (${w.gap('hafiz', t)}); he keeps driving but cannot report`, run: async (x) => x.cars.hafiz.goOffline() },
    { at: DROP.from + 60, text: () => 'on both phones the Hafiz row goes stale: "Last seen ..."', note: true },
    { at: DROP.to, text: () => 'Hafiz gets signal back, his position jumps to where he is now', run: async (x) => x.cars.hafiz.goOnline() },
    { at: STOP_AT, who: 'phone2', text: () => 'THE HIGHLIGHT. Faiz taps Pit stop > Fuel > Add a message ("Low on fuel, next R&R please") > Tell the convoy on phone 2; Hafiz and Daniel tap OK', run: (x) => stopStory(x) },
    { at: STOP_AT + 40, who: 'phone1', text: () => 'phone 1: the OKs come in on the stop card (her own car asked, so there is no OK for her)', note: true },
    { at: STOP_AT + 40 + STOP_OPEN_S, who: 'phone1', text: () => "Aisha taps We've stopped on phone 1; the request closes on both phones", note: true },
    { at: END_AT - 60, text: () => 'the map stays open and the convoy keeps driving until the end', note: true },
    { at: END_AT, text: () => 'END of the demo' },
  ];
};

process.exit(await runDemo({
  id: 'organizer', summary: 'Phone 1 is the organizer in the lead car and taps We’ve stopped; phone 2 rides along as a passenger in her car and informs the convoy.',
  tag: 'demo', title: 'Organizer demo (phone 1 = Aisha, lead car and organizer; phone 2 = Faiz, passenger in her car)',
  cast, order: ['lead', 'daniel', 'hafiz'], endAt: END_AT,
  phones: [
    { id: 'a', label: 'phone 1 (Aisha)', role: 'Aisha, organizer, lead car', udid: o.udid, test: 'DemoOrganizerUITests', follows: 'lead', tracks: true, env: { TEST_RUNNER_IKUT_DEMO_NAME: 'Aisha' } },
    { id: 'b', label: 'phone 2 (Faiz)', role: 'Faiz, passenger in Aisha’s car', udid: o.udid2, test: 'DemoPassengerUITests', follows: 'lead', tracks: false, env: { TEST_RUNNER_IKUT_DEMO_NAME: 'Faiz' } },
  ],
  timeline,
}, o));
