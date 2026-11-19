// Belépési kapu: a laszlobiri oldalak csak belépve használhatók.
//
// Bekötés egy oldalon, a <head> elején (a sorrend számít):
//
//   <style id="lb-gate">html{visibility:hidden}</style>
//   <script>/* lb-gate */if(!/(?:^|;\s*)sb-[a-z0-9]+-auth-token(?:\.0)?=/.test(document.cookie))location.replace('https://laszlobiri.com/belepes/?next='+encodeURIComponent(location.href))</script>
//   <script type="module" src="https://laszlobiri.com/lib/v1/gate.js"></script>
//
// 1. A beágyazott sor azonnal, még rajzolás előtt átirányít, ha nincs munkamenet-süti.
// 2. Ez a modul megnézi a helyben tárolt munkamenetet (hálózat nélkül, tehát offline is
//    működik). Ha van, megmutatja az oldalt; ha nincs, a belépőoldalra irányít.
// 3. Online állapotban a háttérben a szerverrel is ellenőriz: ha a fiókot törölték
//    vagy a munkamenetet visszavonták, kiléptet. Hálózati hibára nem léptet ki.
// 4. Aloldalon (ebed., bevasarlas., gyakorlas., …; lásd access.js) azt is megnézi, hogy
//    a felhasználó megnyithatja-e ezt az oldalt. Ha nem, a „nincs hozzáférésed” üzenetet
//    mutatja, és a `ready` nem teljesül. Hálózati hibánál a legutóbbi ismert döntés
//    számít; ha nincs ilyen, megnyílik (az adatot az RLS védi).
//
// Fontos: ez a böngészőben működő kapu, nem hozzáférés-védelem. A GitHub Pages a
// fájlokat bárkinek kiszolgálja; az adatot az adatbázis RLS-e védi (docs/backend-terv.md).
//
// Publikus szerződés: a modul neve, a `ready` export ({ user, offline }) és a fenti
// bekötés nem változhat;
// törő változás csak lib/v2 alatt.

import { supabase, isConfigured, signIn, signOut } from './auth.js';
import { SITES, currentApp, getAccess, cachedAccess } from './access.js';

const hasSessionCookie = () => /(?:^|;\s*)sb-[a-z0-9]+-auth-token(?:\.0)?=/.test(document.cookie);

function reveal() {
  document.getElementById('lb-gate')?.remove();
  document.documentElement.style.visibility = '';
}

function isNetworkError(error) {
  return Boolean(error) && (error.name === 'AuthRetryableFetchError' || error.status === 0 || navigator.onLine === false);
}

// Ennyi ideig várunk a munkamenetre, mielőtt offline módban megmutatjuk az oldalt.
// Lejárt tokennél és hálózati hibánál a kliens visszalépéssel akár 30 s-ig is próbálkozik.
const OFFLINE_GRACE_MS = 3000;

// ---------------------------------------------------------------------------
// Aloldal-hozzáférés
// ---------------------------------------------------------------------------
const APP = currentApp();
const never = new Promise(() => {});
let denied = false;

function deny(apps) {
  if (denied) return;
  denied = true;
  const el = document.createElement('div');
  el.id = 'lb-denied';
  el.setAttribute('role', 'alert');
  el.style.cssText = 'position:fixed;inset:0;z-index:2147483647;overflow:auto;display:flex;align-items:center;justify-content:center;'
    + 'padding:24px;background:var(--bg,#293c4b);color:var(--fg,#eaecf0);font:16px/24px var(--font-sans,system-ui,sans-serif);text-align:center';
  const links = SITES.filter(s => apps.includes(s.app))
    .map(s => `<a href="${s.url}" style="color:var(--accent-text,#f19559)">${s.name}</a>`);
  el.innerHTML = '<div style="max-width:420px"><h1 style="font-size:24px;line-height:32px;margin:0 0 12px">Ehhez az oldalhoz nincs hozzáférésed.</h1>'
    + '<p style="margin:0 0 16px;color:var(--fg-muted,#a9b6c1)">Ha kellene, kérd az oldal gazdájától.</p>'
    + (links.length ? `<p style="margin:0 0 16px">Megnyithatod: ${links.join(', ')}.</p>` : '')
    + '<p style="margin:0"><a href="https://laszlobiri.com/" style="color:var(--accent-text,#f19559)">Főoldal</a></p>'
    + '<p style="margin:16px 0 0"><button type="button" style="font:inherit;color:inherit;background:transparent;border:1px solid var(--line,#3d5365);border-radius:999px;padding:6px 16px;min-height:44px;cursor:pointer">Belépés másik fiókkal</button></p></div>';
  el.querySelector('button').addEventListener('click', async () => { await signOut(); signIn(location.href); });
  document.body ? document.body.append(el) : document.addEventListener('DOMContentLoaded', () => document.body.append(el));
  reveal();
}

