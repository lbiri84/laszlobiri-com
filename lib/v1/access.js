// Oldalankénti hozzáférés: melyik laszlobiri aloldalt nyithatja meg a belépett felhasználó.
//
// Az adatbázis (public.my_access) adja meg: { apps: ['ebed', ...], admin: bool }. A választ
// az adott oldal localStorage-ában is megjegyezzük, hogy a kapu offline és gyorsan is
// döntsön; online állapotban mindig frissül.
//
// Fontos: ez is böngészős kapu. A családi adatokat a háztartás-tagság védi az RLS-ben,
// az aloldal-hozzáférés azt szabja meg, ki melyik oldalt látja.
//
// Publikus szerződés: a `SITES`, `currentApp`, `getAccess`, `cachedAccess` exportok
// neve és jelentése nem változhat; törő változás csak lib/v2 alatt.

import { supabase, isConfigured } from './client.js';

/** Az aloldalak. Új aloldal: ide, és a public.app_codes() / az allowed_emails.apps feltételbe. */
export const SITES = [
  { app: 'ebed',       name: 'Interfood rendelés', url: 'https://ebed.laszlobiri.com' },
  { app: 'bevasarlas', name: 'Bevásárlólista',     url: 'https://bevasarlas.laszlobiri.com' },
  { app: 'gyakorlas',  name: 'Gyakorló',           url: 'https://gyakorlas.laszlobiri.com' },
  { app: 'tarsashaz',  name: 'Társasház',          url: 'https://tarsashaz.laszlobiri.com', soon: true },
];

/**
 * Az aktuális oldal kódja: a <meta name="lb-app" content="..."> vagy a cím alapján.
 * A főoldal és a belépőoldal: null (nincs aloldal-ellenőrzés).
 */
export function currentApp() {
  const meta = document.querySelector('meta[name="lb-app"]')?.content;
  if (meta) return meta;
  return SITES.find(s => new URL(s.url).hostname === location.hostname)?.app ?? null;
}

const KEY = 'lb-access';
const read = () => { try { return JSON.parse(localStorage.getItem(KEY)) || null; } catch { return null; } };
const write = v => { try { localStorage.setItem(KEY, JSON.stringify(v)); } catch { /* privát mód */ } };

/** A legutóbb megjegyzett hozzáférés ({ uid, apps, admin }), vagy null. uid megadásával csak az övé. */
export function cachedAccess(uid) {
  const c = read();
  if (!c || !Array.isArray(c.apps)) return null;
  if (uid && c.uid !== uid) return null;
  return c;
}

/**
 * A belépett felhasználó hozzáférése a szerverről: { apps, admin }.
 * Hálózati hibánál vagy `timeoutMs` után kivételt dob (ekkor a cachedAccess() használható).
 */
export async function getAccess(uid, { timeoutMs = 3000 } = {}) {
  if (!isConfigured) return { apps: SITES.map(s => s.app), admin: false };
  const call = supabase.rpc('my_access').then(({ data, error }) => {
    if (error) throw error;
    const v = { uid: uid ?? null, apps: Array.isArray(data?.apps) ? data.apps : [], admin: data?.admin === true };
    write(v);
    return v;
  });
  const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), timeoutMs));
  return Promise.race([call, timeout]);
}
