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
//
// Fontos: ez a böngészőben működő kapu, nem hozzáférés-védelem. A GitHub Pages a
// fájlokat bárkinek kiszolgálja; az adatot az adatbázis RLS-e védi (docs/backend-terv.md).
//
// Publikus szerződés: a modul neve, a `ready` export ({ user, offline }) és a fenti
// bekötés nem változhat;
// törő változás csak lib/v2 alatt.

import { supabase, isConfigured, signIn } from './auth.js';

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
    reveal();
    session.then(({ data, error }) => {
      if (!data.session && !isNetworkError(error)) signIn(location.href);
    });
    return { user: null, offline: true };
  }

  const { data, error } = first;
  if (data.session) {
    reveal();
    verifyInBackground();
    return { user: data.session.user, offline: false };
  }
  // Lejárt access token és hálózati hiba: a munkamenet megvan (a kliens hálózati
  // hibánál nem törli), visszatérő hálózatnál magától frissíti a tokent.
  if (isNetworkError(error) && hasSessionCookie()) {
    reveal();
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
 * tokennél null, ekkor `offline` igaz. Átirányításkor nem kell vele foglalkozni.
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
