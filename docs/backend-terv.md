# Backend terv: Supabase a laszlobiri oldalak mögé

Állapot: **az 1. fázis kódja kész** (lásd az 5. szakaszt); az élesítéshez a kézi beállítások kellenek. A döntések és a még nyitott kérdések a dokumentum végén vannak.

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
| gyerekekről csak becenév és eredmény | `pupils`: becenév és ikonkód. `results` és `pupil_badges`: számok, téma- és jelvénykódok, szabad szöveg nélkül. A gyereknek nincs fiókja: a saját tabletje egy névtelen, csak a gyakorlásra jogosult eszközfiókkal működik (gyerek mód). |
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
- `email` (text, PK, kisbetűvel tárolva; az összehasonlítás `lower()`-rel), `household_id` (uuid, null lehet), `household_role` (`parent`), `app_role` (`admin` | `user`), `note`, `created_at`.

**`public.profiles`**
- `id` (uuid, PK, FK → `auth.users.id`, on delete cascade), `display_name` (1–40), `app_role` (`admin` | `user`), `created_at`.
- Az első bejelentkezéskor trigger tölti ki (security definer), az allowlist sora alapján.

**`public.households`**: `id`, `name`, `created_at`. Az elsőt kézzel hozod létre (seed).

**`public.household_members`**: itt él a szerepkör.
- `household_id`, `user_id`, `role`, `created_at`; PK: (`household_id`, `user_id`).
- Döntés: rajtatok kívül nincs más felhasználó, ezért egyetlen szerep van, a `parent` (check constraint). Te és a feleséged mindent láttok és szerkesztetek. Az oszlop azért marad, hogy egy későbbi szűkebb szerep (pl. csak bevásárlólista) egy migrációval felvehető legyen.

### Bevásárlólista

A mai állapot (`bevasarlo-lista.v1`):

```js
{ items:   [{ id, name, qty, cat, done, added }],  // egy lista, nincs pozíció, sorrend: kategória, azon belül az `added` időbélyeg
  history: [{ name, cat, count, last }] }          // legfeljebb 200 elem, ebből jönnek a gyorsjavaslatok és a válogató
```

A `cat` mező a kódban rögzített 9 kategória egyike: `zold`, `tej`, `hus`, `pek`, `szaraz`, `ital`, `fagy`, `haztartas`, `egyeb`. A hozzáadás a kis- és nagybetűt, valamint az ékezeteket figyelmen kívül hagyva (`fold()`) összevonja az azonos nevű tételeket („már rajta volt”).

**`public.lists`**
- `id` (uuid), `household_id`, `name` (1–60), `created_by`, `created_at`, `updated_at`, `deleted_at`.
- Döntés: háztartásonként **egy** közös lista. Egyedi index a `household_id`-n (élő sorokra), a lista a háztartással együtt jön létre (trigger), a UI ezt nyitja meg. A tábla azért külön, hogy később több lista is lehessen; akkor csak az egyedi indexet kell elvenni.

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

**`public.item_history`**: a gyorsjavaslatok. Döntés: háztartásonként közös, a „gyakran vett” mindkettőtöknél ugyanaz.
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
- Két gyerekprofil lesz. A profilokat a szülő a gyakorló oldalon hozza létre; a becenevek **nem kerülnek a repóba** (sem seedbe, sem tesztbe, sem dokumentációba), mert a repók publikusak. A tesztek kitalált beceneveket használnak.

**`public.results`**: egy sor egy befejezett kör vagy minijáték.
- `id` (uuid, kliens generálja: az offline beküldés ismétlése így nem duplikál)
- `pupil_id` (FK, cascade)
- `kind`: `round` | `hangman` | `wordsearch`
- `topic` (check `^[a-z0-9]{1,32}$`, `round` esetén kötelező)
- `score` (0–10), `best_streak` (0–10), `points` (az így szerzett pont), `answered`, `correct`
- `created_at`, `recorded_by` (FK → `auth.users`, on delete set null): a szülő vagy a gyerek mód eszközfiókja
- Döntés: a mai helyi pontok **nem kerülnek át**, a két gyerek nulláról indul. Ezért nincs import sor, és a `results` csak valódi körökből és minijátékokból áll.
- Index: (`pupil_id`, `created_at desc`).
- Döntés: **csak a befejezett kör számít**. Ma a félbehagyott kör jó válaszai is pontot érnek (válaszonként ment); az új modellben a pont, a megválaszolt és a jó válaszok száma a `finish()`-ben, egyszerre íródik. Ez a kijelentkezett, helyi üzemmódra is vonatkozik, hogy a két mód ugyanúgy számoljon.

