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
