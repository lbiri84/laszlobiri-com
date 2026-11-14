# Supabase: a laszlobiri oldalak közös backendje

A terv: [`docs/backend-terv.md`](../docs/backend-terv.md). Ebben a mappában a séma (migrációk), a tesztek és a helyi beállítás van.

| fájl | mi ez |
| --- | --- |
| `migrations/20261114120000_core.sql` | 1. fázis: `profiles`, `households`, `household_members`, `private.allowed_emails`, allowlist hook és trigger, RLS |
| `tests/001_core_rls.test.sql` | pgTAP tesztek: allowlist, profil-trigger, ki mit lát és írhat |
| `tests/000_helpers.sql` | teszt-segédfüggvények (lekérdezés egy adott felhasználóként) |
| `tests/stub/supabase-stub.sql` | csak a `scripts/test-db.sh`-hoz: a Supabase sémák utánzata sima Postgresen |
| `seed.sql` | kitalált adatok a helyi fejlesztéshez |
| `config.toml` | a Supabase CLI helyi beállítása (`supabase start`) |

## Tesztek

Docker nélkül, egy ideiglenes helyi Postgresen (Postgres és `postgresql-16-pgtap` kell):

```bash
npm run test:db
```

Teljes Supabase-környezetben (Docker kell):

```bash
supabase start
```

```bash
supabase test db
```

A belépőoldal böngészős füstpróbája, ál-Supabase szerverrel (Playwright kell):

```bash
node scripts/login-smoke.mjs
```

## Éles beállítás, egyszer

A Supabase-projekt és a Google OAuth kliens beállítása a terv „Amit neked kell kézzel beállítanod” részében van. Utána:

1. **Migráció.** Vagy a Supabase CLI-vel a gépedről (a `<ref>` a projekt azonosítója a dashboard címéből):

   ```bash
   supabase link --project-ref <ref>
   ```

   ```bash
   supabase db push
   ```

   vagy a migrációs fájl tartalmát bemásolod a dashboard SQL Editorába, és lefuttatod.

2. **Allowlist hook.** Dashboard → Authentication → Hooks → *Before User Created* → Postgres → séma `private`, függvény `hook_before_user_created`.

3. **Háztartás és engedélyezett címek.** A dashboard SQL Editorában (a címeket ott írd be, ne fájlba):

   ```sql
   with h as (insert into public.households (name) values ('Család') returning id)
   insert into private.allowed_emails (email, household_id, app_role)
   select lower(e.email), h.id, e.app_role
   from h, (values ('TE@PELDA.HU', 'admin'), ('FELESEGED@PELDA.HU', 'user')) as e(email, app_role);
   ```

   Az első belépéskor a trigger létrehozza a profilt és a háztartás-tagságot. Ha valaki már belépett, mielőtt a címe felkerült volna: a belépése elutasítva lett, fiók nem jött létre, a felvétel után egyszerűen újra be kell lépnie.

4. **Nyilvános adatok a kliensbe.** A `lib/v1/config.js`-be a Project URL és a publishable (anon) kulcs.

5. **Ellenőrzés anon kulccsal.**

   ```bash
   npm run check:rls
   ```

   Minden sornak „rendben”-nek kell lennie. Dashboard → Advisors → Security Advisor: ne legyen figyelmeztetés.

## Új felhasználó később

Egy sor az `allowed_emails` táblába, ugyanazzal a `household_id`-val:

```sql
insert into private.allowed_emails (email, household_id)
select lower('UJ@PELDA.HU'), id from public.households where name = 'Család';
```
