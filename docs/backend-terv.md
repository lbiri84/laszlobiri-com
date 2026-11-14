# Backend terv: Supabase a laszlobiri oldalak mögé

Állapot: **terv, még nincs kód**. A nyitott kérdések a dokumentum végén vannak.

## Kiindulás

Egy közös Supabase-projekt lesz (EU, Frankfurt, `eu-central-1`): Google OAuth, Postgres, Row Level Security (RLS), Realtime. A frontend statikus marad, GitHub Pages-en.

### A négy repó mai állapota

| repó | cím | közzététel | tárolás most | service worker |
| --- | --- | --- | --- | --- |
| `laszlobiri-com` | `laszlobiri.com` | Pages, ágból (Actions nélkül, Jekyll-lel) | nincs | nincs |
| `interfood-menu` | `ebed.laszlobiri.com` | Actions (`update-menu.yml`), a `_site`-ba csak a felsorolt fájlok kerülnek | nincs, a kijelölés vágólapra megy | nincs |
| `bevasarlo-lista` | `bevasarlas.laszlobiri.com` | Pages, ágból | `localStorage['bevasarlo-lista.v1']` | `bevasarlo-v15`, hálózat először |
| `gyakorlas` | `gyakorlas.laszlobiri.com` | Pages, ágból | `localStorage['gyakorlo.v1']` | `gyakorlo-v5`, hálózat először |

Mindhárom aloldal egyetlen `index.html`, build nélkül, inline `<script>`-tel. Mindhárom a központi `tokens.css`-t tölti be, és a `data-theme="slate"` témát használja.

### Fix feltételek, és hogyan teljesül mindegyik

| feltétel | megoldás |
| --- | --- |
| DNS és Proton Mail rekordok nem változnak, nincs nameserver-váltás | Nincs Supabase custom domain (ahhoz CNAME kellene). Az auth a `<ref>.supabase.co` címen fut. A Google domain-ellenőrzés (ha kell) HTML-fájllal történik a GitHub Pages-en, nem DNS TXT rekorddal. A meglévő `bevasarlas`, `gyakorlas`, `ebed` CNAME-ek maradnak. |
| `tokens.css` útvonala és a változónevek érintetlenek | A közös kód külön mappába kerül (`lib/v1/`), a `design-system/` mappához nem nyúlunk. |
| csak a publikus kulcs és a projekt URL kerül kliensbe | A konfiguráció egyetlen fájlban (`lib/v1/config.js`) van. A service role / secret kulcs egyik repóban, Actions secretben vagy kliensben sem szerepel. |
| gyerekekről csak becenév és eredmény | `pupils`: becenév és ikonkód. `results` és `pupil_badges`: számok, téma- és jelvénykódok, szabad szöveg nélkül. A gyerek nem jelentkezik be. |
| a bevásárlólista offline is működik | IndexedDB-ben a lista helyi példánya és egy kimenő sor (outbox). Visszatérő hálózatnál a sor kiürül, utána delta-lekérés és Realtime. A service worker a Supabase-kéréseket nem érinti. |

## 1. Adatmodell

A megosztás a **háztartáson** keresztül történik. A feleséged ugyanannak a háztartásnak a tagja, így a közös listát és a gyerekek eredményeit is látja, anélkül hogy bármit külön meg kellene osztani.

```
auth.users ─1:1─ profiles ──< household_members >── households
                                                       │
                          ┌────────────────────────────┼──────────────────┐
                        lists                     item_history          pupils
                          │                                              │   │
                        items                                       results  pupil_badges

private.allowed_emails   (nem érhető el az API-ból)
```

### Közös táblák

**`private.allowed_emails`**: az allowlist a `private` sémában, amit a Data API nem tesz közzé.
- `email` (citext, PK), `household_id` (uuid, null lehet), `household_role` (`parent` | `member`), `app_role` (`admin` | `user`), `note`, `created_at`.

