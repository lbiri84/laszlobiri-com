# Backend: a laszlobiri oldalak közös háttere

Állapot (2026-11-19): **élesben.** A főoldal, az `ebed.`, a `bevasarlas.`, a `gyakorlas.` és a `tarsashaz.` csak belépve használható; a bevásárlólista a háztartás közös listája, a gyakorló gyerekprofilokkal, közös eredményekkel és gyerek móddal működik. Hátravan: mentés és export (lásd „Hátralévő munka”).

A kézi beállítások (Supabase, Google, migrációk, új felhasználó) a [`supabase/README.md`](../supabase/README.md)-ben vannak.

## Áttekintés

- **Frontend**: statikus oldalak GitHub Pages-en, öt repóban. Build nincs; a közös kód a `laszlobiri.com/lib/v1/` címről töltődik.
- **Backend**: egy közös Supabase-projekt (`eokwxkrcttsoxfflvuus`, EU, Frankfurt): Google OAuth, Postgres, Row Level Security (RLS), Realtime, `pg_cron`.
- **Védelem**: minden adatot az adatbázis RLS-e véd. Az oldalak kapuja böngészőben működik: a fájlok és a repók nyilvánosak, adat nélkül viszont üresek.

| repó | cím | közzététel | backend |
| --- | --- | --- | --- |
| `laszlobiri-com` | `laszlobiri.com` | Pages, ágból (Jekyll, `_config.yml` kizárja a `docs/`, `supabase/`, `scripts/` mappát) | design system, `lib/v1`, `/belepes/`, `/adatvedelem/`, migrációk, tesztek |
| `interfood-menu` | `ebed.laszlobiri.com` | Actions (`update-menu.yml`) | csak a kapu |
| `bevasarlo-lista` | `bevasarlas.laszlobiri.com` | Pages, ágból | közös lista, offline kimenő sor, Realtime |
| `gyakorlas` | `gyakorlas.laszlobiri.com` | Pages, ágból | gyerekprofilok, eredmények, gyerek mód, hibás feladat jelentése |
| `tarsashaz` | `tarsashaz.laszlobiri.com` | Pages, a `main` ágból | társasházi közös költség: időszakok, tételek, felosztás, utalások, vízóra, kimutatás |

### Fix feltételek

| feltétel | hogyan teljesül |
| --- | --- |
| DNS és Proton Mail rekordok nem változnak, nincs nameserver-váltás | Nincs Supabase custom domain; az auth a `<ref>.supabase.co` címen fut. A meglévő aldomain CNAME-ek maradtak. |
| `tokens.css` útvonala és a változónevek érintetlenek | A közös kód a `lib/v1/` mappában van; a gyakorló rózsaszín témája az oldal saját CSS-ében írja felül a tokeneket. |
| csak a publikus kulcs és a projekt URL kerül kliensbe | `lib/v1/config.js`; a service role / secret kulcs semmilyen repóban és kliensben nincs. |
| gyerekekről csak becenév és eredmény | `pupils`: becenév, ikon, színtéma; `results` / `pupil_badges` / `question_reports`: kódok, számok és a generált kérdés szövege, szabad szöveg nélkül. A gyereknek nincs fiókja. |
| a bevásárlólista offline is működik | Helyi másolat és kimenő sor a telefonon; visszatérő hálózatnál szinkron. |

## Belépés

1. Minden védett oldal a központi `https://laszlobiri.com/belepes/?next=…` oldalra küld. A `next` csak a négy laszlobiri cím lehet (nyitott átirányítás ellen).
2. Google-belépés PKCE-vel, csak `openid email profile` scope.
3. **Allowlist két rétegben**: a „Before User Created” hook (`private.hook_before_user_created`) elutasítja az ismeretlen címet (403, „Ez a cím nincs engedélyezve.”); a `auth.users` triggere (`private.handle_new_user`) akkor is elutasít, ha a hook nincs bekötve. A trigger hozza létre a profilt és a háztartás-tagságot. Névtelen fiókot (gyerek tablet) mindkettő átenged, profil nélkül.
4. **Közös munkamenet**: süti `Domain=.laszlobiri.com; Secure; SameSite=Lax` (`@supabase/ssr`), így egy belépés mind a négy címen érvényes, és a kilépés is mindenhol kiléptet.
5. Ki van kapcsolva: e-mail/jelszó, magic link. Be van kapcsolva: Google és a névtelen belépés (a gyerek módhoz, alacsony rate limittel).

### Belépési kapu