**`public.pupil_badges`**: `pupil_id`, `badge_id` (check: `^[a-z0-9-]{1,32}$`), `earned_at`; PK: (`pupil_id`, `badge_id`). Csak beszúrás, `on conflict do nothing`.

### Gyerek mód: eszközfiók

Döntés: a gyerekek saját eszközön (pl. tablet) is gyakorolnak, ezért **gyerek mód** kell. A gyerek mód nem a felület elrejtésén múlik, hanem a szerveren: a tablet nem a szülő Google-munkamenetével fut, hanem egy **névtelen Supabase-fiókkal** (anonymous sign-in), amelynek csak a hozzárendelt gyerekprofilokhoz van joga. Így ha a gyerek a tableten megnyitja a `bevasarlas.` címet, ott sincs hozzáférése semmihez.

**`public.devices`**: egy sor egy párosított eszköz.
- `user_id` (PK, FK → `auth.users`, cascade): a névtelen fiók
- `household_id`, `label` (1–30, pl. „tablet”), `created_by` (a párosító szülő), `created_at`, `last_seen_at`
- Személyes adat nincs benne. A névtelen fióknak nincs e-mail címe.

**`public.device_pupils`**: `device_user_id`, `pupil_id`; PK mindkettő. Melyik gyerekprofil használható az eszközön (egy vagy mindkettő, ha közös a tablet).

**`private.device_pairings`**: egyszer használható párosító kódok, a `private` sémában.
- `code_hash` (PK; a kód maga nincs tárolva), `household_id`, `pupil_ids` (uuid[]), `label`, `created_by`, `expires_at` (10 perc), `used_at`.
- A kód 8 karakter egy félreolvashatatlan ábécéből (pl. `K7MQ-3XPD`), kb. 40 bit. 10 perces lejárattal és a Supabase rate limittel végigpróbálni nem lehet.

Függvények (`security definer`, `set search_path = ''`, `anon`-tól és `public`-tól visszavonva):
- `public.create_pairing(pupil_ids uuid[], label text) → text`: csak `parent` hívhatja, csak a saját háztartása gyerekeire. Visszaadja a kódot.
- `public.claim_pairing(code text) → void`: csak névtelen (`is_anonymous`), még párosítatlan fiók hívhatja. Ellenőrzi a lejáratot és az egyszeri használatot, létrehozza a `devices` és a `device_pupils` sorokat.
- `private.is_device_for(pupil_id) → bool`: a hívó eszközfiókhoz tartozik-e az adott gyerekprofil.

Takarítás (`pg_cron`, naponta):
- a párosítatlan névtelen fiókok törlése 24 óra után (`auth.users`, ahol `is_anonymous` és nincs `devices` sor);
- a lejárt párosító kódok törlése.

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
| `lists` | `is_member` | nincs (trigger hozza létre) | `is_member`, csak `name` | nincs |
| `items` | `is_member(list_household(list_id))` | ugyanaz, `created_by = auth.uid()` | ugyanaz using és with check ágon | soft delete updatettel |
| `item_history` | `is_member` | `is_member` | `is_member` | `parent` |
| `pupils` | `is_parent` vagy `is_device_for(id)` | `is_parent` | `is_parent`, csak `nickname`, `avatar` | `is_parent` (kaszkád az eredményekre) |
| `results` | `is_parent(pupil_household(pupil_id))` vagy `is_device_for(pupil_id)` | ugyanaz, `recorded_by = auth.uid()` | nincs | `is_parent` |
| `pupil_badges` | `is_parent(pupil_household(pupil_id))` vagy `is_device_for(pupil_id)` | ugyanaz | nincs | `is_parent` |
| `devices` | `is_parent(household_id)`, vagy saját sor | nincs (`claim_pairing`) | saját sor: csak `last_seen_at` | `is_parent` (visszavonás, kaszkád a `device_pupils`-ra) |
| `device_pupils` | `is_parent`, vagy saját eszköz sorai | nincs (`claim_pairing`) | nincs | `is_parent` |
| `private.*` | nem érhető el (a séma nincs közzétéve, nincs `usage` jog) | | | |

