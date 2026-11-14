# laszlobiri

Laszlo személyes oldala és kis alkalmazásai (laszlobiri.com). A márka egy pontmátrix: az **L** és a **B** betű egyetlen, elforgatott rácsban, alatta a kisbetűs „laszlobiri” felirattal. Sötét palakék alapon fehéres, narancs és fekete.

## Tartalmi alapelvek

- A név mindig **laszlobiri**, kisbetűvel, egy szóban. Mondat elején sem írjuk nagybetűvel.
- Hangnem: személyes, rövid, tárgyilagos. Egy mondat, ami elmondja, mit csinál az oldal. Felkiáltójel, szlogen és marketingnyelv nélkül.
- Magyar a felület alapnyelve. A kód, a tokenek és a fájlnevek angolul vannak.
- Példák: „Heti ebéd” és „Bevásárlólista”, nem „Fedezd fel a heti ebédválasztót!”.

## Vizuális alapok

- **Alap**: palakék (`bg`), rajta fehéres szöveg (`fg`). Világos téma is van: fehéres alap, sötét szöveg.
- **Egyetlen kiemelő szín**: narancs. A B betűn, a „biri” feliraton, linkeken és főgombokon. Oldalanként egy-két helyen, nem tapétának.
- **Fekete** csak mélységnek: a jel kitöltő pöttyei és sötét blokkok.
- **Forma**: kerek pöttyök (r = 4 a 14-es rácson) és lekerekített téglalapok (`radius-md`, `radius-lg`). Nincs színátmenet, nincs árnyék, nincs keret-csík a kártyák szélén.
- **Betűtípus**: Space Grotesk (Google Fonts), 400–700. A felirat 600-as, szoros betűközzel (-0,03em).
- **Sűrűség**: nagyvonalú. Oldalmargó `space-16`, szekciók között `space-12`.

## A jel

A jel egy 6 × 4 pontos mátrix, 14 egység rácstávval, `viewBox="0 0 81 53"`. A rácsot 90°-kal, majd 180°-kal elforgatjuk, így a betűk fektetve látszanak.

| elem | pontok | szín |
| --- | --- | --- |
| L betű | 9 tömör pötty | `mark-l` |
| B betű | 8 tömör pötty | `mark-b` |
| kitöltők | 4 tömör pötty a B belsejében és jobb felső sarkában | `mark-filler` |
| L gyűrűje | 1 üres gyűrű (r = 3, vonal 2) az L végén | `mark-l` |
| B gyűrűi | 2 üres gyűrű a B két végén | `mark-ring` (narancs) |

Tömör pötty sugara 4, a gyűrűé 3 (a vonal 2 vastag, így a külső mérete is 4). A pöttyök nincsenek összekötve.

### A jel, palakék alapon

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 81 53" width="162" height="106"><g transform="rotate(180 40.5 26.5)"><g transform="translate(81 0) rotate(90)"><circle fill="#000000" cx="47.5" cy="5.5" r="4"/><circle fill="#000000" cx="33.5" cy="19.5" r="4"/><circle fill="#000000" cx="47.5" cy="33.5" r="4"/><circle fill="#000000" cx="33.5" cy="47.5" r="4"/><circle fill="#eaecf0" cx="5.5" cy="5.5" r="4"/><circle fill="#eaecf0" cx="5.5" cy="19.5" r="4"/><circle fill="#eaecf0" cx="5.5" cy="33.5" r="4"/><circle fill="#eaecf0" cx="5.5" cy="47.5" r="4"/><circle fill="#eaecf0" cx="5.5" cy="61.5" r="4"/><circle fill="#eaecf0" cx="5.5" cy="75.5" r="4"/><circle fill="#eaecf0" cx="19.5" cy="75.5" r="4"/><circle fill="#eaecf0" cx="33.5" cy="75.5" r="4"/><circle fill="#eaecf0" cx="47.5" cy="75.5" r="4"/><circle fill="#ee8643" cx="19.5" cy="5.5" r="4"/><circle fill="#ee8643" cx="19.5" cy="19.5" r="4"/><circle fill="#ee8643" cx="19.5" cy="33.5" r="4"/><circle fill="#ee8643" cx="19.5" cy="47.5" r="4"/><circle fill="#ee8643" cx="19.5" cy="61.5" r="4"/><circle fill="#ee8643" cx="33.5" cy="5.5" r="4"/><circle fill="#ee8643" cx="33.5" cy="33.5" r="4"/><circle fill="#ee8643" cx="47.5" cy="19.5" r="4"/><circle stroke="#eaecf0" cx="47.5" cy="61.5" r="3" fill="none" stroke-width="2"/><circle stroke="#ee8643" cx="33.5" cy="61.5" r="3" fill="none" stroke-width="2"/><circle stroke="#ee8643" cx="47.5" cy="47.5" r="3" fill="none" stroke-width="2"/></g></g></svg>
```

Világos alapon használd a világos téma tokenjeit (`mark-l` fekete, `mark-filler` palakék; a B gyűrűi itt is narancsok). A `Logo` komponens mindhárom felületet megmutatja.

### Lockup és szabályok

- **Lockup**: a jel fölül, középen; alatta a „laszlobiri” felirat. A „laszlo” `fg`, a „biri” narancs (`accent`).
- A felirat szélessége nagyjából a jel szélességének 1,6-szerese. Köztük a jel magasságának negyede.
- **Védőtér**: minden oldalon legalább egy rácstáv (14 egység, a jel szélességének 17%-a).
- **Legkisebb méret**: a jel 48 px széles, a lockup 96 px széles. Ennél kisebben csak a felirat nélküli jel jó, 24 px-ig.
- Ne forgasd el más szögre, ne nyújtsd, ne kösd össze a pöttyöket, ne cserélj színt a B és az L között.

## Szín

| token | érték | mire |
| --- | --- | --- |
| `brand-slate` | `#293c4b` | alap |
| `brand-orange` | `#ee8643` | kiemelés |
| `brand-mist` | `#eaecf0` | szöveg és L betű sötét alapon |
| `brand-black` | `#000000` | kitöltő pöttyök, sötét blokkok |