**`public.profiles`**
- `id` (uuid, PK, FK → `auth.users.id`, on delete cascade), `display_name` (1–40), `app_role` (`admin` | `user`), `created_at`.
- Az első bejelentkezéskor trigger tölti ki (security definer), az allowlist sora alapján.

**`public.households`**: `id`, `name`, `created_at`. Az elsőt kézzel hozod létre (seed).

**`public.household_members`**: itt él a szerepkör.
- `household_id`, `user_id`, `role` (`parent` | `member`), `created_at`; PK: (`household_id`, `user_id`).
- `parent`: mindent lát és szerkeszt. Te és a feleséged.
- `member`: csak a bevásárlólistát látja és szerkeszti (pl. nagyszülő). Gyerekadathoz nem fér hozzá.

### Bevásárlólista

A mai állapot (`bevasarlo-lista.v1`):

```js
{ items:   [{ id, name, qty, cat, done, added }],  // egy lista, nincs pozíció, sorrend: kategória, azon belül az `added` időbélyeg
  history: [{ name, cat, count, last }] }          // legfeljebb 200 elem, ebből jönnek a gyorsjavaslatok és a válogató
```

A `cat` mező a kódban rögzített 9 kategória egyike: `zold`, `tej`, `hus`, `pek`, `szaraz`, `ital`, `fagy`, `haztartas`, `egyeb`. A hozzáadás a kis- és nagybetűt, valamint az ékezeteket figyelmen kívül hagyva (`fold()`) összevonja az azonos nevű tételeket („már rajta volt”).

**`public.lists`**
- `id` (uuid), `household_id`, `name` (1–60), `created_by`, `created_at`, `updated_at`, `deleted_at`.
- Az app ma egy listát ismer. Háztartásonként egy „Közös lista” jön létre, a UI ezt nyitja meg. A tábla azért külön, hogy később több lista is lehessen (pl. „Drogéria”) séma-változás nélkül.

**`public.items`**: a mai tétel mezői, szerveroldali kiegészítéssel.
- `id` (uuid, **a kliens generálja** `crypto.randomUUID()`-dal, hogy offline is létrehozható legyen; a mai `uid()` azonosítók importkor új UUID-t kapnak)
- `list_id` (FK, cascade)
- `name` (1–80), `qty` (0–30): ugyanazok a korlátok, mint a mai link-importban
- `name_key` (text): a `fold(name)` eredménye, a kliens tölti ki
- `cat` (check: a 9 kategóriakód)
- `done` (bool), `added_at` (timestamptz, a mai `added`)
- `created_by`, `updated_by`, `updated_at` (szerver trigger), `deleted_at` (soft delete)
- Egyedi index: (`list_id`, `name_key`). Törléskor a trigger a `name_key`-t `null`-ra állítja, így a törölt tétel nem akadályozza az újra felvételt. Ez kezeli azt az esetet, amikor két telefon offline ugyanazt veszi fel: a második beküldés ütközik, és a kliens a meglévő tételhez csatlakozik (`done = false`, a `qty` frissül). Ez ugyanaz a viselkedés, mint ma a „már rajta volt”.
- A soft delete a delta-szinkron miatt kell (a másik eszköz így tudja meg a törlést), és a mai visszavonás is erre épül: a visszavonás egyszerűen törli a `deleted_at` értékét. 30 nap után `pg_cron` véglegesen törli.
- Index: (`list_id`, `updated_at`).

**`public.item_history`**: a gyorsjavaslatok, háztartásonként közösen (a „gyakran vett” így mindkettőtöknél ugyanaz).
- `household_id`, `name_key`, `name`, `cat`, `count`, `last_used`; PK: (`household_id`, `name_key`).
- Növelés egy `security invoker` függvénnyel: `bump_history(household_id, name, cat)` (`insert … on conflict do update set count = count + 1`), így két eszköz egyidejű növelése sem veszik el. A 200-as felső korlát marad: a kliens csak az első 200-at kéri le.

### Gyakorló oldal

A mai állapot (`gyakorlo.v1`) egyetlen, eszközhöz kötött játékos:

