# Backend terv: Supabase a laszlobiri oldalak mögé

Állapot: **terv, még nincs kód**. A nyitott kérdések a dokumentum végén vannak.

## Kiindulás

- A `laszlobiri.com`, az `ebed.`, a `bevasarlas.` és a `gyakorlas.` aloldal statikus, GitHub Pages-en fut. Ez így marad.
- Egy közös Supabase-projekt lesz (EU, Frankfurt, `eu-central-1`): Google OAuth, Postgres, Row Level Security (RLS), Realtime.
- A design system szerződése érvényes marad: a `design-system/tokens.css` útvonala és a változónevek nem változnak. Az új közös kód ugyanígy viselkedik: verziózott, publikus útvonal, helyi másolat nélkül.

Fix feltételek, és hogyan teljesül mindegyik:

| feltétel | megoldás |
| --- | --- |
| DNS és Proton Mail rekordok nem változnak, nincs nameserver-váltás | Nincs Supabase custom domain (ahhoz CNAME kellene). Az auth a `<ref>.supabase.co` címen fut. A Google domain-ellenőrzés (ha kell) HTML-fájllal történik a GitHub Pages-en, nem DNS TXT rekorddal. |
| `tokens.css` útvonala és a változónevek érintetlenek | A közös kód külön mappába kerül (`lib/v1/`), a `design-system/` mappához nem nyúlunk. |
| csak a publikus (anon / publishable) kulcs és a projekt URL kerül kliensbe | A konfiguráció egyetlen fájlban (`lib/v1/config.js`) van. A service role / secret kulcs semmilyen repóban, Actions secretben vagy kliensben nem szerepel; csak a Supabase dashboardon és a saját jelszókezelődben. |
| gyerekekről csak becenév és eredmény | A `pupils` táblában csak becenév és egy szín/ikon kód van, semmi más (se születési dátum, se fotó, se iskola). A gyerek nem jelentkezik be, nincs auth fiókja. |
| bevásárlólista offline is működik, visszatérő hálózatnál szinkronizál | IndexedDB-ben a lista helyi példánya és egy „kimenő sor” (outbox); a service worker az app shellt szolgálja ki; online eseménynél a sor kiürül, utána delta-lekérés és Realtime. |

## 1. Adatmodell

Két szint: **alkalmazásszintű** felhasználó (`profiles`) és **háztartás** (`households`), amin keresztül a megosztás történik. A feleséged ugyanannak a háztartásnak a tagja, így minden listát és a gyerekek eredményeit is látja, anélkül hogy listánként meg kellene osztani.

```
auth.users (Supabase)
   │ 1:1
profiles ──< household_members >── households
                                       │
                         ┌─────────────┼─────────────┐
                       lists         pupils
                         │             │
                       items        results

private.allowed_emails   (nem érhető el az API-ból)
```

### Táblák

**`private.allowed_emails`** – allowlist, a `private` sémában, amit a Data API nem tesz közzé.
- `email` (citext, PK), `household_id` (uuid, null lehet), `household_role` (`parent` | `member`), `app_role` (`admin` | `user`), `note`, `created_at`.

**`public.profiles`** – egy sor bejelentkezett felhasználónként.
- `id` (uuid, PK, FK → `auth.users.id`, on delete cascade)
- `display_name` (text, 1–40 karakter)
- `app_role` (`admin` | `user`, alapértelmezés `user`)
- `created_at`
- Trigger tölti ki az első bejelentkezéskor (`auth.users` insert után, security definer), az allowlist sorából.

**`public.households`**
- `id` (uuid, PK), `name` (text), `created_at`
- Az elsőt kézzel hozod létre (seed SQL). Kliens nem hoz létre háztartást.

**`public.household_members`** – a szerepkör itt él.
- `household_id` (FK, cascade), `user_id` (FK → `profiles`, cascade), `role` (`parent` | `member`), `created_at`
- PK: (`household_id`, `user_id`)
- `parent`: mindent lát és szerkeszt (listák, gyerekprofilok, eredmények). Te és a feleséged.
- `member`: csak a listákat látja és szerkeszti (pl. nagyszülő, bébiszitter). Gyerekadathoz nem fér hozzá.

**`public.lists`**
- `id` (uuid, PK, **kliens generálja**, hogy offline létrehozható legyen), `household_id` (FK), `name` (1–60), `position` (int), `archived_at`, `created_by` (FK → profiles), `created_at`, `updated_at`, `deleted_at`

