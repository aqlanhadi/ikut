// App Check for the production runners. Production's callables reject a request without a valid App Check token, and a
// Node script can't run App Attest, so it presents the debug token registered for the iOS app (App Check > Apps >
// Manage debug tokens) the way a simulator build does. The token is read from QA_APPCHECK_DEBUG_TOKEN or from
// ~/.config/ikut/appcheck-debug-token (one line, mode 600); it is a secret that bypasses App Check, so it is never
// committed or printed. With no token the runner carries on without one, which works until enforcement is on.
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { initializeAppCheck, CustomProvider } from 'firebase/app-check';

const tokenFile = `${homedir()}/.config/ikut/appcheck-debug-token`;

export function debugToken() {
  const fromEnv = process.env.QA_APPCHECK_DEBUG_TOKEN?.trim();
  if (fromEnv) return fromEnv;
  return existsSync(tokenFile) ? readFileSync(tokenFile, 'utf8').trim() : null;
}

/** Gives `app` an App Check provider that trades the debug token for a short-lived token. Returns whether it did. */
export function attachAppCheck(app, config) {
  const token = debugToken();
  if (!token) return false;
  const exchange = `https://firebaseappcheck.googleapis.com/v1/projects/${config.projectId}/apps/${config.appId}:exchangeDebugToken?key=${config.apiKey}`;
  initializeAppCheck(app, {
    isTokenAutoRefreshEnabled: false,
    provider: new CustomProvider({
      getToken: async () => {
        const res = await fetch(exchange, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ debugToken: token }) });
        if (!res.ok) throw new Error(`App Check debug token exchange failed (${res.status})`);
        const { token: appCheckToken, ttl } = await res.json();
        return { token: appCheckToken, expireTimeMillis: Date.now() + parseInt(ttl, 10) * 1000 };
      },
    }),
  });
  return true;
}