```js
{ points, answered, correct, rounds, perfect,
  best: { [topic]: maxScore }, played: { [topic]: 1 }, badges: { [badgeId]: 'YYYY-MM-DD' },
  days, lastDay, mgDone, mgWins, mgN, wsWins }
```

A témakódok a `TOPICS` listából jönnek (`szamok200`, `osszkiv`, `jly`, `emlos` …, és a `vegyes`). Egy kör 10 kérdés; jó válaszonként 10 pont, hibátlan körért +50; minijáték-győzelemért +10.

Javaslat: **az eredmények csak hozzáfűzhető események**, a pontszámot, a szintet, a napi sorozatot és a `best`/`played` értéket a kliens számolja ki belőlük. Így két eszköz offline játéka sem ütközik: a szinkron egyszerű unió.

**`public.pupils`**
- `id`, `household_id`, `nickname` (1–20, egyedi háztartáson belül), `avatar` (check: rögzített kódlista, pl. `fox`, `owl`), `created_at`.

**`public.results`**: egy sor egy befejezett kör vagy minijáték.
- `id` (uuid, kliens generálja: az offline beküldés ismétlése így nem duplikál)
- `pupil_id` (FK, cascade)
- `kind`: `round` | `hangman` | `wordsearch` | `import`
- `topic` (check `^[a-z0-9]{1,32}$`, `round` esetén kötelező)
- `score` (0–10), `best_streak` (0–10), `points` (az így szerzett pont), `answered`, `correct`
- `created_at`, `recorded_by` (FK → profiles)
- Az `import` sor a mai helyi állapot átvitelére szolgál: a `points`, `answered`, `correct` és `rounds` összesítőt egy sorban hozza át. A témánkénti `best`/`played` és a napi sorozat nem jön át; a már megszerzett jelvények viszont igen (lásd lent).
- Index: (`pupil_id`, `created_at desc`).
- A félbehagyott kör ma is számít a `points`/`answered` értékbe (válaszonként ment). Az új modellben csak a befejezett kör kerül be. Ez apró viselkedésváltozás.

**`public.pupil_badges`**: `pupil_id`, `badge_id` (check: `^[a-z0-9-]{1,32}$`), `earned_at`; PK: (`pupil_id`, `badge_id`). Csak beszúrás, `on conflict do nothing`.

### Ebéd (Interfood)

Most nem kap táblát. A kijelölés továbbra is vágólapra megy. Később szóba jöhet a heti kijelölés megosztása (`meal_picks`: `household_id`, `week`, `codes[]`), ugyanazzal a mintával, mint a bevásárlólista.

## 2. Szerepkörök és RLS

### Segédfüggvények

A `private` sémában, `security definer`, `stable`, `set search_path = ''`:
- `private.is_member(hid)`, `private.is_parent(hid)`
- `private.list_household(lid)`, `private.pupil_household(pid)`

A policykban `(select auth.uid())` formát használunk. A `security definer` függvények kerülik meg a `household_members` saját RLS-ét, így nincs rekurzió.

### Policyk táblánként

| tábla | select | insert | update | delete |
| --- | --- | --- | --- | --- |
| `profiles` | saját sor, és akikkel közös háztartásban vagy | nincs (trigger) | csak saját sor, **csak** `display_name` (oszlopszintű `grant`) | nincs (kaszkád) |
| `households` | tag | nincs | `parent`: csak `name` | nincs |
| `household_members` | a saját háztartásaid tagjai | nincs (allowlist + trigger, vagy admin SQL) | nincs | nincs |
| `lists` | `is_member` | `is_member`, `created_by = auth.uid()` | `is_member` régi és új `household_id`-ra | soft delete; valódi delete csak `parent` |
| `items` | `is_member(list_household(list_id))` | ugyanaz, `created_by = auth.uid()` | ugyanaz using és with check ágon | soft delete updatettel |
| `item_history` | `is_member` | `is_member` | `is_member` | `parent` |
| `pupils` | `is_parent` | `is_parent` | `is_parent`, csak `nickname`, `avatar` | `is_parent` (kaszkád az eredményekre) |
| `results` | `is_parent(pupil_household(pupil_id))` | ugyanaz, `recorded_by = auth.uid()` | nincs | `is_parent` |
| `pupil_badges` | `is_parent(pupil_household(pupil_id))` | ugyanaz | nincs | `is_parent` |
| `private.*` | nem érhető el (a séma nincs közzétéve, nincs `usage` jog) | | | |

