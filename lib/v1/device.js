// Gyerek mód: a gyerek tabletjének névtelen, párosított eszközfiókja.
//
// A munkamenet NEM a közös .laszlobiri.com sütiben él, hanem csak az adott oldal
// (gyakorlas.laszlobiri.com) saját localStorage-ában, ezért a többi laszlobiri oldal
// nem látja. Az eszközfiók a szerveren csak a hozzá rendelt gyerekprofilokat éri el
// (RLS: private.is_device_for), mást semmit.
//
//   import { isDevice, deviceClient, deviceReady, pair, unpair, checkPin } from 'https://laszlobiri.com/lib/v1/device.js';
//
// A PIN csak kényelmi zár a kilépéshez (PBKDF2-vel hash-elve tárolódik az eszközön);
// ha a gyerek törli a böngésző adatait, azzal sem jut semmihez, csak a gyerek mód áll le.
//
// Publikus szerződés: az exportált nevek és a viselkedésük nem változhat; törő
// változás csak lib/v2 alatt.

import { createClient } from './supabase.js';
import { SUPABASE_URL, SUPABASE_ANON_KEY, isConfigured } from './config.js';

const FLAG = 'lb-device';              // '1', ha ez az eszköz gyerek módban van
const PIN_KEY = 'lb-device-pin';       // { salt, hash } (base64)
const AUTH_KEY = 'lb-device-auth';     // a supabase-js munkamenete

const ls = {
  get: k => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch { /* nincs tárhely */ } },
  del: k => { try { localStorage.removeItem(k); } catch { /* nincs tárhely */ } },
};

/** Gyerek módban van-e ez az eszköz. */
export const isDevice = () => ls.get(FLAG) === '1';

let client = null;
/** Az eszközfiók Supabase-kliense (saját tároló, nem a közös süti). */
export function deviceClient() {
  if (!isConfigured) return null;
  client ??= createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { storageKey: AUTH_KEY, storage: localStorage, persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
  });
  return client;
}

function reveal() {
  document.getElementById('lb-gate')?.remove();
  document.documentElement.style.visibility = '';
}

const isNetworkError = e => Boolean(e) && (e.name === 'AuthRetryableFetchError' || e.status === 0 || navigator.onLine === false);

/**
 * Teljes kilépés a gyerek módból ezen az eszközön, PIN nélkül. Csak akkor ajánld fel,
 * ha az eszköz már semmihez nem fér hozzá (pl. a szülő visszavonta, nincs hozzárendelt
 * gyerek); egyébként az unpair(pin) a helyes út.
 */
export async function forgetDevice() { await clearDevice(); }

async function clearDevice() {
  try { await deviceClient()?.auth.signOut({ scope: 'local' }); } catch { /* offline: a helyi adat így is törlődik */ }
  [FLAG, PIN_KEY, AUTH_KEY].forEach(ls.del);
}

/**
 * Gyerek módban: a munkamenet ellenőrzése és az oldal megjelenítése.
 * Eredmény: { user, offline } vagy { user: null, revoked: true }, ha a munkamenet
 * a szerveren már nem létezik (pl. a fiókot a takarítás törölte); ilyenkor a gyerek
 * mód helyben is leáll, és újra kell párosítani.
 */
export async function deviceReady() {
  const sb = deviceClient();
  if (!sb || !isDevice()) { reveal(); return { user: null, offline: false }; }
  const { data, error } = await Promise.race([
    sb.auth.getSession(),
    new Promise(r => setTimeout(() => r({ data: {}, error: { name: 'AuthRetryableFetchError' } }), navigator.onLine === false ? 0 : 3000)),
  ]);
  reveal();
  if (data?.session) {
    // A szülő a „Eszközök” listában látja, mikor használták utoljára (nem kritikus).
    sb.from('devices').update({ last_seen_at: new Date().toISOString() }).eq('user_id', data.session.user.id).then(() => {}, () => {});
    return { user: data.session.user, offline: false };
  }
  if (isNetworkError(error) && ls.get(AUTH_KEY)) return { user: null, offline: true };
  await clearDevice();
  return { user: null, revoked: true };
}

// ---------------------------------------------------------------- PIN
const b64 = buf => btoa(String.fromCharCode(...new Uint8Array(buf)));
const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));

async function pinHash(pin, salt) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(pin), 'PBKDF2', false, ['deriveBits']);
  return crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: 150000 }, key, 256);
}

/** A PIN formailag jó-e (4 számjegy). */
export const validPin = pin => /^\d{4}$/.test(String(pin ?? ''));

/** A megadott PIN egyezik-e az eszközön tárolttal. */
export async function checkPin(pin) {
  let rec;
  try { rec = JSON.parse(ls.get(PIN_KEY)); } catch { return false; }
  if (!rec?.salt || !rec?.hash || !validPin(pin)) return false;
  return b64(await pinHash(String(pin), unb64(rec.salt))) === rec.hash;
}

async function setPin(pin) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  ls.set(PIN_KEY, JSON.stringify({ salt: b64(salt), hash: b64(await pinHash(String(pin), salt)) }));
}

// ---------------------------------------------------------------- párosítás
/**
 * Párosítás a szülőtől kapott kóddal. Névtelenül belép (ha még nincs munkamenet),
 * beváltja a kódot, és beállítja a PIN-t. Eredmény: 'ok' | 'invalid' (hibás vagy
 * lejárt kód). Más hibánál kivételt dob.
 */
export async function pair(code, pin) {
  if (!validPin(pin)) throw new Error('A PIN 4 számjegy.');
  const sb = deviceClient();
  if (!sb) throw new Error('A belépés még nincs beállítva.');
  const { data } = await sb.auth.getSession();
  if (!data.session) {
    const { error } = await sb.auth.signInAnonymously();
    if (error) throw error;
  }
  const { data: res, error } = await sb.rpc('claim_pairing', { p_code: String(code ?? '') });
  if (error) throw error;
  if (res !== 'ok') return 'invalid';
  await setPin(pin);
  ls.set(FLAG, '1');
  return 'ok';
}

/** Kilépés a gyerek módból a PIN-nel. Eredmény: true, ha sikerült. */
export async function unpair(pin) {
  if (!(await checkPin(pin))) return false;
  await clearDevice();
  return true;
}