További szabályok:
- Az `anon` szerep egyik táblán sem kap jogot. A `bump_history` függvényt `revoke execute … from anon, public`, `grant … to authenticated`.
- Realtime: az `items` és a `lists` kerül a `supabase_realtime` publikációba. A `postgres_changes` alkalmazza az RLS-t.
- Minden migráció után a Supabase Security Advisor figyelmeztetései nullán legyenek.

### Tesztelés

**a) SQL tesztek (pgTAP, `supabase test db`)**, helyi Supabase-en vagy külön teszt-projekten. Két háztartás, három felhasználó (A1 és A2 az A háztartásban, B a B-ben), `set local role authenticated; set local request.jwt.claims = '{"sub": "…"}'` mellett:
- B semmit nem lát A listáiból, tételeiből, előzményeiből, gyerekeiből, eredményeiből, jelvényeiből;
- B update/delete A soraira 0 sort érint, insert A listájába RLS-hibát ad, `bump_history` A háztartására hibát ad;
- egy A-beli tétel nem mozgatható át B listájába (with check);
- A1 és A2 ugyanazt látja (a megosztás működik), A1 írása A2-nél Realtime eseményként megjelenik;
- háztartáshoz nem tartozó, de allowlistes felhasználó semmit nem lát;
- háztartásonként nem jöhet létre második lista;
- senki nem írhatja a saját `app_role`-ját és a `household_members` táblát;
- gyerek mód: az eszközfiók csak a hozzárendelt gyerekprofilt és annak eredményeit látja; nem lát listát, tételt, előzményt, más gyereket, más háztartást; nem írhat eredményt nem hozzárendelt gyereknek; nem hívhatja a `create_pairing`-et;
- a párosítatlan névtelen fiók semmit nem lát;
- a `claim_pairing` lejárt, már felhasznált vagy hibás kóddal hibát ad, és nem névtelen fiókkal sem hívható;
- a visszavont eszköz (`devices` sor törölve) érvényes tokennel sem lát semmit;
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

- **„Before User Created” auth hook** (`private.hook_before_user_created`): ha az e-mail nincs az `allowed_emails` táblában, a fiók létre sem jön. Kivétel a névtelen fiók (a gyerek mód miatt): az átengedhető, de semmihez nincs joga, amíg egy szülő által kiadott kóddal nem párosítják, és 24 óra után párosítás nélkül törlődik. (Az 1. fázisban ellenőrizni kell, hogy a hook eseménye tartalmazza-e az `is_anonymous` jelzőt.)
- A `profiles` trigger az allowlist sora alapján beállítja az `app_role`-t és a `household_members` sort.
- Második réteg: minden adat a háztartás-tagságon múlik.
- Opcionális harmadik réteg: a Google consent screen „Testing” módban, felvett tesztfelhasználókkal.
- Ki van kapcsolva: e-mail/jelszó, magic link. A névtelen belépés be van kapcsolva, alacsony rate limittel (Authentication → Rate Limits, pl. óránként 10 IP-címenként).

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

### Gyerek mód munkamenete

- Az eszközfiók munkamenete **nem** a közös sütiben él, hanem csak a `gyakorlas.laszlobiri.com` saját `localStorage`-ában, külön kulcs alatt (`lib/v1/device.js`). A többi aldomain nem látja.
- Párosítás, két út:
  1. **A tableten**: a szülő a tableten belép Google-lel, a gyakorló oldalon „Ez az eszköz gyerek módba kerül” → kiválasztja a gyereket (vagy mindkettőt) és a PIN-t. Az oldal kódot kér (`create_pairing`), **kilépteti a szülőt** (a közös süti törlődik, így a tableten a bevásárlólista sem marad nyitva), névtelenül belép és beváltja a kódot.
  2. **A szülő telefonjáról**: a szülői nézetben „Új eszköz” → kód 10 percig. A tableten „Gyerek mód” → kód beírása → PIN megadása.
- A gyerek mód felülete: csak a hozzárendelt gyerekprofilok választója és a gyakorlás. Nincs belépés gomb, nincs link a többi oldalra, nincs szülői nézet. Ha két gyerek közös tabletet használ, a profilváltás PIN nélküli.
- **Kilépés a gyerek módból**: „Szülő” gomb → 4 jegyű PIN → kijelentkezés és a helyi eszközadatok törlése. A PIN-t PBKDF2-vel (WebCrypto) hash-elve tároljuk az eszközön. A PIN csak kényelmi zár: ha a gyerek törli a böngésző adatait, azzal sem jut semmihez, csak a gyerek mód áll le.
- **Visszavonás**: a szülői nézet „Eszközök” listájából (név, utoljára látott). A törlés után az eszköz tokenje érvényes marad, de az RLS miatt semmit nem lát, és a takarítás a névtelen fiókot is törli.
- **Megmaradás**: iPaden a gyakorló oldalt a kezdőképernyőre telepítve kell használni. A böngészőfülben a Safari 7 nap használat nélkül törölheti a `localStorage`-ot, és akkor újra kell párosítani. A telepített app erre nem vonatkozik.