További szabályok:
- Az `anon` szerep egyik táblán sem kap jogot. A `bump_history` függvényt `revoke execute … from anon, public`, `grant … to authenticated`.
- Realtime: az `items` és a `lists` kerül a `supabase_realtime` publikációba. A `postgres_changes` alkalmazza az RLS-t.
- Minden migráció után a Supabase Security Advisor figyelmeztetései nullán legyenek.

### Tesztelés

**a) SQL tesztek (pgTAP, `supabase test db`)**, helyi Supabase-en vagy külön teszt-projekten. Két háztartás, három felhasználó (A szülő, A tag, B szülő), `set local role authenticated; set local request.jwt.claims = '{"sub": "…"}'` mellett:
- B semmit nem lát A listáiból, tételeiből, előzményeiből, gyerekeiből, eredményeiből, jelvényeiből;
- B update/delete A soraira 0 sort érint, insert A listájába RLS-hibát ad, `bump_history` A háztartására hibát ad;
- egy A-beli tétel nem mozgatható át B listájába (with check);
- az A tag nem lát `pupils`/`results`/`pupil_badges` sort;
- senki nem írhatja a saját `app_role`-ját és a `household_members` táblát;
- `anon` szereppel minden tábla 0 sort vagy jogosultsági hibát ad.

**b) Fekete dobozos teszt anon kulccsal** (`scripts/rls-check.mjs`, Node + `@supabase/supabase-js`, csak URL + anon kulcs):
1. Bejelentkezés nélkül minden táblára `select` → üres vagy 401/42501, `insert` → hiba, `rpc('bump_history')` → hiba, a `private` séma → nem elérhető.
2. Két tesztfiókkal (csak a teszt-projekten, jelszavas belépéssel, ami élesben ki van kapcsolva): B lekéri A listáját ismert `id` alapján → üres; módosítja → 0 sor; Realtime csatornát nyit A listájára, A közben ír → B nem kap eseményt.
3. Élesben csak az 1. pont fut.

## 3. Bejelentkezés, allowlist, közös munkamenet

### Folyamat

1. Az aloldalon „Belépés” gomb → `https://laszlobiri.com/belepes/?next=https://bevasarlas.laszlobiri.com/`.
2. A belépőoldal `signInWithOAuth({ provider: 'google', … })` hívással a Google-höz visz (PKCE, csak `openid email profile`).
3. Visszatéréskor a belépőoldal kicseréli a `code`-ot munkamenetre, és a `next` címre irányít. A `next` csak `https://laszlobiri.com` vagy a három aloldal lehet (fix lista, nyitott átirányítás ellen).
4. Elutasított cím esetén: „Ez a cím nincs engedélyezve.”

Egyetlen visszahívási cím van a Supabase-ben és a Google-ben, és az aloldalak nem foglalkoznak OAuth-tal.

### Allowlist

- **„Before User Created” auth hook** (`private.hook_before_user_created`): ha az e-mail nincs az `allowed_emails` táblában, a fiók létre sem jön.
- A `profiles` trigger az allowlist sora alapján beállítja az `app_role`-t és a `household_members` sort.
- Második réteg: minden adat a háztartás-tagságon múlik.
- Opcionális harmadik réteg: a Google consent screen „Testing” módban, felvett tesztfelhasználókkal.
- Ki van kapcsolva: e-mail/jelszó, magic link, anonim belépés.

### Közös munkamenet az aloldalak között

