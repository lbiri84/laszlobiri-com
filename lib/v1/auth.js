// Belépés, kilépés és a bejelentkezett felhasználó a laszlobiri oldalakon.
//
// Bekötés egy aloldalon:
//   import { getUser, signIn, signOut, onAuthChange } from 'https://laszlobiri.com/lib/v1/auth.js';
//
// Publikus szerződés: az exportált függvények neve és viselkedése nem változhat;
// törő változás csak lib/v2 alatt.

import { supabase, isConfigured, ON_SITE, SITE_ORIGIN } from './client.js';

export { supabase, isConfigured };

export const LOGIN_URL = SITE_ORIGIN + '/belepes/';

// Ezekre a címekre irányíthat vissza a belépőoldal (nyitott átirányítás ellen).
const SITE_ORIGINS = [
  'https://laszlobiri.com',
  'https://ebed.laszlobiri.com',
  'https://bevasarlas.laszlobiri.com',
  'https://gyakorlas.laszlobiri.com',
];
const DEV_HOSTS = ['localhost', '127.0.0.1'];

/** A `next` cím, ha a laszlobiri oldalak egyike; különben a főoldal. */
export function safeNext(raw) {
  const fallback = SITE_ORIGIN + '/';
  if (!raw) return fallback;
  let url;
  try { url = new URL(raw, location.href); } catch { return fallback; }
  const devOk = !ON_SITE && DEV_HOSTS.includes(url.hostname) && url.protocol === 'http:';
  if (!SITE_ORIGINS.includes(url.origin) && !devOk) return fallback;
  return url.href;
}

/** A helyben tárolt munkamenet felhasználója, hálózat nélkül (null, ha nincs). */
export async function getUser() {
  if (!supabase) return null;
  const { data } = await supabase.auth.getSession();
  return data.session?.user ?? null;
}

/** A felhasználó profilja (display_name, app_role), vagy null. */
export async function getProfile() {
  const user = await getUser();
  if (!user) return null;
  const { data, error } = await supabase
    .from('profiles').select('id, display_name, app_role').eq('id', user.id).maybeSingle();
  if (error) return null;
  return data;
}

/** Átirányít a központi belépőoldalra; belépés után a `next` címre tér vissza. */
export function signIn(next = location.href) {
  location.assign(LOGIN_URL + '?next=' + encodeURIComponent(safeNext(next)));
}

/** Kilépés. A süti közös, így minden laszlobiri oldalon kiléptet. */
export async function signOut() {
  if (!supabase) return;
  await supabase.auth.signOut({ scope: 'local' });
}

/**
 * Figyeli a belépés változását. A cb(user) a mostani állapottal azonnal is lefut.
 * Más aldomainen történt be- vagy kilépést az oldal előtérbe kerülésekor veszi észre.
 * Visszatérési érték: leiratkozó függvény.
 */
export function onAuthChange(cb) {
  if (!supabase) { cb(null); return () => {}; }
  let lastId;
  const emit = user => {
    const id = user?.id ?? null;
    if (id === lastId) return;
    lastId = id;
    cb(user ?? null);
  };
  const { data } = supabase.auth.onAuthStateChange((_event, session) => emit(session?.user));
  const recheck = () => { if (document.visibilityState === 'visible') getUser().then(emit); };
  document.addEventListener('visibilitychange', recheck);
  getUser().then(emit);
  return () => {
    data.subscription.unsubscribe();
    document.removeEventListener('visibilitychange', recheck);
  };
}

// ---------------------------------------------------------------------------
// Csak a belépőoldalnak (belepes/index.html).
// ---------------------------------------------------------------------------

/** Google-belépés indítása; visszatérés a belépőoldalra, a `next` megőrzésével. */
export async function startGoogleLogin(next) {
  if (!supabase) throw new Error('A belépés még nincs beállítva.');
  const { error } = await supabase.auth.signInWithOAuth({
    provider: 'google',
    options: {
      redirectTo: LOGIN_URL + '?next=' + encodeURIComponent(safeNext(next)),
      queryParams: { prompt: 'select_account' },
    },
  });
  if (error) throw error;
}

/**
 * A Google-ről visszatérő cím feldolgozása.
 * Eredmény: { status: 'none' | 'signed-in' | 'error', message? }
 */
export async function completeLogin() {
  const q = new URLSearchParams(location.search);
  const h = new URLSearchParams(location.hash.slice(1));
  const code = q.get('code');
  const err = q.get('error_description') || h.get('error_description') || q.get('error') || h.get('error');

  // A code és a hibaüzenet ne maradjon a címsorban.
  if (code || err) {
    const clean = new URL(location.href);
    ['code', 'error', 'error_code', 'error_description', 'state'].forEach(k => clean.searchParams.delete(k));
    clean.hash = '';
    history.replaceState(null, '', clean.pathname + clean.search);
  }

  if (err) return { status: 'error', message: loginErrorText(err) };
  if (!code) return { status: 'none' };
  if (!supabase) return { status: 'error', message: 'A belépés még nincs beállítva.' };

  const { error } = await supabase.auth.exchangeCodeForSession(code);
  if (error) return { status: 'error', message: loginErrorText(error.message) };
  return { status: 'signed-in' };
}

function loginErrorText(raw) {
  const s = String(raw || '');
  // Az allowlist (hook vagy trigger) elutasítása.
  if (/nincs engedélyezve|database error saving new user|signups not allowed|access_denied/i.test(s)) {
    return 'Ez a cím nincs engedélyezve.';
  }
  if (/code verifier|flow state|expired/i.test(s)) {
    return 'A belépés megszakadt vagy lejárt. Próbáld újra.';
  }
  return 'A belépés nem sikerült. Próbáld újra.';
}