- Minden oldal `<head>`-jének elején: rejtett oldal (`lb-gate` stílus), egy beágyazott sor, ami munkamenet-süti híján **rajzolás előtt** a belépőoldalra irányít, és a `lib/v1/gate.js`, ami a helyi munkamenetet ellenőrzi, majd megjeleníti az oldalt.
- Offline is megnyit: ha a böngésző offline, vagy a munkamenet 3 másodpercen belül nem áll elő (lejárt token, nincs hálózat), de van munkamenet-süti. Kiléptetni csak a szerver egyértelmű elutasítása léptet ki, hálózati hiba soha.
- A gyakorló kapuja a párosított gyerek tabletet (`localStorage['lb-device']`) és a párosító oldalt (`#parositas`) is átengedi.
- Kivétel: `/belepes/` és `/adatvedelem/` nyilvános.

### Oldalankénti hozzáférés és admin felület

- Minden engedélyezett címhez tartozik, mely aloldalakat nyithatja meg (`allowed_emails.apps`: `ebed`, `bevasarlas`, `gyakorlas`, `tarsashaz`). A család címei a bevezetéskor az első hármat kapták.
- A kapu (`gate.js`) aloldalon a `my_access()` alapján dönt; a választ az oldal localStorage-a (`lb-access`) megjegyzi, így offline és gyorsan is működik, online mindig frissül. Ha nincs hozzáférés: „Ehhez az oldalhoz nincs hozzáférésed.”, a `ready` nem teljesül. Hálózati hibánál a legutóbbi ismert döntés számít, ha nincs ilyen, megnyílik. A főoldal csak a megnyitható alkalmazásokat mutatja.
- Az oldal-pipa az adatot is védi (2026-11-17 óta): a bevásárlólista adataihoz (`lists`, `items`, `item_history`, `bump_history`) a `bevasarlas`, a gyakorló szülői adataihoz (minden, ami a `private.is_parent()`-en megy át: gyerekprofilok, eredmények, jelvények, tabletek, párosítás, jelentések, fejezetek) a `gyakorlas` is kell a háztartás-tagság mellett (`private.has_app()`, `private.can_list()`). A háztartás-tagság magától állítódik: aki a két családi oldal egyikét megkapja, tag; akinek mindkettő lekerül, kikerül. Külön „Család” pipa nincs. A gyerek tablet nem változik. Lakótárs (csak Elszámolás) a családi adatokból semmit nem lát, akkor sem, ha a kaput megkerüli; ezt a `008` és `009` teszt bizonyítja.
- `/admin/` (csak `app_role = 'admin'`): a címek listája (van-e fiók, utolsó belépés), felvétel, oldalak, megjegyzés (legfeljebb 80 karakter), visszavonás. Az admin függvények maguk is ellenőrzik a jogot; az admin magát nem vonhatja vissza, és nála a Lista vagy a Gyakorló megmarad. Visszavonáskor a cím és a háztartás-tagság megszűnik, a fiók megmarad, de semmihez nem fér hozzá (törlés: dashboard).
- Új aloldal: kód a `private.app_codes()`-ba és az `allowed_emails.apps` feltételébe (migráció), a `lib/v1/access.js` `SITES` listájába, és az origin a `auth.js` `SITE_ORIGINS`-ába.

### Ismert korlátok

- Safari (ITP) a JavaScriptből írt sütit legfeljebb 7 napig tartja meg; minden frissítés újraírja, tehát csak egy hét teljes kihagyás után kell újra belépni.
- iOS-en a kezdőképernyőre tett appnak külön tárolója van: ott egyszer külön kell belépni, illetve a gyerek tabletet a telepített appban kell párosítani. Ha a tableten Safariban is volt szülői belépés, ott ki kell lépni.
- Két aloldal egyszerre frissítheti a tokent; ezt a refresh token reuse interval kezeli.

## Adatmodell és jogok