A `localStorage` domainenként külön van, ezért a munkamenet **sütiben** él: `Domain=.laszlobiri.com; Secure; SameSite=Lax; Path=/`, a `@supabase/ssr` `createBrowserClient` függvényével (ez darabolja a 4 KB fölötti sütit). Egy belépés mind a négy címen érvényes, a kilépés mindenhol kiléptet.

Ismert korlátok:
- A süti JavaScriptből olvasható (mint a `localStorage`), ezért az XSS a fő kockázat. A mai kód `innerHTML`-t használ `esc()` függvénnyel. Eddig csak a saját bevitel jelent meg, ezután **a másik felhasználó által beírt szöveg** is. Teendők:
  - minden szerverről jövő mező csak `esc()`-en keresztül kerülhet a DOM-ba;
  - a `cat` csak a 9 ismert kód egyike lehet (adatbázis check és kliens ellenőrzés is, mert attribútumba és szótárkeresésbe kerül);
  - az `id` UUID formátum-ellenőrzésen megy át, mielőtt `data-id`-be kerül;
  - `<meta http-equiv="Content-Security-Policy">` legalább `connect-src 'self' https://<ref>.supabase.co wss://<ref>.supabase.co https://laszlobiri.com` és `script-src 'self' https://laszlobiri.com 'unsafe-inline'` tartalommal. Az `'unsafe-inline'` addig marad, amíg az inline szkript külön fájlba nem kerül.
- A süti minden kéréssel a GitHub Pages szerverekhez is elmegy (TLS-en). Az access token 1 óráig él, a refresh token forog.
- Safari (ITP) a JavaScriptből írt sütit legfeljebb 7 napig tartja meg. Óránként újraíródik, így csak egy hét teljes kihagyás után kell újra belépni.
- iOS-en a kezdőképernyőre tett PWA-nak (mindkét aloldalon van `apple-mobile-web-app-capable`) külön tárolója van, ott egyszer külön be kell lépni. Az OAuth-visszairányítást telepített PWA-ban a 0. fázisban ki kell próbálni.
- Két aloldal egyszerre frissítheti a tokent. Ezt a refresh token reuse interval (alapból 10 s) kezeli.

Tartalék, ha a közös süti nem elfogadható: domainenkénti `localStorage`, és aloldalanként egy kattintás a belépés.

## 4. A közös kliens kód helye és bekötése

Ebben a repóban, a `design-system/` mellett:

```
design-system/          (változatlan)
lib/
  v1/
    config.js           projekt URL + anon/publishable kulcs (publikus)
    supabase.js         előre buildelt, rögzített verziójú ESM csomag (@supabase/supabase-js + @supabase/ssr)
    client.js           egyetlen kliens példány, közös süti-beállításokkal
    auth.js             getUser(), signIn(next), signOut(), onAuthChange(cb)
    outbox.js           IndexedDB kimenő sor: enqueue(op), flush(handlers), a két aloldal közös mintája
    auth-badge.js       <lb-auth> web component (belépés gomb / név + kilépés), csak tokenes CSS
  build/README.md       a supabase.js újragenerálása (esbuild, rögzített verziók)
belepes/index.html      központi belépőoldal
adatvedelem/index.html  adatkezelési tájékoztató (GDPR)
supabase/
  migrations/           séma, RLS, hook, trigger, bump_history, pg_cron
  tests/                pgTAP
  seed.sql              háztartás + allowlist minta (valódi e-mail nélkül)
scripts/rls-check.mjs   fekete dobozos anon-teszt
```

