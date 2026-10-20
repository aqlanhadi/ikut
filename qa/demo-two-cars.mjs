#!/usr/bin/env node
// Live demo 2 of 2: THE ORGANIZER AND A PARTICIPANT IN ANOTHER CAR. About 9 minutes of real-time (1x) convoy.
//
//   node demo-two-cars.mjs                 # build, then the show
//   node demo-two-cars.mjs --skip-build    # reuse the build in --derived-data (default /tmp/ikut-dd-q4)
//   node demo-two-cars.mjs --dry-run       # no Firebase, no simulator: print the timeline, check the geometry
//   (same options as demo.mjs)
//
// Cast: phone 1 is Aisha, the organizer, driving the lead car; she creates the trip in the app (see demo.mjs). Phone 2
// is Faiz, who joins as "A new car" ("Faiz’s Axia"), driver with location sharing on, and drives behind Aisha, ahead of
// the scripted Daniel and Hafiz (the slowest, who loses signal). UI tests in ios/ikutUITests/DemoUITests.swift
// (DemoOrganizerUITests, DemoOwnCarUITests), marker files as in lib/demo-common.mjs.
//
// The highlight: Faiz taps Pit stop > Fuel on phone 2 (the request sends itself); Hafiz suggests "R&R Demo", Daniel
// agrees; on phone 1 Aisha agrees and pins it; phone 2 shows "pinned by the lead car"; it stays 75 s, then Aisha taps
// Everyone has arrived.

import { PIN_VISIBLE_S, parseArgs, runDemo, stopStory } from './lib/demo-common.mjs';

const o = parseArgs(process.argv, 'See the header of demo-two-cars.mjs (qa/README.md, "Live demo").');

const REPORT_AT = 75;
const DROP = { from: 150, to: 270 };
const STOP_AT = 300;
const END_AT = 560;

const cast = {
  lead: { displayName: 'Aisha', role: 'phone 1: organizer, lead car', motion: { start: 3400, speed: 26.4 } }, // phone 1, 95 km/h
  faiz: { displayName: 'Faiz', role: 'phone 2: own car behind Aisha', motion: { start: 2600, speed: 26.4 } }, // phone 2, 800 m behind Aisha
  daniel: { displayName: 'Daniel', role: 'scripted car, agrees to the stop', name: 'Daniel’s City', color: '#7C3AED', scripted: true, motion: { start: 1700, speed: 25.5, wobble: 20, period: 100, phase: 0.6 } },
  hafiz: { displayName: 'Hafiz', role: 'scripted car, slowest, loses signal, suggests R&R Demo', name: 'Hafiz’s Hilux', color: '#0F766E', scripted: true, motion: { start: 600, speed: 24.5, wobble: 25, period: 110, phase: 1.3 } },
};

const timeline = (d) => {
  const w = d.world;
  const hazard = w.offsetOf('lead', REPORT_AT + 3);
  const alertAt = (who) => {
    for (let t = REPORT_AT; t < END_AT; t++) if (w.offsetOf(who, t) >= hazard - 500) return t;
    return END_AT;
  };
  const pinAt = STOP_AT + 30; // Pit stop countdown, 10 s of script, then the taps on phone 1
  return [
    { at: 0, text: () => `GO. Order: Aisha (phone 1, lead), Faiz (phone 2) ${w.gap('faiz', 0)}, Daniel ${w.gap('daniel', 0)}, Hafiz ${w.gap('hafiz', 0)}` },
    { at: 45, text: (t) => `convoy spread: Hafiz is ${((w.offsetOf('lead', t) - w.offsetOf('hafiz', t)) / 1000).toFixed(1)} km behind Aisha and falling back`, note: true },
    { at: REPORT_AT, who: 'phone1', text: () => 'Aisha opens Report on phone 1 and taps Debris', run: async (x) => x.sync.mark('report.a') },
    { at: REPORT_AT + 6, text: () => 'debris marker appears on both phones', note: true },
    { at: alertAt('faiz'), who: 'phone2', text: () => 'phone 2 (Faiz, behind Aisha) gets the approach alert: "Debris ahead in 500 meters"', note: true },
    { at: alertAt('daniel'), text: () => 'Daniel gets the approach alert, Hafiz later (see the "approach alert" lines of this log)', note: true },
    { at: DROP.from, text: (t) => `Hafiz loses signal (${w.gap('hafiz', t)}); he keeps driving but cannot report`, run: async (x) => x.cars.hafiz.goOffline() },
    { at: DROP.from + 60, text: () => 'on both phones the Hafiz row goes stale: "Last seen ..."', note: true },
    { at: DROP.to, text: () => 'Hafiz gets signal back, his position jumps to where he is now', run: async (x) => x.cars.hafiz.goOnline() },
    { at: STOP_AT, who: 'phone2', text: () => 'THE HIGHLIGHT. Faiz taps Pit stop > Fuel on phone 2 (it sends itself); Hafiz suggests "R&R Demo", 4 km ahead of Aisha; Daniel agrees', run: (x) => stopStory(x, { byPhone: true }) },
    { at: pinAt - 10, who: 'phone1', text: () => 'phone 1: the stop card; Aisha taps Agree to Stop, then Pin R&R Demo', note: true },
    { at: pinAt, text: () => `phone 2: the stop shows "pinned by the lead car" and the pin is on the map; it stays ${PIN_VISIBLE_S} s`, note: true },
    { at: pinAt + PIN_VISIBLE_S + 5, who: 'phone1', text: () => 'Aisha taps Everyone has arrived on phone 1; the stop card goes on both phones', note: true },
    { at: END_AT - 60, text: () => 'the map stays open and the convoy keeps driving until the end', note: true },
    { at: END_AT, text: () => 'END of the demo' },
  ];
};

process.exit(await runDemo({
  id: 'two-cars', summary: 'Phone 1 is the organizer and pins a stop; phone 2 is another car behind her that asks for the fuel stop.',
  tag: 'demo2', title: 'the two-cars demo (phone 1 = Aisha, lead car and organizer; phone 2 = Faiz, his own car behind her)',
  cast, order: ['lead', 'faiz', 'daniel', 'hafiz'], endAt: END_AT,
  phones: [
    { id: 'a', label: 'phone 1 (Aisha)', role: 'Aisha, organizer, lead car', udid: o.udid, test: 'DemoOrganizerUITests', follows: 'lead', tracks: true, env: { TEST_RUNNER_IKUT_DEMO_NAME: 'Aisha' } },
    { id: 'b', label: 'phone 2 (Faiz)', role: 'Faiz, own car behind Aisha', udid: o.udid2, test: 'DemoOwnCarUITests', follows: 'faiz', tracks: true, env: { TEST_RUNNER_IKUT_DEMO_NAME: 'Faiz', TEST_RUNNER_IKUT_CAR_NAME: 'Faiz’s Axia' } },
  ],
  timeline,
  sanity: (d) => (d.world.offsetOf('lead', STOP_AT + 130) > d.world.offsetOf('lead', STOP_AT) + 4000 ? ['the lead drives past "R&R Demo" before Everyone has arrived'] : []),
}, o));