**`public.items`**
- `id` (uuid, PK, kliens generálja), `list_id` (FK, cascade), `text` (1–200), `quantity` (text, 0–30), `checked` (bool), `position` (numeric, a sorrendhez beszúrás átszámozás nélkül), `created_by`, `updated_by`, `created_at`, `updated_at` (szerver trigger állítja), `deleted_at` (soft delete)
- Index: (`list_id`, `updated_at`) a delta-szinkronhoz.
- A soft delete azért kell, hogy a másik eszköz a delta-lekérésnél megtudja a törlést. 30 nap után `pg_cron` véglegesen törli.

**`public.pupils`** – gyerekprofilok, nem felhasználók.
- `id` (uuid, PK), `household_id` (FK), `nickname` (1–20 karakter, egyedi háztartáson belül), `avatar` (rövid kód egy rögzített listából, pl. `fox`, `owl`; check constraint), `created_at`
- Semmi más. A UI kéri, hogy becenevet adj, ne teljes nevet.

**`public.results`**
- `id` (uuid, PK, kliens generálja: az offline beküldés ismétlése így nem duplikál), `pupil_id` (FK, cascade), `exercise` (text, `^[a-z0-9_.-]{1,64}$`, pl. `szorzotabla.7`), `score` (int ≥ 0), `max_score` (int > 0, `score ≤ max_score`), `duration_s` (int, null lehet), `created_at`, `recorded_by` (FK → profiles)
- Szabad szöveg nincs benne (nehogy véletlenül személyes adat kerüljön bele).
- Index: (`pupil_id`, `created_at desc`).

Minden `public` táblán: RLS bekapcsolva, `anon` szerepnek **semmilyen** jog, `authenticated` szerepnek csak a szükséges műveletekre és oszlopokra.

## 2. Szerepkörök és RLS

### Segédfüggvények

A `private` sémában, `security definer`, `stable`, `set search_path = ''`:
- `private.is_member(hid uuid) → bool`: a hívó (`auth.uid()`) tagja-e a háztartásnak.
- `private.is_parent(hid uuid) → bool`: `parent` szerepű tag-e.
- `private.list_household(lid uuid) → uuid`, `private.pupil_household(pid uuid) → uuid`.

A policykban `(select auth.uid())` formát használunk (soronként egyszer értékelődik ki). A függvények `security definer`-ek, hogy a `household_members` saját RLS-e ne okozzon rekurziót.

### Policyk táblánként

| tábla | select | insert | update | delete |
| --- | --- | --- | --- | --- |
| `profiles` | saját sor, és akikkel közös háztartásban vagy (név a „ki írta fel” megjelenítéshez) | nincs (trigger) | csak saját sor, **csak** `display_name` oszlop (oszlopszintű `grant update (display_name)`); az `app_role` nem írható | nincs (az `auth.users` törlése kaszkádol) |
| `households` | ha tag vagy | nincs | `parent`: csak `name` | nincs |
| `household_members` | a saját háztartásaid tagjai | nincs a kliensből (allowlist + trigger, vagy admin SQL) | nincs | nincs |
| `lists` | `is_member(household_id)` | `is_member(household_id)` és `created_by = auth.uid()` | `is_member` a régi és (with check) az új `household_id`-ra, így nem tolható át másik háztartásba | soft delete updatettel; valódi delete csak `parent` |
| `items` | `is_member(list_household(list_id))` | ugyanaz + `created_by = auth.uid()` | ugyanaz using és with check ágon (más listába nem mozgatható át, ha az nem a tiéd) | soft delete; valódi delete nincs a kliensből |
| `pupils` | `is_parent(household_id)` | `is_parent` | `is_parent`, csak `nickname`, `avatar` | `is_parent` (kaszkádolva törli az eredményeket) |
| `results` | `is_parent(pupil_household(pupil_id))` | ugyanaz + `recorded_by = auth.uid()` | nincs (az eredmény nem írható át) | `is_parent` (hibás bejegyzés törlése) |
| `private.*` | nem érhető el (a séma nincs közzétéve, `anon`/`authenticated` nem kap usage jogot) | | | |

További védelem:
- Realtime: az `items` és a `lists` kerül a `supabase_realtime` publikációba. A `postgres_changes` az RLS-t alkalmazza, így idegen lista változása nem jön meg.
- Nincs `security definer` RPC a `public` sémában. Ha később kell, `revoke execute ... from anon`.
- Supabase Security Advisor (dashboard) figyelmeztetései nullán legyenek minden migráció után.