Szabályok (a `tokens.css` mintájára, bekerülnek a design system README-be):
- Közzétett cím: `https://laszlobiri.com/lib/v1/…`. **Az útvonal és az exportált függvénynevek publikus szerződés.** Törő változásnál `lib/v2/` jön létre.
- Az aloldalak nem tartanak helyi másolatot, és CDN-t sem használnak közvetlenül.
- Ez a repó ágból, Jekyll-lel települ: a `lib/`, `belepes/`, `adatvedelem/` mappa változtatás nélkül kimegy. A `supabase/`, `scripts/` és `docs/` mappát egy `_config.yml` `exclude` sorral kihagyjuk a közzétételből (titok egyikben sincs, de a webre nem tartoznak).
- Kereszt-domain modulbetöltés: a `<script type="module">` CORS-t igényel. A GitHub Pages `Access-Control-Allow-Origin: *` fejlécet küld; ezt az első bekötésnél a böngésző hálózati paneljén ellenőrizzük (ebből a munkamenetből nem tudtam lekérni).
- Az `interfood-menu` közzétételén nem kell változtatni, mert a `lib/v1` a `laszlobiri.com`-ról jön, nem a saját `_site`-jából.

Bekötés egy aloldalon (a mai `<head>` mellé):

```html
<link rel="preconnect" href="https://laszlobiri.com">
<link rel="stylesheet" href="https://laszlobiri.com/design-system/tokens.css">
<script type="module">
  import { getUser, onAuthChange } from 'https://laszlobiri.com/lib/v1/auth.js';
  import { supabase } from 'https://laszlobiri.com/lib/v1/client.js';
  import 'https://laszlobiri.com/lib/v1/auth-badge.js';
</script>
```

A mai kód IIFE, klasszikus `<script>`-ben. A bekötéshez át kell állnia `type="module"`-ra (vagy dinamikus `import()`-ra). Ez a 2. és 3. fázis első lépése.

### Service worker módosítások (mindkét PWA)

A mai `sw.js` minden GET kérést hálózat-először kezel, és **mindent** elment a gyorsítótárba, kereszt-domain kérést is, a válasz állapotától függetlenül. Ez a backenddel így nem maradhat:
- `*.supabase.co` és a `laszlobiri.com/belepes/` kérésekre a fetch kezelő azonnal visszatér (`return`, nincs `respondWith`). Ez megakadályozza, hogy API-válasz vagy tokenes kérés a gyorsítótárba kerüljön, vagy offline elavult adat jöjjön vissza belőle.
- Csak `res.ok` választ mentünk el.
- A `lib/v1/*` és a `tokens.css` a meglévő hálózat-először ágon megy, első betöltéskor elmentődik (a README PWA-szabálya szerint nem kerül az `ASSETS` listába).
- A verzió emelése: `bevasarlo-v16`, `gyakorlo-v6`.

## 5. Megvalósítási sorrend

### 0. fázis: előkészítés és kísérlet
- Supabase-projekt és Google OAuth kliens (lásd lent).
- Kísérlet a `laszlobiri.com/belepes/` oldallal: a munkamenet látszik-e a `bevasarlas.` címen. Asztali Chrome, Android Chrome, iOS Safari, **iOS-re telepített PWA**.

### 1. fázis: alap (`laszlobiri-com`)
- Migrációk: `profiles`, `households`, `household_members`, `private.allowed_emails`, hook, trigger, segédfüggvények.
- `lib/v1/`, `belepes/`, `adatvedelem/`, `_config.yml` exclude.
- pgTAP az alaptáblákra, `rls-check.mjs` 1. pont.

### 2. fázis: bevásárlólista (`laszlobiri-com` migráció + `bevasarlo-lista`)
- Migráció: `lists`, `items`, `item_history`, `bump_history`, Realtime publikáció, `pg_cron` takarítás. Tesztek.
- Az `index.html` átállítása modulra. Az adatréteg két üzemmódja:
  - **Kijelentkezve**: pontosan a mai működés (`localStorage`, link- és szöveges megosztás).
  - **Belépve**: IndexedDB (`items`, `history`, `outbox`, `meta`), a UI a helyi adatból rajzol, minden módosítás azonnal helyben megjelenik és a kimenő sorba kerül.
