// A közös Supabase-projekt nyilvános adatai. Mindkettő publikus, kliensbe való.
// SOHA ne kerüljön ide a service role / secret kulcs.
//
// Kitöltés: Supabase dashboard → Project Settings → API:
//   SUPABASE_URL      = Project URL (https://<ref>.supabase.co)
//   SUPABASE_ANON_KEY = publishable (anon) kulcs
// Ha üres, a lib/v1 „nincs beállítva” állapotban van: a belépés gomb nem
// jelenik meg, az aloldalak a mai, helyi módban működnek.

export const SUPABASE_URL = 'https://eokwxkrcttsoxfflvuus.supabase.co';
export const SUPABASE_ANON_KEY = 'sb_publishable__lQcQeQANtoCNnByfFAQIA_NRXtsriy';

export const isConfigured = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY);
