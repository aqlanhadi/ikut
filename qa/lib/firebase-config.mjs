// The production Firebase client config, read from the app's own GoogleService-Info.plist. Used by
// prod-smoke.mjs, battery-watch.mjs and the demos' --backend production.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// The project every runner talks to: the emulators run it under this id, production is the same project.
export const PROJECT_ID = 'ikut-b1083';
export const REGION = 'asia-southeast1';

const plist = fileURLToPath(new URL('../../ios/ikut/Resources/GoogleService-Info.plist', import.meta.url));
const read = (key) => execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist], { encoding: 'utf8' }).trim();

/**
 * The API key is restricted to the app's bundle id, so Google refuses a request that doesn't name it (sign-in says
 * "requests from this iOS client application <empty> are blocked"). The iOS SDK names it in a header on every request;
 * this adds the same header to this process's requests to Google's APIs. It is the production runners' stand-in for
 * the app, nothing more: the header is not a secret, so the restriction keeps out other keys' misuse, not a determined caller.
 */
export function sendAppBundleId() {
  const bundleId = read('BUNDLE_ID');
  const real = globalThis.fetch;
  if (real.sendsBundleId) return;
  const wrapped = (input, init = {}) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (!/^https:\/\/[^/]*\.googleapis\.com\//.test(url)) return real(input, init);
    const headers = new Headers(init.headers ?? (typeof input === 'object' && 'headers' in input ? input.headers : undefined));
    headers.set('X-Ios-Bundle-Identifier', bundleId);
    return real(input, { ...init, headers });
  };
  wrapped.sendsBundleId = true;
  globalThis.fetch = wrapped;
}

// Runs when this file is imported, which the runners do before the Firebase SDK: the SDK keeps the fetch it finds
// when it loads, so patching later does nothing.
sendAppBundleId();

export const productionFirebaseConfig = () => {
  return { apiKey: read('API_KEY'), projectId: read('PROJECT_ID'), appId: read('GOOGLE_APP_ID') };
};