- A mai műveletek leképezése:

  | mai művelet | új művelet |
  | --- | --- |
  | `addItem` (új) | `upsert` kliens-UUID-dal + `bump_history`; `name_key` ütközéskor csatlakozás a meglévőhöz |
  | `addItem` (már rajta van) | `update done=false, qty` |
  | pipálás | `update done` |
  | szerkesztés | `update name, name_key, qty, cat` + `bump_history` |
  | törlés / visszavonás | `update deleted_at = now()` / `deleted_at = null` |
  | „Kipipáltak törlése” | `update deleted_at` szűrővel (`list_id`, `done = true`) |
  | „Mind visszaállítása” | `update done=false` szűrővel |
  | „Teljes lista törlése” | `update deleted_at` szűrővel (`list_id`) |
  | `storage` esemény (más fül) | `BroadcastChannel` + Realtime |

- Szinkron indul: megnyitáskor, `online` eseménykor, `visibilitychange` eseménykor. Sorrend: token frissítése → kimenő sor sorrendben → delta-lekérés (`updated_at > utolsó szinkron`, a töröltekkel) → Realtime feliratkozás. iOS-en nincs Background Sync, ezért nem építünk rá.
- Ütközés: mezőnként az utolsó szerverre érkező írás nyer; a pipálás és a szöveg külön frissül.
- **Átállás**: első belépéskor, ha a `bevasarlo-lista.v1` nem üres: „Feltöltöd a telefonon lévő listát a közös listába?” Az `items` új UUID-t kap, a `history` a `count` értékkel megy át. A régi kulcs megmarad (nem töröljük), amíg a felhasználó ki nem jelentkezik vagy „Helyi lista törlése” nem lesz.
- A „Lista küldése linkként” megmarad (nem belépett embernek is működik), de a menüben a közös lista lesz az elsődleges.
- `sw.js` módosítás (lásd fent).
- Kézi teszt: két telefon, az egyik repülő módban; mindkettő felveszi a „Tej”-et, pipál, töröl; visszakapcsolás után a két lista egyezik, és nincs dupla „Tej”.

### 3. fázis: gyakorló oldal (`laszlobiri-com` migráció + `gyakorlas`)
- Migráció: `pupils`, `results`, `pupil_badges`, tesztek a `parent`/`member` különbségre.
- **Kijelentkezve**: a mai működés, egy helyi játékos (`gyakorlo.v1`).
- **Belépve**: a kezdőképernyőn „Ki gyakorol?” választó (becenév + ikon); a választott gyerek `id`-ja eszközönként `localStorage`-ban.
  - A mai `S` állapot gyerekenként a `results` és `pupil_badges` sorokból számolódik (`points` = a `points` összege, `rounds`, `perfect`, `best[topic]`, `played[topic]`, `days`/`lastDay` a dátumokból, `mgWins`/`wsWins` a `kind` alapján, `mgDone`/`mgN` a pontból). A `finish()` és a minijáték-győzelem egy-egy `results` sort ír; az új jelvény egy `pupil_badges` sort.
  - Az írás ugyanazzal a kimenő sorral történik (`lib/v1/outbox.js`), csak beszúrás, így offline gyakorlás is szinkronizálódik.
- **Átállás**: első belépéskor, ha a `gyakorlo.v1` nem üres: „Kié ez az eredmény?” → a választott gyerekhez egy `import` sor és a meglévő jelvények.
- Szülői nézet: gyerekenként az utolsó körök, témánkénti legjobb és átlag, jelvények.
- `sw.js` módosítás (lásd fent). A README „Nincs fiók, semmit nem küld sehová” mondata frissül: belépés nélkül ez igaz marad, belépve a szülő fiókjába ment.

### 4. fázis: mentés, export, üzemeltetés
- **Export az appban**: „Adataim letöltése” JSON-ban (lista, előzmények; szülőnek a gyerekprofilok, eredmények, jelvények). RLS alatt fut. A bevásárlólista JSON importot is kap.
- **Teljes mentés**: havonta helyben `supabase db dump` a saját gépeden, titkosított helyre. GitHub Actionsbe nem tesszük (publikus repók, jelszó és artefaktumok kezelése).
- Ingyenes csomag: nincs letölthető napi mentés, és egy hét tétlenség után a projekt szünetel. A bevásárlólista napi használata ezt valószínűleg megelőzi.
- GDPR: tájékoztató (`/adatvedelem/`), Supabase DPA, gyerekprofil törlése kaszkádolva törli az eredményeket és jelvényeket, fiók törlése kérésre (admin SQL).