| tábla | tartalom | ki olvassa | ki írja |
| --- | --- | --- | --- |
| `private.allowed_emails` | engedélyezett címek, háztartás, szerep, megnyitható aloldalak (`apps`), megjegyzés | senki közvetlenül; a saját `apps` a `my_access()`-szel, a teljes lista az adminnak az `admin_access_list()`-tel | admin: a `/admin/` oldal (`admin_access_set` / `admin_access_remove`); az admin szerep csak SQL |
| `profiles` | név, `app_role` | saját + a háztartás tagjai | saját név (`display_name`); a többit a trigger |
| `households`, `household_members` | háztartás, tagság (`parent`) | tagok | név: szülő; tagság: trigger / az admin oldal (a Lista vagy a Gyakorló pipával jár) |
| `lists` | háztartásonként egy lista (trigger hozza létre) | tagok Lista pipával | név: ugyanők |
| `items` | tétel (`name_key` egyedi az élő tételek között, soft delete) | tagok Lista pipával | ugyanők; `created_by`, `updated_*`, `list_id` a szerveré; valódi törlés nincs |
| `item_history` | „gyakran vett” javaslatok | tagok Lista pipával | csak `bump_history()` |
| `pupils` | becenév, ikon, `theme` (`slate` / `rose` / `sky`) | szülő; a tablet a hozzá rendelteket | szülő; a tablet csak a hozzá rendelt gyerek `theme`-jét (`pupils_guard`) |
| `results` | befejezett kör / minijáték-győzelem (`round`, `hangman`, `wordsearch`, `breakout`; csak hozzáfűzés) | szülő; a tablet a hozzá rendelteket | szülő / tablet; `recorded_by` a szerveré; törölni csak a szülő |
| `pupil_badges` | jelvények | mint `results` | mint `results` |
| `devices`, `device_pupils` | párosított gyerek tabletek | szülő; a tablet a sajátját | `claim_pairing()`; törlés (visszavonás): szülő |
| `private.device_pairings`, `private.pairing_attempts` | párosító kódok (hash), hibás próbálkozások | senki | `create_pairing()` / `claim_pairing()` |
| `question_reports` | hibás feladat jelentése (a kérdés pillanatképe, okkód) | csak a szülő | beküldés: szülő / a hozzá rendelt tablet; `status`: szülő |
| `chapter_access` | tantárgyanként az elérhető tankönyvi fejezetek kódjai (háztartásonként közös; ha nincs sor, minden elérhető) | szülő; a háztartás tabletje | csak a szülő |

- „Szülő” ebben a táblában: háztartás-tag Gyakorló pipával (`private.is_parent()`).
- Az `anon` szerep egyik táblán sem kap jogot. A segédfüggvények (`private.is_member`, `is_parent`, `list_household`, `pupil_household`, `is_device_for`) `security definer`-ek.
- Párosítás: a kód 8 karakter, 10 percig él, egyszer használható; fiókonként 10 hibás próbálkozás után zár. A `claim_pairing` hibás kódnál nem kivételt dob, hanem `'invalid'`-ot ad, különben a számláló is visszagörgetődne.
- Napi takarítás (`pg_cron`): 30 napnál régebben törölt tételek; párosítatlan vagy visszavont névtelen fiókok 24 óra után; lejárt párosító kódok.
- Realtime: `lists`, `items` (a `postgres_changes` az RLS-t alkalmazza).

## Közös kód (`laszlobiri-com/lib/v1/`)

| fájl | szerep |
| --- | --- |
| `config.js` | projekt URL + publishable kulcs |
| `supabase.js` | generált csomag: `@supabase/supabase-js` 2.118.0 + `@supabase/ssr` 0.12.7 (`npm run build:lib`) |
| `client.js` | a közös kliens, `.laszlobiri.com` sütivel |
| `auth.js` | `getUser`, `getProfile`, `signIn`, `signOut`, `onAuthChange`, `safeNext`; a belépőoldalnak `startGoogleLogin`, `completeLogin` |
| `gate.js` | belépési kapu (`ready` → `{ user, offline }`) |
| `auth-badge.js` | `<lb-auth>`: név + Kilépés |
| `outbox.js` | kimenő sor (localStorage), sorrendben küld, hálózati hibánál megtartja, fülek között zárolva |
| `device.js` | gyerek mód: névtelen eszközfiók saját tárolóval (`lb-device-auth`), párosítás, PIN (PBKDF2), kilépés |

Az útvonal és az exportált nevek publikus szerződés; törő változás csak `lib/v2/` alatt. Bekötés: [`design-system/README.md`](../design-system/README.md).

## Az oldalak működése

### Bevásárlólista

- Háztartásonként egy közös lista. Minden módosítás azonnal helyben megjelenik és a kimenő sorba kerül; szinkron megnyitáskor, előtérbe kerüléskor, visszatérő hálózatnál, minden módosítás után, és ha a másik telefon változtat (Realtime). Szinkronkor a teljes élő lista jön le, rá a még el nem küldött műveletek.
- Ha két telefon offline ugyanazt veszi fel, a második a meglévőhöz csatlakozik („már rajta volt”), és az ő mennyisége érvényesül.
- Törlés: soft delete, így szinkronizálódik és visszavonható. A gyakran vett javaslatok közösek.
- A linkes küldés megszűnt; a szöveges megosztás megmaradt.

### Gyakorló