Döntés: **közös süti**. Ha a 0. fázis kísérlete valamelyik böngészőben elbukik, a tartalék a domainenkénti `localStorage` és aloldalanként egy kattintásos belépés; erről akkor külön döntünk.

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
    device.js           gyerek mód: eszközfiók-kliens saját localStorage-dzsal, pair(code), unpair(), PIN-ellenőrzés
    auth-badge.js       <lb-auth> web component (belépés gomb / név + kilépés), csak tokenes CSS
  build/README.md       a supabase.js újragenerálása (esbuild, rögzített verziók)
belepes/index.html      központi belépőoldal
adatvedelem/index.html  adatkezelési tájékoztató (GDPR)
supabase/
  migrations/           séma, RLS, hook, trigger, bump_history, pg_cron
  tests/                pgTAP
  seed.sql              háztartás + allowlist minta (valódi e-mail és becenév nélkül)
scripts/
  rls-check.mjs         fekete dobozos anon-teszt
  backup.sh             helyi, titkosított teljes mentés (lásd 4. fázis)
  restore-local.sh      visszaállítás próba helyi Supabase-be
```

Szabályok (a `tokens.css` mintájára, bekerülnek a design system README-be):
- Közzétett cím: `https://laszlobiri.com/lib/v1/…`. **Az útvonal és az exportált függvénynevek publikus szerződés.** Törő változásnál `lib/v2/` jön létre.
- Az aloldalak nem tartanak helyi másolatot, és CDN-t sem használnak közvetlenül.
- Ez a repó ágból, Jekyll-lel települ: a `lib/`, `belepes/`, `adatvedelem/` mappa változtatás nélkül kimegy. A `supabase/`, `scripts/` és `docs/` mappát egy `_config.yml` `exclude` sorral kihagyjuk a közzétételből (titok egyikben sincs, de a webre nem tartoznak).
- Kereszt-domain modulbetöltés: a `<script type="module">` CORS-t igényel. **Ellenőrizve (2026-11-14):** a `laszlobiri.com` válasza `access-control-allow-origin: *`, tehát az aloldalak betölthetik a `lib/v1` modulokat.
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
- **Állapot: kész.** Ami elkészült:
  - `supabase/migrations/20261114120000_core.sql`, `supabase/config.toml`, `supabase/seed.sql`, `supabase/README.md` (élesítési lépések);
  - `supabase/tests/001_core_rls.test.sql`: 38 pgTAP teszt, helyben futtatva `npm run test:db` (sima Postgres 16 + pgTAP, Supabase-stubbal);
  - `lib/v1/`: `config.js` (még üres), `client.js`, `auth.js`, `auth-badge.js`, `supabase.js` (supabase-js 2.118.0 + ssr 0.12.7, esbuild);
  - `belepes/`, `adatvedelem/`, `_config.yml`;
  - `scripts/rls-check.mjs` (anon kulccsal, éles projekten futtatandó), `scripts/login-smoke.mjs` (böngészős füstpróba ál-Supabase szerverrel, 16 ellenőrzés).
  - Eltérés a tervtől: az allowlist `text` oszlop `lower()`-rel, nem `citext` (üres `search_path` mellett a `citext` összehasonlítás kis- és nagybetű-érzékeny maradt). A trigger második rétegként akkor is elutasít, ha a hook nincs bekötve.
  - A Supabase-projekt elkészült (`eokwxkrcttsoxfflvuus`, a nyilvános adatok a `lib/v1/config.js`-ben). Valódi Supabase-en még nem futott: a migráció, a hook eseményformátuma (`is_anonymous`) és a `.laszlobiri.com` süti a projekt létrehozása után ellenőrizendő.

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
- Migráció: `pupils`, `results`, `pupil_badges`, tesztek.
- **Kijelentkezve**: a mai működés, egy helyi játékos (`gyakorlo.v1`).
- **Belépve**: a kezdőképernyőn „Ki gyakorol?” választó (becenév + ikon); a választott gyerek `id`-ja eszközönként `localStorage`-ban.
  - A mai `S` állapot gyerekenként a `results` és `pupil_badges` sorokból számolódik (`points` = a `points` összege, `rounds`, `perfect`, `best[topic]`, `played[topic]`, `days`/`lastDay` a dátumokból, `mgWins`/`wsWins` a `kind` alapján, `mgDone`/`mgN` a pontból). A `finish()` és a minijáték-győzelem egy-egy `results` sort ír; az új jelvény egy `pupil_badges` sort.
  - Az írás ugyanazzal a kimenő sorral történik (`lib/v1/outbox.js`), csak beszúrás, így offline gyakorlás is szinkronizálódik.