### Tesztelés

**a) SQL tesztek (pgTAP, `supabase test db`)** – helyi Supabase-en (Docker) vagy a külön teszt-projekten, a migrációkkal együtt a repóban. Minden teszt két háztartást és három felhasználót hoz létre (A szülő, A tag, B szülő), majd `set local role authenticated; set local request.jwt.claims = '{"sub": "..."}'` mellett ellenőrzi:
- B semmit nem lát A listáiból, tételeiből, gyerekeiből, eredményeiből (0 sor);
- B update/delete A soraira 0 sort érint, insert A listájába RLS-hibát ad;
- A `member` nem lát `pupils`/`results` sort;
- senki nem írhatja a saját `app_role`-ját és a `household_members` táblát;
- `anon` szerepkörrel minden tábla 0 sort vagy jogosultsági hibát ad.

**b) Fekete dobozos teszt anon kulccsal** (`scripts/rls-check.mjs`, helyben futtatva, Node + `@supabase/supabase-js`, csak URL + anon kulcs):
1. Bejelentkezés nélkül: `select` minden táblára → üres tömb vagy 401/42501; `insert` → hiba; a `private` séma elérése → 404/406.
2. Két tesztfiókkal (a teszt-projekten jelszavas belépéssel, ami élesben ki van kapcsolva): B lekéri A listáját ismert `id` alapján → üres; módosítja → 0 sor; Realtime csatornát nyit A listájára, A közben ír → B nem kap eseményt.
3. Élesben csak az 1. pont fut (nincs tesztfiók az éles projektben).

A teszt-projekt a második ingyenes Supabase-projekt, vagy helyi `supabase start`. Javaslat: helyi a fejlesztéshez, és az anon-teszt 1. pontja minden éles migráció után.

## 3. Bejelentkezés, allowlist, közös munkamenet

### Folyamat

1. Az aloldalon „Belépés Google-lel” gomb → átirányít a központi belépőoldalra: `https://laszlobiri.com/belepes/?next=https://bevasarlas.laszlobiri.com/`.
2. A belépőoldal `signInWithOAuth({ provider: 'google', options: { redirectTo: 'https://laszlobiri.com/belepes/?next=…' } })` hívással a Supabase → Google oldalra visz (PKCE folyamat, csak `openid email profile` scope).
3. Visszatéréskor a belépőoldal kicseréli a `code`-ot munkamenetre, majd a `next` címre irányít. A `next` csak `https://laszlobiri.com` vagy `https://*.laszlobiri.com` lehet (nyitott átirányítás ellen).
4. Elutasított e-mail esetén a belépőoldal magyar hibaüzenetet ír („Ez a cím nincs engedélyezve.”).

Előny: a Supabase-ben és a Google-ben egyetlen visszahívási cím van, és az aloldalak nem foglalkoznak OAuth-tal.

### Allowlist

- **Supabase „Before User Created” auth hook** (Postgres függvény, `private.hook_before_user_created`): ha az új fiók e-mailje nincs a `private.allowed_emails` táblában, a hook hibát ad, és a fiók **létre sem jön**. Ez a fő kapu.
- A `profiles` trigger az allowlist sora alapján beállítja az `app_role`-t és létrehozza a `household_members` sort.
- Második réteg: minden adat a háztartás-tagságon múlik, így ha valaki mégis bejutna, akkor sem lát semmit.
- Opcionális harmadik réteg: a Google OAuth consent screen „Testing” módban marad, és csak a felvett tesztfelhasználók léphetnek be (100 főig). A Supabase csak a belépéskor használja a Google tokent, így a teszt mód 7 napos Google refresh token korlátja nem zavar.
- Ki van kapcsolva: e-mail/jelszavas regisztráció, magic link, anonim belépés. Csak a Google provider aktív.
- Új személy felvétele: egy sor az `allowed_emails` táblába a dashboard SQL szerkesztőjében (az admin felület később jöhet).

### Közös munkamenet az aloldalak között

A Supabase kliens alapból `localStorage`-ba menti a munkamenetet, ami domainenként külön van, ezért az aloldalak nem látnák egymásét. Javaslat:

- **Sütiben tároljuk, `Domain=.laszlobiri.com`, `Secure`, `SameSite=Lax`, `Path=/`** beállítással, a `@supabase/ssr` `createBrowserClient` függvényével (ez darabolja a sütit a 4 KB-os korlát miatt). Így egy belépés mind a négy címen érvényes, és a kijelentkezés is mindenhol kiléptet.
- Ismert korlátok, amiket elfogadunk:
  - A süti JavaScriptből olvasható (ugyanúgy, mint a `localStorage`). XSS ellen: a felhasználói szöveg mindig `textContent`-tel kerül a DOM-ba, `innerHTML` soha; szigorú `<meta http-equiv="Content-Security-Policy">` minden oldalon.
  - A süti minden kéréssel elmegy a GitHub Pages szervereinek is (TLS-en). A tokenek rövid életűek (access 1 óra), a refresh token forgó.
  - Safari (ITP) a JavaScriptből írt sütit legfeljebb 7 napig tartja meg. Mivel minden óránkénti frissítés újraírja, ez csak akkor jelent újbóli belépést, ha egy hétig nem nyitod meg egyik oldalt sem.
  - iOS-en a kezdőképernyőre tett PWA-nak külön tárolója van, ott egyszer külön be kell lépni. Az OAuth visszairányítás telepített PWA-ban iOS-en kényes: ezt a 0. fázisban ki kell próbálni.
  - Két aloldal egyszerre frissítheti a tokent (a `navigator.locks` csak egy originen belül véd). A Supabase refresh token reuse interval (alapból 10 s) ezt kezeli; nem állítjuk 0-ra.
- Ha ez nem elfogadható: tartalék megoldás a domainenkénti `localStorage` és aloldalanként egy kattintásos belépés (a Google emlékszik rád, tehát nem kér újra jelszót).

## 4. A közös kliens kód helye és bekötése

Ebben a repóban, a `design-system/` mellett, ugyanazzal a szerződéssel:

```
design-system/          (változatlan)
lib/
  v1/
    config.js           projekt URL + anon/publishable kulcs (publikus)
    supabase.js         előre buildelt, rögzített verziójú ESM csomag (@supabase/supabase-js + @supabase/ssr)
    client.js           egyetlen kliens példány, közös süti beállításokkal
    auth.js             getUser(), requireUser(), signIn(next), signOut(), onAuthChange(cb)
    auth-badge.js       kis web component: <lb-auth> (belépés gomb / név + kilépés), csak tokenes CSS
  build/                a supabase.js újragenerálásának leírása (esbuild, rögzített verziók)
belepes/index.html      központi belépőoldal
adatvedelem/index.html  adatkezelési tájékoztató (GDPR)
supabase/
  migrations/           SQL migrációk (séma, RLS, hook, trigger)
  tests/                pgTAP tesztek
  seed.sql              háztartás + allowlist minta (valódi e-mail nélkül)
scripts/rls-check.mjs   fekete dobozos anon-teszt
```

Szabályok (a `tokens.css` mintájára, bekerülnek a design system README-be):
- Közzétett cím: `https://laszlobiri.com/lib/v1/…`. **Az útvonal és az exportált függvénynevek publikus szerződés.** Törő változásnál `lib/v2/` jön létre, és az aloldalakat egyenként kell átállítani.
- Az aloldalak **nem tartanak helyi másolatot**, a CDN-t sem használják közvetlenül: a Supabase könyvtár rögzített verzióban, saját címről jön (nincs külső függőség futásidőben, nincs ellenőrizetlen frissülés).
- A GitHub Pages `Access-Control-Allow-Origin: *` fejlécet küld, ezért a modulok más aldomainről is betölthetők. Ezt az első bekötésnél ellenőrizzük.
- PWA-nál ugyanaz, mint a `tokens.css`-nél: a `lib/v1/*` nem kerül az előre mentett listába, hanem a hálózat-először kezelő menti el első betöltéskor.

Bekötés egy aloldalon:

```html
<link rel="preconnect" href="https://laszlobiri.com">
<link rel="stylesheet" href="https://laszlobiri.com/design-system/tokens.css">
<script type="module">
  import { requireUser, onAuthChange } from 'https://laszlobiri.com/lib/v1/auth.js';
  import { supabase } from 'https://laszlobiri.com/lib/v1/client.js';
  import 'https://laszlobiri.com/lib/v1/auth-badge.js';
</script>
<lb-auth></lb-auth>
```