- Szülő: „Ki gyakorol?” → gyerek; szülői nézet: gyerekprofilok, eredmények (utolsó 5 kör), gyerek tabletek (párosítás, visszavonás, „Ez az eszköz legyen a gyerek tablet”), jelentett feladatok.
- A pont, a szint, a napi sorozat, a témánkénti legjobb és a jelvények az eredményekből számolódnak. Csak a befejezett kör és a megnyert minijáték mentődik.
- Gyerek mód: a tablet csak a hozzá rendelt gyerekeket látja; kilépés „Szülő” → PIN.
- Minijáték: 500 pontonként jutalom; a gyerek választ akasztófa, szókereső és falbontó (2 × 6 tégla, 3 élet, a téma színeivel) közül. Egy jutalom egy játék; győzelem +10 pont.
- Színtéma: a gyerek maga választja a kezdőképernyőn („Színem”): palakék, rózsaszín (sötét) vagy égkék (világos). A választott téma a gyerek saját nézeteiben él, a „Ki gyakorol?” és a szülői nézet palakék.
- Hibás feladat: a kérdésnél „⚑” → okkód; a szülői nézetben „Javítva” / „Elvetés” és „Szövegként másolás” a javításhoz (a gyerek neve nélkül).

### Társasház

- Négy lakás (fsz-1, fsz-2, em-3, em-4), nevek nélkül: a társasház oldalt megnyitó címhez egy lakás tartozik (`allowed_emails.flat`, az admin oldalon állítható).
- Táblák: `th_flats` (tulajdoni hányad), `th_residents` (létszám, dátumtól), `th_periods`, `th_items` és `th_item_shares` (a tétel lakásonkénti része, mentéskor rögzítve), `th_readings` (vízóra), `th_transfers`.
- Olvasni a társasház oldal jogával lehet (`private.th_can_read()`); írni csak az **admin**, ha a társasház oldalt is megnyithatja (`private.th_is_manager()`), a `th_*` függvényeken át; a táblákra közvetlen írási jog nincs. Az utalást az utaló vagy a fogadó lakás lakója is jelölheti (`th_mark_transfer`).
- A felosztást és a legkevesebb utalást a kliens számolja; a szerver ellenőrzi, hogy a lakásrészek összege a tétel összege, csak beszálló lakásnak van része, és lezáráskor az utalások kiadják az egyenlegeket (egyedi utalásnál lakásonként legfeljebb 10 Ft kerekítési eltéréssel).
- A működés leírása a felhasználóknak az oldalon: „Hogyan számol?” (a fejléc „?” gombja).

## Döntések

| kérdés | döntés |
| --- | --- |
| munkamenet az aloldalak között | közös süti (`.laszlobiri.com`) |
| használat belépés nélkül | nincs; böngészős kapu minden oldalon, a `/belepes/` és az `/adatvedelem/` kivételével. Szerveroldali védelem (más tárhely) elvetve. |
| felhasználók | két szülő, egy `parent` szerep; további szerep egy migrációval vehető fel |
| társasház szerkesztése | csak az admin; külön kezelői jog nincs (2026-11-19) |
| több oldal, más felhasználók (pl. lakótársak) | közös belépés, oldalankénti hozzáférés (`apps`), az oldal-pipa az adatot is védi (szülő = háztartás-tag Gyakorló pipával); külön Család pipa nincs; kezelés a `/admin/` oldalon (2026-11-17) |
| gyerekprofilok | kettő; a becenevek csak az adatbázisban, a repókban nem |
| gyerekek saját eszköze | gyerek mód: névtelen, párosított eszközfiók, PIN-nel lehet kilépni |
| listák | egy közös lista háztartásonként; közös gyorsjavaslatok |
| félbehagyott kör | nem számít |
| minijáték | 500 pontonként, választható (akasztófa, szókereső, falbontó), egy jutalom egy játék |
| régi helyi adatok (lista, pontok) | az új verzió első indításkor törli (`bevasarlo-lista.v1`, `gyakorlo.v1`), nem kerülnek fel |
| színtéma | gyerekenként, a gyerek választja; a jel színei nem változnak |
| hibás feladat | „⚑” jelentés okkóddal, szabad szöveg nélkül; a javítás a szülőn keresztül, a másolt szöveg alapján |
| tananyag bővítése | tankönyvfotók alapján, ebben a munkamenet-formában (nem külön feltöltő oldal); saját feladatok, a tankönyv szövege nem kerül a nyilvános repóba |
| egyszerűsítések a tervhez képest | IndexedDB helyett localStorage; delta-lekérés helyett teljes élő lista; allowlist `lower()`-rel, nem `citext`-tel |
| csomag | ingyenes Supabase + helyi, titkosított mentés (még nincs kész) |

## Munkamód

