// The production Firebase client config, read from the app's own GoogleService-Info.plist. Used by
// prod-smoke.mjs, battery-watch.mjs and the demos' --backend production.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// The project every runner talks to: the emulators run it under this id, production is the same project.
export const PROJECT_ID = 'ikut-b1083';
export const REGION = 'asia-southeast1';

const plist = fileURLToPath(new URL('../../ios/ikut/Resources/GoogleService-Info.plist', import.meta.url));
const read = (key) => execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist], { encoding: 'utf8' }).trim();

export const productionFirebaseConfig = () => ({
  apiKey: read('API_KEY'), projectId: read('PROJECT_ID'), appId: read('GOOGLE_APP_ID'),
});
