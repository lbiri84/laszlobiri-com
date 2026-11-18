-- 2. fázis: közös bevásárlólista (lists, items, item_history, bump_history).
-- Szereplők (kitalált adatok): A1, A2 az A háztartásban, B a B-ben, C háztartás nélkül.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(41);

-- ---------------------------------------------------------------- előkészítés
insert into public.households (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'B háztartás');
insert into private.allowed_emails (email, household_id) values
  ('a1@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000'),
  ('a2@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000'),
  ('b@example.invalid',  'bbbbbbbb-0000-0000-0000-000000000000'),
  ('c@example.invalid',  null);
-- A családtagok a két családi oldalt is megkapják (lásd 008: az oldal-pipa az adatot is védi).
update private.allowed_emails set apps = '{ebed,bevasarlas,gyakorlas}' where household_id is not null;
insert into auth.users (id, email) values
  ('a1a1a1a1-0000-0000-0000-000000000000', 'a1@example.invalid'),
  ('a2a2a2a2-0000-0000-0000-000000000000', 'a2@example.invalid'),
  ('b0b0b0b0-0000-0000-0000-000000000000', 'b@example.invalid'),
  ('c0c0c0c0-0000-0000-0000-000000000000', 'c@example.invalid');

-- A listák azonosítója (a trigger hozza létre őket).
create temp table l as
  select (select id from public.lists where household_id = 'aaaaaaaa-0000-0000-0000-000000000000') as a,
         (select id from public.lists where household_id = 'bbbbbbbb-0000-0000-0000-000000000000') as b;
grant select on l to authenticated, anon;

-- ---------------------------------------------------------------- lists
select isnt((select a from l), null, 'új háztartáshoz automatikusan létrejön a lista');
select is((select count(*)::int from public.lists where household_id = 'aaaaaaaa-0000-0000-0000-000000000000'), 1, 'háztartásonként egy lista');
select throws_ok($$insert into public.lists (household_id) values ('aaaaaaaa-0000-0000-0000-000000000000')$$,
  '23505', null, 'második lista ugyanannak a háztartásnak nem hozható létre (postgresként sem)');
select is(pg_temp.count_as('a1a1a1a1-0000-0000-0000-000000000000', 'select * from public.lists'), 1, 'A1 egy listát lát, a sajátját');
select is(pg_temp.count_as('c0c0c0c0-0000-0000-0000-000000000000', 'select * from public.lists'), 0, 'háztartás nélkül nincs lista');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.lists (household_id) values ('aaaaaaaa-0000-0000-0000-000000000000')$$), '42501', 'kliensből nem hozható létre lista');
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.lists set name = 'Bevásárlás' where id = (select a from l)$$), 1, 'A1 átnevezheti a saját listáját');
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.lists set name = 'Feltört' where id = (select b from l)$$), 0, 'A1 nem nevezheti át B listáját');

-- ---------------------------------------------------------------- items: írás és olvasás
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.items (id, list_id, name, name_key, qty, cat) values ('11111111-0000-0000-0000-000000000001', (select a from l), 'Tej', 'tej', '2 l', 'tej')$$),
  'ok', 'A1 tételt vesz fel a saját listájára');
select is((select created_by from public.items where id = '11111111-0000-0000-0000-000000000001'),
  'a1a1a1a1-0000-0000-0000-000000000000'::uuid, 'a created_by a szerverről jön (A1)');
select is(pg_temp.count_as('a2a2a2a2-0000-0000-0000-000000000000', 'select * from public.items'), 1, 'A2 látja A1 tételét (megosztás)');
select is(pg_temp.count_as('b0b0b0b0-0000-0000-0000-000000000000', 'select * from public.items'), 0, 'B nem látja A tételeit');
select is(pg_temp.count_as('b0b0b0b0-0000-0000-0000-000000000000',
  $$select * from public.items where id = '11111111-0000-0000-0000-000000000001'$$), 0, 'B ismert id-val sem látja');
select is(pg_temp.err_as('b0b0b0b0-0000-0000-0000-000000000000',
  $$insert into public.items (list_id, name, name_key) values ((select a from l), 'Idegen', 'idegen')$$), '42501', 'B nem írhat A listájára');
select is(pg_temp.n_as('b0b0b0b0-0000-0000-0000-000000000000',
  $$update public.items set done = true where id = '11111111-0000-0000-0000-000000000001'$$), 0, 'B nem módosíthatja A tételét');
select is(pg_temp.err_as('c0c0c0c0-0000-0000-0000-000000000000',
  $$insert into public.items (list_id, name, name_key) values ((select a from l), 'Idegen', 'idegen')$$), '42501', 'háztartás nélküli felhasználó nem írhat');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$delete from public.items where id = '11111111-0000-0000-0000-000000000001'$$), '42501', 'valódi törlés kliensből nincs');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.items set created_by = 'b0b0b0b0-0000-0000-0000-000000000000' where id = '11111111-0000-0000-0000-000000000001'$$),
  '42501', 'a created_by kliensből nem írható');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.items set list_id = (select b from l) where id = '11111111-0000-0000-0000-000000000001'$$),
  '42501', 'a list_id kliensből nem írható (nem tolható át B listájára)');