Megjegyzés: ez a repó publikus, és a GitHub Pages a `docs/`, `lib/` és `supabase/` mappát is kiszolgálja. Titok egyikben sincs, a biztonság az RLS-en múlik, nem a kód rejtésén. Ha nem akarod, hogy a `docs/` és a `supabase/` webről is olvasható legyen, egy `_config.yml` `exclude` sorral kizárhatók.

## 5. Megvalósítási sorrend

### 0. fázis: előkészítés és kísérlet (kézi beállítás + 1 nap)
- Supabase-projekt és Google OAuth kliens (lásd lent).
- Kísérlet: belépés a `laszlobiri.com/belepes/` oldalon, a munkamenet látszik-e a `bevasarlas.` címen; asztali Chrome, Android Chrome, iOS Safari, **iOS telepített PWA**. Ha az iOS PWA belépés nem működik, előbb erre kell megoldás.

### 1. fázis: alap (ebben a repóban)
- Migrációk: `profiles`, `households`, `household_members`, `private.allowed_emails`, hook, trigger, segédfüggvények.
- `lib/v1/` csomag, `belepes/`, `adatvedelem/` oldal.
- pgTAP tesztek az alaptáblákra, `rls-check.mjs` 1. pont.

### 2. fázis: bevásárlólista
- Migráció: `lists`, `items`, Realtime publikáció, `pg_cron` takarítás.
- Kliens adatréteg:
  - IndexedDB: `lists`, `items`, `outbox`, `meta` (utolsó szinkron időbélyege listánként).
  - Minden módosítás azonnal az IndexedDB-be és az `outbox`-ba kerül; a UI mindig a helyi adatból rajzol.
  - Szinkron indul: oldal megnyitásakor, `online` eseménykor, `visibilitychange` (előtérbe kerülés) eseménykor, és ahol van, a Background Sync API-val (Chromium; iOS-en nincs, ott az előző három kell).
  - Sorrend: token frissítése → `outbox` kiküldése sorrendben (`upsert` kliens-UUID-dal, így az ismétlés biztonságos) → delta-lekérés (`updated_at > utolsó szinkron`, a törölteket is) → Realtime feliratkozás az aktív listára.
  - Ütközés: soronként az utolsó szerverre érkező írás nyer. Családi listánál ez elég; a „kipipálás” és a szöveg külön mezőként frissül, így ritkán írják felül egymást.
- Service worker: app shell előre mentve; `lib/v1/*` és `tokens.css` hálózat-először; a `*.supabase.co` kéréseket **nem** cache-eli és nem érinti.
- Belépés nélkül a lista helyben működik tovább (mint most). Első belépéskor egy „Feltöltöd a meglévő listát?” kérdés átviszi a helyi adatot a szerverre.
- Tesztek: pgTAP + `rls-check.mjs` 2. pont a teszt-projekten; kézzel: két telefon, egyik repülő módban, mindkettő ír, visszakapcsolás után egyezik-e.

### 3. fázis: gyakorló oldal
- Migráció: `pupils`, `results`, tesztek a `parent`/`member` különbségre.
- UI: belépett szülő → „Ki gyakorol?” választó (becenév + ikon) → feladatok → eredmény mentése. A választott gyerek eszközönként megjegyezve (`localStorage`, csak az `id`).
- Az eredmény mentése ugyanazzal a kimenő sor mintával történik (csak insert, kliens-UUID), így offline gyakorlás is elmegy később.
- Szülői nézet: gyerekenként az utolsó eredmények, feladatonkénti átlag.
- Belépés nélkül a gyakorlás működik, csak nem ment eredményt.

### 4. fázis: mentés, export, üzemeltetés
- **Export az appban**: „Adataim letöltése” JSON-ban (listák, tételek; szülőnek a gyerekprofilok és eredmények is). RLS alatt fut, tehát csak a saját adat jön le. A bevásárlólistához import is.
- **Teljes mentés**: havonta helyben `supabase db dump` (adat + séma) a saját gépeden, titkosított helyre. GitHub Actionsbe nem tesszük: a repó publikus, az artefaktumok és a jelszó kezelése ott kockázatos.
- Az ingyenes csomagban nincs letölthető napi mentés, és **egy hét tétlenség után a projekt szünetel**. A bevásárlólista napi használata ezt valószínűleg megelőzi; ha nem, Pro csomag (napi mentés, nincs szüneteltetés) vagy döntés később.
- GDPR: adatkezelési tájékoztató (`/adatvedelem/`), a Supabase DPA elfogadása a dashboardon, gyerekprofil törlése kaszkádolva törli az eredményeket, fiók törlése kérésre (admin SQL).