### 5. fázis (később): `ebed.`
A belépés gomb és a heti kijelölés közös mentése (`meal_picks`), ha igény lesz rá. Service worker nélkül, a `lib/v1` bekötésével.

## Amit neked kell kézzel beállítanod

### Supabase
1. Új projekt, régió **Central EU (Frankfurt)**. Az adatbázis-jelszót a jelszókezelőbe.
2. Project Settings → API: a **projekt URL** és a **publishable/anon kulcs** kell nekem (ezek publikusak). A service role / secret kulcsot ne küldd el, ne másold sehova.
3. Authentication → Providers: Google bekapcsolása (Client ID + Secret). E-mail provider és anonim belépés ki.
4. Authentication → URL Configuration: Site URL `https://laszlobiri.com`; Redirect URLs: `https://laszlobiri.com/belepes/**`, fejlesztéshez `http://localhost:8000/**`.
5. Authentication → Hooks: „Before User Created” → `private.hook_before_user_created` (a migráció után).
6. A migrációk futtatása (Supabase CLI a gépedről, vagy SQL szerkesztő), utána a seed: háztartás, a te és a feleséged címe az allowlistbe (`parent`, te `admin`). Valódi e-mail cím nem kerül repóba.
7. Organization settings → DPA elfogadása.
8. Opcionális: második projekt tesztelésre, vagy Docker a helyi `supabase start`-hoz.

### Google Cloud
1. Új projekt (pl. „laszlobiri”).
2. OAuth consent screen: External; név „laszlobiri”; authorized domain: `laszlobiri.com` és `supabase.co`; főoldal `https://laszlobiri.com`, adatvédelem `https://laszlobiri.com/adatvedelem/`. Scope-ok: `openid`, `email`, `profile`. Logót ne tölts fel (ellenőrzést indítana). Testing mód + tesztfelhasználók, vagy Production.
3. Ha domain-ellenőrzést kér: Search Console, **HTML-fájlos** módszer, nem DNS-rekord.
4. Credentials → OAuth client ID, „Web application”. Authorized redirect URI: `https://<projekt-ref>.supabase.co/auth/v1/callback`. JavaScript origin: `https://laszlobiri.com`.
5. A Client ID és Secret a Supabase Google providerébe kerül (a Secret csak oda).

### Repók
A 2. és 3. fázishoz a `bevasarlo-lista` és a `gyakorlas` repót írási joggal kell a munkamenethez adni.

## Nyitott kérdések

1. **Közös süti**: elfogadod a `.laszlobiri.com` domainű, JavaScriptből írt munkamenet-sütit a fenti korlátokkal, vagy inkább aloldalanként egy kattintás a belépés?
2. **`member` szerepkör**: kell-e rajtatok kívül valaki (pl. nagyszülő), aki csak a bevásárlólistát látja?
3. **Gyerekek**: hány gyerekprofil lesz, és a ti telefonotokon vagy saját eszközön gyakorolnak? Ma a `gyakorlo.v1` eszközönként egy játékos. Ha a mai pontok több gyerekéi vegyesen, az import csak egy gyerekhez tudja rendelni őket.
4. **Egy vagy több lista**: elég a háztartásonként egy közös lista (a mai működés), vagy kell több (pl. „Drogéria”, „Hétvége”)? A séma mindkettőt tudja, a UI-ban ez külön munka.
5. **Gyorsjavaslatok**: a „gyakran vett” közös legyen (javaslat), vagy személyenként külön?
6. **Félbehagyott kör**: rendben van, hogy az új modellben csak a befejezett kör pontjai számítanak?
7. **Csomag**: elég az ingyenes Supabase (szünetelés egy hét tétlenség után, nincs letölthető mentés), vagy számolsz a Pro csomaggal?
