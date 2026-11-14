// Egyetlen, közös Supabase-kliens a laszlobiri.com és az aloldalai számára.
//
// A munkamenet sütiben él, Domain=.laszlobiri.com beállítással, így egy belépés
// a főoldalon, az ebed., a bevasarlas. és a gyakorlas. címen is érvényes.
// Helyi fejlesztésnél (localhost) a süti domain nélkül, csak az adott hoston él.
//
// Publikus szerződés: a `supabase`, `isConfigured`, `SITE_ORIGIN` exportok neve
// és jelentése nem változhat; törő változás csak lib/v2 alatt.

import { createBrowserClient } from './supabase.js';
import { SUPABASE_URL, SUPABASE_ANON_KEY, isConfigured } from './config.js';

export { isConfigured };

const host = location.hostname;
export const ON_SITE = host === 'laszlobiri.com' || host.endsWith('.laszlobiri.com');

// A belépőoldal és a többi központi oldal helye.
export const SITE_ORIGIN = ON_SITE ? 'https://laszlobiri.com' : location.origin;

export const supabase = isConfigured
  ? createBrowserClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      cookieOptions: {
        domain: ON_SITE ? '.laszlobiri.com' : undefined,
        path: '/',
        sameSite: 'lax',
        secure: location.protocol === 'https:',
      },
      auth: {
        // A ?code= cseréjét csak a belépőoldal végzi (auth.js: completeLogin).
        detectSessionInUrl: false,
      },
    })
  : null;