- Commit **szerzője**: Laszlo Biri `<lbiri84@users.noreply.github.com>`; **committere**: Claude `<noreply@anthropic.com>`. A környezet a commitokat a Claude kulcsával SSH-val aláírja, és a GitHub ezt csak `noreply@anthropic.com` committerrel fogadja el („Verified”). Valódi e-mail cím nem kerül commitba. (2026-11-14 előtti commitoknál a committer is a noreply cím volt, ezért azok aláíratlannak látszanak; nem írjuk át őket.)
- Munkaág: `claude/funny-turing-bphs2l` minden repóban. Élesítés: helyi merge commit a `main`-re, ugyanezzel a szerző–committer párossal (nem a GitHub-on készült merge, mert az a fiók elsődleges címét írhatja be).
- Sorrend: a `laszlobiri-com` élesítése (a `supabase-migrate` munkafolyamat a `main`-re került új migrációt magától lefuttatja; az Actions naplójában ellenőrizni), `npm run check:rls`, végül az aloldal. Kézi SQL nem kell. A munkafolyamat titkai: `SUPABASE_ACCESS_TOKEN` (szűkített token: csak ez a projekt, olvasási jog) és `SUPABASE_DB_PASSWORD`; lásd `supabase/README.md`.
- Minden változás előtt: `npm run test:db`, `npm run test:smoke`; élesítés után `npm run check:rls`.

## Tesztek (`laszlobiri-com`)

| parancs | mit ellenőriz |
| --- | --- |
| `npm run test:db` | pgTAP: allowlist és profil (001), közös lista (002), gyakorló és gyerek mód (003), színtéma (004), jelentések (005), falbontó-eredmény (006), elérhető fejezetek (007), oldalankénti hozzáférés és admin (008), az oldal-pipa az adatot is védi (009), társasház (010), a korlátok átfogóan: minden `th_*` és `admin_*` függvény, táblajogok, anon (011). Helyi Postgresen, Supabase-stubbal. |
| `npm run test:smoke` | böngészős próbák ál-Supabase-zel: belépés, kapu, oldalankénti hozzáférés és admin oldal (`login-smoke`), kéttelefonos listaszinkron (`list-sync-smoke`), gyakorló szülővel és tablettel (`practice-smoke`), társasház kezelővel és lakóval (`tarsashaz-smoke`; `MOBILE=1`: telefon-emuláció). A bevasarlo-lista és a gyakorlas repó a laszlobiri-com mellett legyen. |
| `npm run check:rls` | az éles projekt a nyilvános kulccsal: bejelentkezés nélkül semmi nem olvasható és írható. Proxy mögött `NODE_USE_ENV_PROXY=1`. |

## Hátralévő munka

1. **Mentés** (4. fázis): `scripts/backup.sh` a saját gépen: `supabase db dump` (séma; a `public` és `private` adat; az `auth.users` és `auth.identities`), `age` jelszavas titkosítás, `~/laszlobiri-backup/`, a legutóbbi 12 megtartása, ellenőrzés a végén; a Session pooler címe a `SUPABASE_DB_URL`-ből, jelszó soha fájlba. Havonta és minden migráció előtt; másolat egy második helyre.
2. **Visszaállítás próba**: `scripts/restore-local.sh` egy helyi `supabase start` példányba, negyedévente.
3. **Export az oldalakon**: „Adataim letöltése” JSON-ban (lista, előzmények; szülőnek a gyerekek eredményei).
4. **Szüneteltetés figyelése**: az ingyenes projekt egy hét tétlenség után szünetel. Ha előfordul, egy heti kérés a publikus kulccsal életben tarthatja (előbb ellenőrizni, hogy aktivitásnak számít-e).
5. **Dashboardon ellenőrizendő** (kívülről nem látszik): Database → Publications → `supabase_realtime` tartalmazza a `lists` és `items` táblát; Database → Cron Jobs alatt ott a `laszlobiri-items-purge` és a `laszlobiri-devices-cleanup`. Ha valamelyik hiányzik, a `pg_cron` nem volt bekapcsolva a migrációkor: bekapcsolás után a megfelelő migráció végét újra kell futtatni.
6. **Kézi próbák**, amik még nincsenek meg: bevásárlólista két telefonon (szinkron, offline, azonos tétel, gyorsjavaslatok); gyakorló (két profil, tablet párosítása telepített appban, offline kör a tableten, színválasztás a tableten).
7. **Opcionális**: PIN a szülői nézethez szülői belépés mellett is (ha a gyerek a szülő telefonján játszik); a gyakorló feladatai külön adatfájlokba az első nagyobb tananyag-bővítésnél.