- **Átállás**: nincs. A `gyakorlo.v1` helyi állapot érintetlen marad, és kijelentkezve továbbra is az látszik; belépve a gyerekprofilok nulláról indulnak. Belépéskor egy egyszeri, rövid tájékoztatás jelzi, hogy a régi pontok ezen az eszközön, kijelentkezve maradnak meg.
- Szülői nézet: gyerekenként az utolsó körök, témánkénti legjobb és átlag, jelvények; „Eszközök” lista és „Új eszköz” párosítás.
- **Gyerek mód** (a 3. fázis második fele): migráció (`devices`, `device_pupils`, `private.device_pairings`, `create_pairing`, `claim_pairing`, takarítás), `lib/v1/device.js`, a gyerek mód felülete, PIN, visszavonás, tesztek. Kézi teszt egy iPaden telepített appként: párosítás, offline gyakorlás, visszakapcsolás, visszavonás, és hogy a tableten a `bevasarlas.` oldal üres.
- `sw.js` módosítás (lásd fent). A README „Nincs fiók, semmit nem küld sehová” mondata frissül: belépés nélkül ez igaz marad, belépve a szülő fiókjába ment.

### 4. fázis: mentés, export, üzemeltetés
- **Export az appban**: „Adataim letöltése” JSON-ban (lista, előzmények; szülőnek a gyerekprofilok, eredmények, jelvények). RLS alatt fut. A bevásárlólista JSON importot is kap.
- **Teljes mentés: `scripts/backup.sh`** (döntés: ingyenes csomag, tehát a mentés a mi dolgunk). A saját gépeden fut, nem GitHub Actionsben: a repók publikusak, és ott a jelszót és a mentett adatot is kezelni kellene.
  - Bemenet: a kapcsolati cím a `SUPABASE_DB_URL` környezeti változóból (a dashboard „Connect” → **Session pooler** címe, mert az ingyenes csomag közvetlen címe csak IPv6). A jelszó soha nem kerül fájlba vagy repóba; a szkript bekéri, ha nincs megadva.
  - Mit ment, a Supabase CLI-vel (`supabase db dump`, Docker kell hozzá):
    1. `schema.sql`: a `public` és a `private` séma szerkezete, policyk, függvények, triggerek;
    2. `data.sql`: a `public` és a `private` séma adatai (`--data-only`);
    3. `auth.sql`: csak az `auth.users` és az `auth.identities` adatai. Erre azért van szükség, mert a `profiles.id` ezekre hivatkozik; nélkülük a visszaállított adat gazdátlan lenne.
  - Utána: a három fájl egy `tar` csomagba, majd `age` jelszavas titkosítással egy `.tar.age` fájlba, `~/laszlobiri-backup/ÉÉÉÉ-HH-NN.tar.age` néven. A titkosítatlan fájlok törlődnek. A régiekből a legutóbbi 12 marad meg.
  - Ellenőrzés a szkript végén: egyik fájl sem üres, a `data.sql`-ben szerepelnek a `public.items` és a `public.results` sorai, és a titkosított fájl visszafejthető.
  - Gyakoriság: havonta, és minden migráció előtt. Emlékeztetőt érdemes a naptárba tenni.
  - A mentés helye legyen egy második helyen is (pl. külső lemez vagy Proton Drive), mert a gép elvesztése a mentést is viszi.
- **Visszaállítás próba: `scripts/restore-local.sh`**: a titkosított fájlt visszafejti, és egy helyi `supabase start` példányba tölti. Negyedévente érdemes lefuttatni: csak a visszaállított mentés bizonyítja, hogy a mentés jó.
- **Szüneteltetés**: az ingyenes projekt egy hét tétlenség után szünetel (az adat megmarad, a dashboardon egy kattintással újraindul). A bevásárlólista napi használata valószínűleg megelőzi. Ha mégis előfordul, egy heti GitHub Actions kérés a publikus kulccsal életben tarthatja; ehhez titok nem kell, de előbb ellenőrizni kell, hogy a Supabase aktivitásnak számítja-e.
- GDPR: tájékoztató (`/adatvedelem/`), Supabase DPA, gyerekprofil törlése kaszkádolva törli az eredményeket és jelvényeket, fiók törlése kérésre (admin SQL).

