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
// The highlight: Hafiz asks for a fuel stop and suggests "R&R Demo"; Daniel agrees; on phone 1 Aisha taps Agree to
// Stop and pins it ("the lead car pins a stop for the convoy"); phone 2 shows it pinned; it stays on the map for 75 s,
// then Aisha taps Everyone has arrived and the card goes on both phones.

import { PIN_VISIBLE_S, parseArgs, runDemo, stopStory } from './lib/demo-common.mjs';

const o = parseArgs(process.argv, 'See the header of demo.mjs (qa/README.md, "Live demo").');

const REPORT_AT = 75;
const DROP = { from: 150, to: 270 };
const STOP_AT = 300;
const END_AT = 560;

const cast = {
  lead: { displayName: 'Aisha', role: 'phone 1: organizer, lead car', motion: { start: 3000, speed: 26.4 } }, // phone 1, 95 km/h
  daniel: { displayName: 'Daniel', role: 'scripted car, agrees to the stop', name: 'Daniel’s City', color: '#7C3AED', scripted: true, motion: { start: 1800, speed: 25.5, wobble: 20, period: 100, phase: 0.6 } },
  hafiz: { displayName: 'Hafiz', role: 'scripted car, slowest, loses signal, suggests R&R Demo', name: 'Hafiz’s Hilux', color: '#0F766E', scripted: true, motion: { start: 600, speed: 24.5, wobble: 25, period: 110, phase: 1.3 } },
};

const timeline = (d) => {
  const w = d.world;
  // When a car reaches 500 m before the debris that Faiz reports about 3 s after REPORT_AT.
  const alertAt = (who) => {
    const hazard = w.offsetOf('lead', REPORT_AT + 3);
    for (let t = REPORT_AT; t < END_AT; t++) if (w.offsetOf(who, t) >= hazard - 500) return t;
    return END_AT;
  };
  const pinAt = STOP_AT + 22; // 10 s of script, then the taps on phone 1
  return [
    { at: 0, text: () => `GO. Order: Aisha (phone 1, lead), Daniel ${w.gap('daniel', 0)}, Hafiz ${w.gap('hafiz', 0)}. Faiz rides in Aisha's car (phone 2)` },
    { at: 45, text: (t) => `convoy spread: Hafiz is ${((w.offsetOf('lead', t) - w.offsetOf('hafiz', t)) / 1000).toFixed(1)} km behind Aisha and falling back (Aisha fastest, Hafiz slowest)`, note: true },
    { at: REPORT_AT, who: 'phone2', text: () => 'Faiz (co-pilot, phone 2) opens Report and taps Debris', run: async (x) => x.sync.mark('report.b') },
    { at: REPORT_AT + 6, text: () => 'debris marker appears on both phones (and the toast "Reported debris" on phone 2)', note: true },
    { at: alertAt('daniel'), text: () => 'Daniel (behind) gets the approach alert, Hafiz later (see the "approach alert" lines of this log)', note: true },
    { at: DROP.from, text: (t) => `Hafiz loses signal (${w.gap('hafiz', t)}); he keeps driving but cannot report`, run: async (x) => x.cars.hafiz.goOffline() },
    { at: DROP.from + 60, text: () => 'on both phones the Hafiz row goes stale: "Last seen ..."', note: true },
    { at: DROP.to, text: () => 'Hafiz gets signal back, his position jumps to where he is now', run: async (x) => x.cars.hafiz.goOnline() },
    { at: STOP_AT, text: () => 'THE HIGHLIGHT. Hafiz asks for a fuel stop and suggests "R&R Demo", 4 km ahead of Aisha; Daniel agrees', run: (x) => stopStory(x, { byPhone: false }) },
    { at: pinAt - 10, who: 'phone1', text: () => 'phone 1: the stop card; Aisha taps Agree to Stop, then Pin R&R Demo', note: true },
    { at: pinAt, text: () => `both phones: "the lead car pins a stop for the convoy", the pin is on the map; it stays ${PIN_VISIBLE_S} s`, note: true },
    { at: pinAt + PIN_VISIBLE_S + 5, who: 'phone1', text: () => 'Aisha taps Everyone has arrived on phone 1; the stop card goes on both phones', note: true },
    { at: END_AT - 60, text: () => 'the map stays open and the convoy keeps driving until the end', note: true },
    { at: END_AT, text: () => 'END of the demo' },
  ];
};

process.exit(await runDemo({
  id: 'organizer', summary: 'Phone 1 is the organizer in the lead car and pins a stop; phone 2 rides along as a passenger in her car.',
  tag: 'demo', title: 'Organizer demo (phone 1 = Aisha, lead car and organizer; phone 2 = Faiz, passenger in her car)',
  cast, order: ['lead', 'daniel', 'hafiz'], endAt: END_AT,
  phones: [
    { id: 'a', label: 'phone 1 (Aisha)', role: 'Aisha, organizer, lead car', udid: o.udid, test: 'DemoOrganizerUITests', follows: 'lead', tracks: true, env: { TEST_RUNNER_IKUT_DEMO_NAME: 'Aisha' } },
    { id: 'b', label: 'phone 2 (Faiz)', role: 'Faiz, passenger in Aisha’s car', udid: o.udid2, test: 'DemoPassengerUITests', follows: 'lead', tracks: false, env: { TEST_RUNNER_IKUT_DEMO_NAME: 'Faiz' } },
  ],
  timeline,
  sanity: (d) => (d.world.offsetOf('lead', STOP_AT + 130) > d.world.offsetOf('lead', STOP_AT) + 4000 ? ['the lead drives past "R&R Demo" before Everyone has arrived'] : []),
}, o));
