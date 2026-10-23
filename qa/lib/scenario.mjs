// The scripted drive shared by generate-gpx.mjs (which writes the tracks) and convoy-sim.mjs (which plays them).
// Times are scenario seconds from "go"; distances are meters along the trip's main route.
// Staleness is judged on the server clock (ConvoyOrdering.Config.staleAfter = 60 s), so checks that depend
// on it (the signal drop) only hold at speed <= 2x. See qa/README.md.

export const GPX_EPOCH = '2026-10-18T09:00:00Z';
export const DURATION = 900; // seconds of drive
export const FIX_HZ = 1;

export const TRIP = {
  name: 'QA convoy: Bidor to Ipoh',
  destination: { name: 'Ipoh', latitude: 4.5975, longitude: 101.0901 },
};

// Car 4 starts in Tapah town, off the highway, and joins via its own road and the Tapah ramp.
export const CAR4_START = { latitude: 4.1990, longitude: 101.2560 };

/**
 * key: file name stem and handle in the timeline.
 * kind 'main': drives the main route from startOffset at about `speed` m/s (speed wobbles +-0.8 m/s).
 * kind 'merge': starts stationary off-route, drives its own route and reaches the merge point at mergeAt
 *   (the generator solves for the departure time).
 * kind 'app': a real phone; GPX is fed to the simulator with simctl, not played by the sim.
 */
export const CARS = [
  { key: 'car1', kind: 'main', name: 'Aisha’s Myvi', displayName: 'Aisha', color: '#2563EB', startOffset: 5000, speed: 27.9, phase: 0.0, organizer: true },
  { key: 'car2', kind: 'main', name: 'Wyna’s X70', displayName: 'Wyna', color: '#D9480F', startOffset: 4200, speed: 27.7, phase: 1.3, gap: { from: 200, to: 380 } },
  { key: 'car3', kind: 'main', name: 'Hafiz’s Hilux', displayName: 'Hafiz', color: '#0F766E', startOffset: 2900, speed: 27.5, phase: 2.6 },
  { key: 'car4', kind: 'merge', name: 'Daniel’s City', displayName: 'Daniel', color: '#7C3AED', mergeAt: 408, ownCruise: 15, mainSpeed: 27.2 },
  { key: 'car5-app', kind: 'app', name: 'the app', startOffset: 1900, speed: 27.4 },
];

export const SPEED_WOBBLE = 0.8; // m/s
export const WOBBLE_PERIOD = 90; // s

/** Scripted happenings, in scenario seconds. `car` is a CARS key. */
export const TIMELINE = [
  { at: 520, car: 'car1', do: 'hazard', type: 'debris' },
  { at: 700, car: 'car3', do: 'stopRequest', type: 'stopFuel', message: 'Low on fuel, next R&R please' },
  { at: 730, car: 'car2', do: 'ok' },
  { at: 735, car: 'car4', do: 'ok' },
  { at: 800, car: 'car1', do: 'markStopped' },
];

/**
 * The parked-ahead scenario (D26, `--scenario parked` on convoy-sim.mjs and run-ui.mjs): the same drive, plus cars
 * parked on the main route far ahead of the convoy, at an R&R say, that drive on once it comes by. They are in the
 * convoy all along. `waitOffset`: parked there until car 1 (the lead) has passed it by `departAfter`, then pulls out
 * behind it at 1.5 m/s² up to `speed`. Car 1 starts at 5.0 km and covers about 27.9 m/s, so (lib/farahead.mjs):
 *   the phone (car5-parked), parked at 24 km: heads-up "Aisha’s car is 3.3 km behind you" about T=561, drives on about T=692
 *   car 6 (Mei), parked at 28 km:             heads-up about T=704,                                 drives on about T=835
 * Car 3 asks for a fuel stop early, at T=300, while 13 km behind the phone and 17 km behind car 6, so it is worded
 * with the distance. The phone replaces car5-app; run-ui runs ConvoyScenarioUITests/testParkedAheadOfTheConvoy.
 */
export const PARKED_CARS = [
  { key: 'car6', kind: 'main', name: 'Mei’s Saga', displayName: 'Mei', color: '#DB2777', waitOffset: 28_000, departAfter: 300, speed: 27.4 },
  { key: 'car5-parked', kind: 'app', name: 'the app', waitOffset: 24_000, departAfter: 300, speed: 27.4 },
];

export const PARKED_TIMELINE = [
  { at: 300, car: 'car3', do: 'stopRequest', type: 'stopFuel', message: 'Low on fuel, next R&R please' },
  { at: 400, car: 'car2', do: 'ok' }, // after its signal drop (200-380): an offline write would hold the clock
  { at: 450, car: 'car4', do: 'ok' },
  { at: 520, car: 'car1', do: 'hazard', type: 'debris' },
  { at: 800, car: 'car1', do: 'markStopped' },
];

/**
 * The planned-stop scenario (D25 piece 3b, `--scenario stop` on convoy-sim.mjs): cars 1-4 drive as in the default
 * scenario, but each pulls in at the planned stop R&R Tapah, 20 km along the main route, and parks there (car i
 * 20 m short of car i-1, all within the 150 m "here" radius). Car 1 arrives about T=532, car 2 about 565, car 4
 * (merged at 408) about 598, car 3 about 616. The organizer writes the stop before the start, like the lobby; car 1's
 * phone model (lib/stoparrival.mjs) reads everyone's positions and counts who is here. No phone: no `app` car, so
 * `--wait-app` and run-ui do not take this scenario. The tracks are `car<N>-stop.gpx`.
 */
export const STOP = { name: 'R&R Tapah', kind: 'fuel', minutes: 20, offset: 20_000 };
/** The stop after it (D25 4a): Next stop moves on to it once car 1 has left R&R Tapah. Offset is capped to the route. */
export const STOP_NEXT = { name: 'Kopitiam Gopeng', kind: 'food', minutes: 45, offset: 50_000 };
export const STOP_CARS = CARS.filter((c) => c.kind !== 'app').map((c, i) => ({ ...c, gpx: `${c.key}-stop`, stopAt: STOP.offset - 20 * i }));

export const SCENARIOS = ['drive', 'parked', 'stop'];

/** The cars of a scenario: 'drive' (the default) or 'parked'. */
export function scenarioCars(name = 'drive') {
  if (name === 'drive') return CARS;
  if (name === 'parked') return [...CARS.filter((c) => c.kind !== 'app'), ...PARKED_CARS];
  if (name === 'stop') return STOP_CARS;
  throw new Error(`unknown scenario ${name} (${SCENARIOS.join(' or ')})`);
}

/** The scripted happenings of a scenario. */
export const scenarioTimeline = (name = 'drive') => (name === 'parked' ? PARKED_TIMELINE : name === 'stop' ? [] : TIMELINE);

/** The phone's track in a scenario. */
export const appKey = (name = 'drive') => scenarioCars(name).find((c) => c.kind === 'app')?.key;