// Belépett felhasználó: igaz, ha az oldal megnyitható (ekkor meg is jelenik).
async function allowed(user) {
  if (!APP) { reveal(); return true; }
  const cached = cachedAccess(user.id);
  if (cached?.apps.includes(APP)) {
    reveal();
    // a háttérben frissítünk: ha közben visszavonták, most zár
    getAccess(user.id).then(a => { if (!a.apps.includes(APP)) deny(a.apps); }).catch(() => {});
    return true;
  }
  try {
    const a = await getAccess(user.id);
    if (a.apps.includes(APP)) { reveal(); return true; }
    deny(a.apps); return false;
  } catch {
    if (cached) { deny(cached.apps); return false; }
    reveal(); return true;   // még soha nem kérdeztük, és nincs hálózat
  }
}

// Offline, felhasználó nélkül: a legutóbbi ismert döntés.
function allowedOffline() {
  const c = APP ? cachedAccess() : null;
  if (c && !c.apps.includes(APP)) { deny(c.apps); return false; }
  reveal(); return true;
}

async function check() {
  if (!isConfigured) { reveal(); return { user: null, offline: false }; }

  const session = supabase.auth.getSession();
  const offlineNow = navigator.onLine === false && hasSessionCookie();
  const timeout = new Promise(r => setTimeout(() => r('timeout'), offlineNow ? 0 : OFFLINE_GRACE_MS));
  const first = await Promise.race([session, timeout]);

  if (first === 'timeout') {
    if (!hasSessionCookie()) { signIn(location.href); return { user: null, offline: false }; }
    // Offline (vagy nagyon lassú hálózat), de van munkamenet: megmutatjuk az oldalt,
    // és csak akkor léptetünk ki, ha a szerver később egyértelműen elutasít.
    if (!allowedOffline()) return never;
    session.then(({ data, error }) => {
      if (!data.session && !isNetworkError(error)) signIn(location.href);
    });
    return { user: null, offline: true };
  }

  const { data, error } = first;
  if (data.session) {
    verifyInBackground();
    if (!(await allowed(data.session.user))) return never;
    return { user: data.session.user, offline: false };
  }
  // Lejárt access token és hálózati hiba: a munkamenet megvan (a kliens hálózati
  // hibánál nem törli), visszatérő hálózatnál magától frissíti a tokent.
  if (isNetworkError(error) && hasSessionCookie()) {
    if (!allowedOffline()) return never;
    return { user: null, offline: true };
  }
  signIn(location.href);
  return { user: null, offline: false };
}

function verifyInBackground() {
  if (navigator.onLine === false) return;
  // Él-e még a fiók és a munkamenet a szerveren (pl. törölt fiók, visszavont munkamenet).
  supabase.auth.getUser().then(async ({ error }) => {
    if (!error || isNetworkError(error)) return;
    const status = error.status ?? 0;
    if (status === 401 || status === 403 || /user.*not.*found|session.*not.*found|invalid.*jwt/i.test(error.message)) {
      await supabase.auth.signOut({ scope: 'local' });
      signIn(location.href);
    }
  }).catch(() => { /* hálózati hiba: marad a helyi munkamenet */ });
}

/**
 * Promise: { user, offline }. A `user` a belépett felhasználó; offline, lejárt
 * tokennél null, ekkor `offline` igaz. Átirányításkor és ha a felhasználó ezt az
 * aloldalt nem nyithatja meg, nem teljesül.
 */
export const ready = check();

// Ha egy másik laszlobiri oldalon kiléptél, ez az oldal is kiléptet, amikor előtérbe kerül.
// Ugyanezen az oldalon (pl. az <lb-auth> gombbal) történt kilépésnél is.
if (isConfigured) {
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && !hasSessionCookie()) signIn(location.href);
  });
  supabase.auth.onAuthStateChange(event => {
    if (event === 'SIGNED_OUT') signIn(location.href);
  });
}