-- Módosítás: A2 kipipálja, a szerver rögzíti, ki és mikor.
select is(pg_temp.n_as('a2a2a2a2-0000-0000-0000-000000000000',
  $$update public.items set done = true where id = '11111111-0000-0000-0000-000000000001'$$), 1, 'A2 kipipálhatja A1 tételét');
select is((select updated_by from public.items where id = '11111111-0000-0000-0000-000000000001'),
  'a2a2a2a2-0000-0000-0000-000000000000'::uuid, 'az updated_by a szerverről jön (A2)');

-- ---------------------------------------------------------------- name_key: egyediség, törlés, visszavonás
select is(pg_temp.err_as('a2a2a2a2-0000-0000-0000-000000000000',
  $$insert into public.items (id, list_id, name, name_key) values ('11111111-0000-0000-0000-000000000002', (select a from l), 'TEJ', 'tej')$$),
  '23505', 'ugyanaz a név kétszer nem lehet a listán (offline duplikátum)');
select is(pg_temp.err_as('a2a2a2a2-0000-0000-0000-000000000000',
  $$insert into public.items (id, list_id, name, name_key) values ('11111111-0000-0000-0000-000000000003', (select b from l), 'Tej', 'tej')$$),
  '42501', 'a duplikátum-ellenőrzés nem szivárogtat: B listájára így sem írhat');
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.items set deleted_at = now() where id = '11111111-0000-0000-0000-000000000001'$$), 1, 'soft delete');
select is((select name_key from public.items where id = '11111111-0000-0000-0000-000000000001'), null, 'törléskor a name_key null lesz');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.items (id, list_id, name, name_key) values ('11111111-0000-0000-0000-000000000004', (select a from l), 'Tej', 'tej')$$),
  'ok', 'törlés után ugyanaz a név újra felvehető');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.items set deleted_at = null, name_key = 'tej' where id = '11111111-0000-0000-0000-000000000001'$$),
  '23505', 'visszavonás ütközik, ha közben újra felvették (a kliens elhagyja a visszavonást)');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.items set deleted_at = null where id = '11111111-0000-0000-0000-000000000001'$$),
  '23514', 'élő tételnek kell name_key');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.items (list_id, name, name_key, cat) values ((select a from l), 'Valami', 'valami', 'rossz')$$),
  '23514', 'ismeretlen kategória nem írható');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.items (list_id, name, name_key) values ((select a from l), 'Valami', 'VALAMI')$$),
  '23514', 'a name_key csak kisbetűs lehet');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  format($$insert into public.items (list_id, name, name_key) values ((select a from l), %L, 'hosszu')$$, repeat('x', 81))),
  '23514', '80 karakternél hosszabb név nem írható');

-- ---------------------------------------------------------------- item_history és bump_history
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$select public.bump_history('aaaaaaaa-0000-0000-0000-000000000000', 'tej', 'Tej', 'tej')$$), 'ok', 'A1 növeli az előzményt');
select is(pg_temp.err_as('a2a2a2a2-0000-0000-0000-000000000000',
  $$select public.bump_history('aaaaaaaa-0000-0000-0000-000000000000', 'tej', 'Tej', 'tej')$$), 'ok', 'A2 is növeli ugyanazt');
select is((select count from public.item_history where household_id = 'aaaaaaaa-0000-0000-0000-000000000000' and name_key = 'tej'),
  2, 'két növelés = 2 (közös előzmény)');
select is(pg_temp.err_as('b0b0b0b0-0000-0000-0000-000000000000',
  $$select public.bump_history('aaaaaaaa-0000-0000-0000-000000000000', 'tej', 'Tej', 'tej')$$), '42501', 'B nem növelheti A előzményét');
select is(pg_temp.count_as('b0b0b0b0-0000-0000-0000-000000000000', 'select * from public.item_history'), 0, 'B nem látja A előzményét');
select is(pg_temp.count_as('a2a2a2a2-0000-0000-0000-000000000000', 'select * from public.item_history'), 1, 'A2 látja a közös előzményt');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.item_history (household_id, name_key, name, cat) values ('aaaaaaaa-0000-0000-0000-000000000000', 'x', 'X', 'egyeb')$$),
  '42501', 'az előzmény csak a bump_history-n át írható');

-- ---------------------------------------------------------------- anon
select is(pg_temp.err_as(null, 'select * from public.items'), '42501', 'anon: items nem olvasható');
select is(pg_temp.err_as(null, 'select * from public.lists'), '42501', 'anon: lists nem olvasható');
select is(pg_temp.err_as(null, $$select public.bump_history('aaaaaaaa-0000-0000-0000-000000000000', 'x', 'X', 'egyeb')$$),
  '42501', 'anon: bump_history nem hívható');

select * from finish();
rollback;