### 5. fázis (később): `ebed.`
Most nem kell belépés. Ha később kell (pl. kedvencek), ugyanaz a `lib/v1` bekötés és egy új tábla.

## Amit neked kell kézzel beállítanod

### Supabase
1. Új projekt, régió **Central EU (Frankfurt)**. Az adatbázis-jelszót a jelszókezelőbe.
2. Project Settings → API: a **projekt URL** és a **publishable/anon kulcs** kell nekem (ezek publikusak). A service role / secret kulcsot ne küldd el, ne másold sehova.
3. Authentication → Providers: Google bekapcsolása (Client ID + Client Secret a Google-ből). E-mail provider kikapcsolása, anonim belépés ki.
4. Authentication → URL Configuration: Site URL `https://laszlobiri.com`; Redirect URLs: `https://laszlobiri.com/belepes/**`, fejlesztéshez `http://localhost:8000/**`.
5. Authentication → Hooks: „Before User Created” → `private.hook_before_user_created` (a migráció után).
6. A migrációk futtatása (Supabase CLI-vel a gépedről, vagy az SQL szerkesztőben), utána a `seed`: háztartás létrehozása, a te és a feleséged e-mail címe az allowlistbe (`parent`, te `admin`). Valódi e-mail cím nem kerül a repóba.
7. Organization settings → DPA (adatfeldolgozói szerződés) elfogadása.
8. Opcionális: második projekt tesztelésre, vagy Docker a helyi `supabase start`-hoz.

### Google Cloud
1. Új projekt (pl. „laszlobiri”).
2. OAuth consent screen: External; alkalmazásnév „laszlobiri”; support e-mail; authorized domain: `laszlobiri.com` és `supabase.co`; főoldal `https://laszlobiri.com`, adatvédelem `https://laszlobiri.com/adatvedelem/`. Scope-ok: csak `openid`, `email`, `profile`. Logót ne tölts fel (az ellenőrzést indítana). Testing mód + tesztfelhasználók, vagy Production (alap scope-okhoz nem kell ellenőrzés).
3. Ha a Google domain-ellenőrzést kér: Search Console, **HTML-fájlos** módszer (a fájlt ebbe a repóba tesszük), nem DNS-rekord.
4. Credentials → OAuth client ID, típus „Web application”. Authorized redirect URI: `https://<projekt-ref>.supabase.co/auth/v1/callback`. Authorized JavaScript origins: `https://laszlobiri.com`.
5. A Client ID és Secret a Supabase Google providerébe kerül (a Secret csak oda).

## Nyitott kérdések

1. **Aloldal repók**: az `ebed.`, `bevasarlas.`, `gyakorlas.` külön repóban van? Ebben a munkamenetben csak a `laszlobiri-com` repóhoz férek hozzá; a 2–3. fázishoz azokat is hozzá kell adni.
2. **Közös süti**: elfogadod-e a `.laszlobiri.com` domainű, JavaScriptből írt munkamenet-sütit a fenti korlátokkal, vagy inkább aloldalanként egy kattintás a belépés?
3. **Szerepkörök**: rajtatok kívül kell-e `member` (pl. nagyszülő, aki csak a bevásárlólistát látja)? Ha nem, a modell akkor is maradhat, csak nem használjuk.
4. **Gyerekek eszköze**: a gyerekek a te/feleséged telefonján gyakorolnak, vagy saját (pl. tablet) eszközön? Ha sajátjukon, azon is szülői belépés kell, és azon a bevásárlólista is elérhető lenne; ekkor érdemes egy „gyerek módot” tervezni (csak a gyakorló oldal, PIN-nel kilépés).
5. **Meglévő adat**: a bevásárlólista most `localStorage`-ban tárol? Milyen formában (kell az importhoz)?
6. **Csomag**: ingyenes Supabase (szünetelés egy hét tétlenség után, nincs letölthető mentés) elég, vagy számolsz a Pro csomaggal?
7. **Publikus terv**: rendben van, hogy ez a dokumentum és a migrációk a `laszlobiri.com/docs/…` címen is olvashatók, vagy zárjuk ki a `_config.yml`-ben?
