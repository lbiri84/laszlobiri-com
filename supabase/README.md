# Supabase: a laszlobiri oldalak közös backendje

Hogyan működik az egész: [`docs/backend-terv.md`](../docs/backend-terv.md). Ebben a mappában a séma (migrációk), a tesztek és a helyi beállítás van; lent az éles projekt kézi beállításai.

Éles projekt: `eokwxkrcttsoxfflvuus` (Central EU, Frankfurt). A nyilvános adatai a `lib/v1/config.js`-ben vannak.

## Fájlok

| fájl | mi ez |
| --- | --- |
| `migrations/20261114120000_core.sql` | `profiles`, `households`, `household_members`, `private.allowed_emails`, allowlist hook és trigger, RLS |
| `migrations/20261114150000_lists.sql` | bevásárlólista: `lists` (háztartásonként egy), `items` (soft delete, név szerinti egyediség), `item_history`, `bump_history()`, Realtime, napi takarítás |
| `migrations/20261114180000_practice.sql` | gyakorló: `pupils`, `results`, `pupil_badges`, gyerek mód (`devices`, `device_pupils`, `private.device_pairings`, `create_pairing()`, `claim_pairing()`), napi takarítás |
| `migrations/20261114200000_pupil_theme.sql` | gyerekprofil színtémája (`pupils.theme`: `slate` / `rose`) |
| `migrations/20261114210000_pupil_theme_self.sql` | a tablet a hozzá rendelt gyerek színét írhatja, mást nem (`pupils_guard`) |
| `migrations/20261114220000_question_reports.sql` | hibás feladat jelentése (`question_reports`) |
| `tests/000_helpers.sql` | teszt-segédfüggvények (lekérdezés egy adott felhasználóként) |
| `tests/001_core_rls.test.sql` … `005_question_reports.test.sql` | pgTAP tesztek a fenti migrációkhoz |
| `tests/stub/supabase-stub.sql` | csak a `scripts/test-db.sh`-hoz: a Supabase sémák utánzata sima Postgresen |
| `seed.sql` | kitalált adatok a helyi fejlesztéshez |
| `config.toml` | a Supabase CLI helyi beállítása (`supabase start`) |

## Tesztek

```bash
npm run test:db
```

Docker nélkül, egy ideiglenes helyi Postgresen (Postgres és `postgresql-16-pgtap` kell). Teljes Supabase-környezetben (Docker kell) ugyanezek a tesztek: `supabase start`, majd `supabase test db`.

```bash
npm run test:smoke
```

Böngészős próbák ál-Supabase szerverrel (Playwright kell; a `bevasarlo-lista` és a `gyakorlas` repó a `laszlobiri-com` mellett legyen).

```bash
npm run check:rls
```

Az éles projekt ellenőrzése a nyilvános kulccsal (HTTPS-proxy mögött `NODE_USE_ENV_PROXY=1`). Minden sornak „rendben”-nek kell lennie.

## Új migráció élesítése

1. A fájl tartalmát a dashboard SQL Editorában futtasd le (vagy `supabase link --project-ref eokwxkrcttsoxfflvuus`, majd `supabase db push`).
2. `npm run check:rls`.
3. Csak ezután élesedhet a kliens, amelyik az új táblát vagy oszlopot használja.

## Új felhasználó

Egy sor az `allowed_emails` táblába, a dashboard SQL Editorában (a címet ott írd be, ne fájlba):

```sql
insert into private.allowed_emails (email, household_id)
select lower('UJ@PELDA.HU'), id from public.households where name = 'Család';
```

Ha valaki a felvétele előtt próbált belépni, a belépése elutasítva lett (fiók nem jött létre); a felvétel után újra be kell lépnie.

## Az éles projekt kézi beállításai (megtörtént; újrakezdéshez)

### Supabase

1. Projekt, régió Central EU (Frankfurt); az adatbázis-jelszó a jelszókezelőben.
2. Project Settings → API: a Project URL és a publishable (anon) kulcs a `lib/v1/config.js`-be. A service role / secret kulcs sehova nem kerül.
3. Authentication → Sign In / Providers: **Google** be (Client ID + Secret a Google Cloudból); **Email** ki; **Allow anonymous sign-ins** be (a gyerek módhoz).
4. Authentication → Rate Limits: az anonymous sign-ins korlátja alacsony (pl. óránként 10).
5. Authentication → URL Configuration: Site URL `https://laszlobiri.com`; Redirect URLs: `https://laszlobiri.com/belepes/**`.
6. A migrációk sorban (lásd fent). Ha a `pg_cron` nincs bekapcsolva, előbb Database → Extensions → `pg_cron`.
7. Authentication → Hooks → *Before User Created* → Postgres, séma `private`, függvény `hook_before_user_created`.
8. Háztartás és a két szülő címe:

   ```sql
   with h as (insert into public.households (name) values ('Család') returning id)
   insert into private.allowed_emails (email, household_id, app_role)
   select lower(e.email), h.id, e.app_role
   from h, (values ('TE@PELDA.HU', 'admin'), ('FELESEGED@PELDA.HU', 'user')) as e(email, app_role);
   ```

9. Organization settings → DPA elfogadása.

### Google Cloud

1. Projekt „laszlobiri”; OAuth consent screen (Google Auth Platform): External, név „laszlobiri”; Branding: főoldal `https://laszlobiri.com`, adatvédelem `https://laszlobiri.com/adatvedelem/`, authorized domain `laszlobiri.com` (és ha elfogadja, `eokwxkrcttsoxfflvuus.supabase.co`; a `supabase.co` a Public Suffix List része, önmagában nem fogadja el). Logó nélkül; scope csak `openid`, `email`, `profile`; Production (vagy Testing, a két szülő tesztfelhasználóként).
2. Clients → Web application: JavaScript origin `https://laszlobiri.com`; redirect URI `https://eokwxkrcttsoxfflvuus.supabase.co/auth/v1/callback`. A Client ID és Secret csak a Supabase Google providerébe kerül.