Kontraszt: a fehéres a palakéken 9,6:1. A narancs a palakéken csak 4,4:1, ezért kis szövegnek és linknek az `accent-text` kell (5,0:1), a `accent` 24 px fölötti szövegnek és grafikának jó. A narancs a fehéres alapon csak 2,2:1: ott a narancs csak a jelben és blokkokban szerepelhet, szövegnek az `accent-text` (4,7:1).

## Betűtípus

Space Grotesk, a Google Fontsból (`https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&display=swap`). Címek 600–700, szöveg 400. Tartalék: `system-ui, sans-serif`.

## Használat

Tokeneket a `tokens.css` adja (CSS változók, `--bg`, `--fg`, `--accent`…). A témát a `data-theme="slate"` vagy `data-theme="light"` választja. Új oldalnál az `bg` háttérre és az `fg` szövegre épülj, és a narancshoz az `accent-text`-et használd, ha szöveg.

### Új oldal vagy app bekötése (központi tokenek)

A `tokens.css` egyetlen példánya itt van, és közzé van téve: **`https://laszlobiri.com/design-system/tokens.css`**. Az aloldalak (Interfood, Bevásárlólista és minden új) ezt töltik be, **nem tartanak helyi másolatot**:

```html
<link rel="preconnect" href="https://laszlobiri.com">
<link rel="stylesheet" href="https://laszlobiri.com/design-system/tokens.css">
```

Szabályok:

- **Ne másold** a `tokens.css`-t az aloldal repójába, és ne vedd fel a közzétételi (Actions) másoló lépésbe. Token módosítása csak itt, a `tokens.json`-ban történik, utána a `tokens.css` újragenerálása, és az aloldalak maguktól megkapják.
- **Az útvonal publikus szerződés**: a `design-system/tokens.css` nem nevezhető át és nem mozdítható el, és a változónevek (`--bg`, `--fg`, `--accent`…) nem törölhetők vagy nevezhetők át, mert az aloldalak ezektől függenek. Törő változtatásnál előbb új, verziózott útvonal (pl. `design-system/v2/tokens.css`) jöjjön létre, és az aloldalakat egyenként át kell állítani.
- **Ami helyben marad az aloldalon**: az `icon.svg` és az alkalmazás ikonjai (a manifest és az `apple-touch-icon` miatt), a téma kiválasztása (`data-theme`) és az oldal saját CSS-e.
- **PWA-nál** (service worker): a `tokens.css` ne kerüljön az előre mentett (`ASSETS`) listába, mert az install lépés CORS nélkül elbukhat. A hálózat-először kezelő az első betöltéskor lementi, így offline is elérhető.
- **Függés**: ha a `laszlobiri.com` nem érhető el, az aloldal stílus nélkül jelenik meg. A főoldal elérhetősége ezért mindhárom oldalra hat.
- **Ellenőrzés új oldalnál**: megnyitás után a böngésző hálózati paneljén a `tokens.css` kérésnek 200-assal kell visszajönnie.

## Fájlok ebben a repóban

- `tokens.json`: a tokenek forrása. `tokens.css`: ebből generált CSS-változók (`data-theme="slate"` vagy `"light"`); az aloldalak ezt a fájlt töltik be a `laszlobiri.com` címről (lásd fent).
- `assets/logo/mark-on-slate.svg` és `mark-on-light.svg`: a jel, palakék és világos alapra.
- `components/Logo`, `components/Cover`: az élő előnézetek (a Claude design system oldalán nyílnak meg, a `tokens.css`-t várják).