### 5. fázis (később): `ebed.`
A belépés gomb és a heti kijelölés közös mentése (`meal_picks`), ha igény lesz rá. Service worker nélkül, a `lib/v1` bekötésével.

## Amit neked kell kézzel beállítanod

### Supabase
1. Új projekt, régió **Central EU (Frankfurt)**. Az adatbázis-jelszót a jelszókezelőbe.
2. Project Settings → API: a **projekt URL** és a **publishable/anon kulcs** kell nekem (ezek publikusak). A service role / secret kulcsot ne küldd el, ne másold sehova.
3. Authentication → Providers: Google bekapcsolása (Client ID + Secret). E-mail provider ki. **Anonymous sign-ins be** (a gyerek módhoz), és Authentication → Rate Limits alatt a névtelen belépés korlátja alacsonyra.
4. Authentication → URL Configuration: Site URL `https://laszlobiri.com`; Redirect URLs: `https://laszlobiri.com/belepes/**`, fejlesztéshez `http://localhost:8000/**`.
5. Authentication → Hooks: „Before User Created” → `private.hook_before_user_created` (a migráció után).
6. A migrációk futtatása (Supabase CLI a gépedről, vagy SQL szerkesztő), utána a seed: háztartás, a te és a feleséged címe az allowlistbe (`parent`, te `admin`). Valódi e-mail cím nem kerül repóba.
7. A mentéshez a gépedre: Supabase CLI, Docker és `age`.
8. Organization settings → DPA elfogadása.
9. Opcionális: második projekt tesztelésre, vagy Docker a helyi `supabase start`-hoz.

### Google Cloud
1. Új projekt (pl. „laszlobiri”).
2. OAuth consent screen: External; név „laszlobiri”; authorized domain: `laszlobiri.com` és `eokwxkrcttsoxfflvuus.supabase.co` (a `supabase.co` a Public Suffix List része, ezért önmagában nem fogadja el a Google; ha a projektcímet sem, elég a `laszlobiri.com`); főoldal `https://laszlobiri.com`, adatvédelem `https://laszlobiri.com/adatvedelem/`. Scope-ok: `openid`, `email`, `profile`. Logót ne tölts fel (ellenőrzést indítana). Testing mód + tesztfelhasználók, vagy Production.
3. Ha domain-ellenőrzést kér: Search Console, **HTML-fájlos** módszer, nem DNS-rekord.
4. Credentials → OAuth client ID, „Web application”. Authorized redirect URI: `https://<projekt-ref>.supabase.co/auth/v1/callback`. JavaScript origin: `https://laszlobiri.com`.
5. A Client ID és Secret a Supabase Google providerébe kerül (a Secret csak oda).

### Repók
A 2. és 3. fázishoz a `bevasarlo-lista` és a `gyakorlas` repót írási joggal kell a munkamenethez adni.

## Döntések

| kérdés | döntés |
| --- | --- |
| munkamenet az aloldalak között | közös süti (`.laszlobiri.com`) |
| további felhasználó (pl. nagyszülő) | nincs, egyetlen `parent` szerep |
| gyerekprofilok | kettő; a becenevek csak az adatbázisban, a repóban nem |
| listák száma | egy közös lista háztartásonként |
| gyorsjavaslatok | közösek |
| félbehagyott kör | nem számít, csak a befejezett kör |
| mai helyi gyakorló pontok | nem kerülnek át, a gyerekek nulláról indulnak |
| csomag | ingyenes Supabase + helyi, titkosított mentő szkript |
| gyerekek saját eszköze | gyerek mód: névtelen, párosított eszközfiók, csak gyakorlásra jogosult, PIN-nel lehet kilépni belőle |

## Nyitott kérdések

Jelenleg nincs. A megvalósítás közben ellenőrizendő: a GitHub Pages CORS fejléce (4. szakasz), az iOS-re telepített PWA OAuth-visszairányítása (0. fázis), és hogy a Before User Created hook eseménye tartalmazza-e az `is_anonymous` jelzőt (1. fázis).
