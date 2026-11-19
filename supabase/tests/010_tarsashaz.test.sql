-- Társasházi elszámoló: olvasás a társasház oldal jogával, írás csak a kezelőnek, a
-- lakók a saját utalásukat jelölhetik; az összegek ellenőrzése.
--
-- Szereplők (kitalált adatok):
--   K:   kezelő (admin), em-4
--   L1:  lakó, fsz-1
--   L2:  lakó, fsz-2
--   CS:  családtag, a társasház oldal nélkül
--   T:   gyerek tablet

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(49);

insert into public.households (id, name) values ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás');
insert into private.allowed_emails (email, household_id, app_role, apps, flat) values
  ('k@example.invalid',  'aaaaaaaa-0000-0000-0000-000000000000', 'admin', '{bevasarlas,gyakorlas,tarsashaz}', 'em-4'),
  ('l1@example.invalid', null, 'user', '{tarsashaz}', 'fsz-1'),
  ('l2@example.invalid', null, 'user', '{tarsashaz}', 'fsz-2'),
  ('cs@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000', 'user', '{bevasarlas,gyakorlas}', null);
insert into auth.users (id, email) values
  ('0c0c0c0c-0000-0000-0000-000000000000', 'k@example.invalid'),
  ('11111111-0000-0000-0000-000000000000', 'l1@example.invalid'),
  ('22222222-0000-0000-0000-000000000000', 'l2@example.invalid'),
  ('c5c5c5c5-0000-0000-0000-000000000000', 'cs@example.invalid');
insert into auth.users (id, is_anonymous) values ('7a7a7a7a-0000-0000-0000-000000000000', true);

\set K  '''0c0c0c0c-0000-0000-0000-000000000000'''
\set L1 '''11111111-0000-0000-0000-000000000000'''
\set L2 '''22222222-0000-0000-0000-000000000000'''
\set CS '''c5c5c5c5-0000-0000-0000-000000000000'''
\set T  '''7a7a7a7a-0000-0000-0000-000000000000'''

-- ---------------------------------------------------------------- th_me
select is(pg_temp.q_as(:K, 'select public.th_me() as a') -> 0 -> 'a', '{"flat": "em-4", "manager": true}'::jsonb, 'th_me: kezelő, em-4');
select is(pg_temp.q_as(:L1, 'select public.th_me() as a') -> 0 -> 'a', '{"flat": "fsz-1", "manager": false}'::jsonb, 'th_me: lakó, fsz-1');
select is(pg_temp.q_as(:CS, 'select public.th_me() as a') -> 0 -> 'a', '{"flat": null, "manager": false}'::jsonb, 'th_me: családtag társasház nélkül: semmi');

-- ---------------------------------------------------------------- beállítások
select is(pg_temp.err_as(:L1, $$select public.th_save_flats('{"fsz-1":1911,"fsz-2":1911,"em-3":3089,"em-4":3089}')$$), '42501', 'hányad: lakó nem állíthatja');
select is(pg_temp.err_as(:K, $$select public.th_save_flats('{"fsz-1":1911,"fsz-2":1911,"em-3":3089,"em-4":3000}')$$), '22023', 'hányad: az összeg 10 000 legyen');
select is(pg_temp.err_as(:K, $$select public.th_save_flats('{"fsz-1":1911,"fsz-2":1911,"em-3":3089,"em-4":3089}')$$), 'ok', 'hányad: kezelő beállítja');
select is(pg_temp.err_as(:K, $$select public.th_save_residents('2025-07-01', '{"fsz-1":1,"fsz-2":4,"em-3":4,"em-4":4}')$$), 'ok', 'létszám: kezelő beállítja');

-- ---------------------------------------------------------------- olvasás
select is(pg_temp.count_as(:L2, 'select * from public.th_flats'), 4, 'olvasás: lakó látja a lakásokat');
select is(pg_temp.count_as(:CS, 'select * from public.th_flats'), 0, 'olvasás: társasház nélkül semmit');
select is(pg_temp.count_as(:T,  'select * from public.th_residents'), 0, 'olvasás: tablet semmit');
select is(pg_temp.err_as(null, 'select * from public.th_flats'), '42501', 'olvasás: anon nem fér hozzá');
select is(pg_temp.err_as(:K, $$insert into public.th_periods (name, starts_on) values ('x', current_date)$$), '42501', 'írás: közvetlenül a kezelő sem írhat táblát');

-- ---------------------------------------------------------------- időszak és tételek
select is(pg_temp.err_as(:L1, $$select public.th_open_period('2026. szeptember–október', '2026-09-01')$$), '42501', 'időszak: lakó nem nyithat');
select is(pg_temp.err_as(:K, $$select public.th_open_period('2026. szeptember–október', '2026-09-01')$$), 'ok', 'időszak: kezelő nyit');
select is(pg_temp.err_as(:K, $$select public.th_open_period('Még egy', '2026-11-01')$$), '22023', 'időszak: egyszerre egy nyitott');

create temp table ids as select id as pid from public.th_periods;
grant select on ids to authenticated;

select is(pg_temp.err_as(:L1, $$select public.th_rename_period((select pid from ids), 'Átnevezve', '2026-09-01', null, null)$$), '42501', 'átnevezés: lakó nem nevezheti át');
select is(pg_temp.err_as(:K, $$select public.th_rename_period((select pid from ids), ' 2026. szeptember–október ', '2026-09-01', null, 'két hónap')$$)
  || ':' || (select name from public.th_periods limit 1), 'ok:2026. szeptember–október', 'átnevezés: kezelő javítja az elírt nevet');

select is(pg_temp.err_as(:K, $$select public.th_save_item(jsonb_build_object('period_id', (select pid from ids), 'name', 'Közös villany', 'category', 'villany',
  'amount', 8940, 'paid_by', 'fsz-1', 'method', 'hanyad', 'participants', '["fsz-1","fsz-2","em-3","em-4"]'::jsonb,
  'shares', '{"fsz-1":1708,"fsz-2":1708,"em-3":2762,"em-4":2761}'::jsonb))$$), '22023', 'tétel: a részek összege nem egyezik → elutasítva');
select is(pg_temp.err_as(:K, $$select public.th_save_item(jsonb_build_object('period_id', (select pid from ids), 'name', 'Közös villany', 'category', 'villany',
  'amount', 8940, 'paid_by', 'fsz-1', 'method', 'hanyad', 'participants', '["fsz-1","fsz-2","em-3"]'::jsonb,
  'shares', '{"fsz-1":1708,"fsz-2":1708,"em-3":2762,"em-4":2762}'::jsonb))$$), '22023', 'tétel: nem beszálló lakásnak nem lehet része');
select is(pg_temp.err_as(:L1, $$select public.th_save_item(jsonb_build_object('period_id', (select pid from ids), 'name', 'x', 'category', 'egyeb',
  'amount', 4, 'paid_by', 'fsz-1', 'method', 'egyenlo', 'participants', '["fsz-1","fsz-2","em-3","em-4"]'::jsonb,
  'shares', '{"fsz-1":1,"fsz-2":1,"em-3":1,"em-4":1}'::jsonb))$$), '42501', 'tétel: lakó nem vehet fel');
select is(pg_temp.err_as(:K, $$select public.th_save_item(jsonb_build_object('period_id', (select pid from ids), 'name', 'Közös villany', 'category', 'villany',
  'amount', 8940, 'paid_by', 'fsz-1', 'method', 'hanyad', 'participants', '["fsz-1","fsz-2","em-3","em-4"]'::jsonb,
  'shares', '{"fsz-1":1708,"fsz-2":1708,"em-3":2762,"em-4":2762}'::jsonb))$$), 'ok', 'tétel: kezelő felvesz egy villany tételt');
select is(pg_temp.err_as(:K, $$select public.th_save_item(jsonb_build_object('period_id', (select pid from ids), 'name', 'Zöldhulladék-zsák', 'category', 'egyeb',
  'amount', 2760, 'paid_by', 'em-4', 'method', 'egyenlo', 'participants', '["fsz-1","fsz-2","em-3","em-4"]'::jsonb,
  'shares', '{"fsz-1":690,"fsz-2":690,"em-3":690,"em-4":690}'::jsonb))$$), 'ok', 'tétel: kezelő felvesz egy zsák tételt');
select is(pg_temp.count_as(:L2, 'select * from public.th_item_shares'), 8, 'tétel: a lakó látja a részeket');

-- ---------------------------------------------------------------- lezárás és utalások
-- egyenlegek: fsz-1 +8940-1708-690 = 6542; fsz-2 −2398; em-3 −3452; em-4 2760-2762-690 = −692
select is(pg_temp.err_as(:K, $$select public.th_close_period((select pid from ids),
  '[{"from":"fsz-2","to":"fsz-1","amount":2398},{"from":"em-3","to":"fsz-1","amount":3452}]')$$), '22023', 'lezárás: hiányzó utalás → elutasítva');
-- egyedi utalások: 2 Ft eltérés (fsz-1 +2, em-4 +2) tűrés nélkül elutasítva
select is(pg_temp.err_as(:K, $$select public.th_close_period((select pid from ids),
  '[{"from":"fsz-2","to":"fsz-1","amount":2398},{"from":"em-3","to":"fsz-1","amount":3452},{"from":"em-4","to":"fsz-1","amount":694}]')$$), '22023', 'egyedi utalás: eltérés tűrés nélkül → elutasítva');
-- 11 Ft eltérés 20 Ft-os kérésre is elutasítva (a tűrés legfeljebb 10 Ft)
select is(pg_temp.err_as(:K, $$select public.th_close_period((select pid from ids),
  '[{"from":"fsz-2","to":"fsz-1","amount":2398},{"from":"em-3","to":"fsz-1","amount":3452},{"from":"em-4","to":"fsz-1","amount":703}]', 20)$$), '22023', 'egyedi utalás: 10 Ft fölötti eltérés → elutasítva');
select is(pg_temp.err_as(:K, $$select public.th_close_period((select pid from ids),
  '[{"from":"fsz-1","to":"fsz-1","amount":5}]', 10)$$), '22023', 'egyedi utalás: önmagának nem utalhat');
select is(pg_temp.err_as(:K, $$select public.th_close_period((select pid from ids),
  '[{"from":"fsz-2","to":"fsz-1","amount":2398},{"from":"em-3","to":"fsz-1","amount":3452},{"from":"em-4","to":"fsz-1","amount":692}]')$$), 'ok', 'lezárás: az utalások kiadják az egyenlegeket');
select is((select status from public.th_periods), 'closed', 'lezárás: az időszak lezárva');
select is(pg_temp.err_as(:K, $$select public.th_save_item(jsonb_build_object('period_id', (select pid from ids), 'name', 'Késő', 'category', 'egyeb',
  'amount', 4, 'paid_by', 'fsz-1', 'method', 'egyenlo', 'participants', '["fsz-1","fsz-2","em-3","em-4"]'::jsonb,
  'shares', '{"fsz-1":1,"fsz-2":1,"em-3":1,"em-4":1}'::jsonb))$$), '22023', 'lezárt időszakba nem vehető fel tétel');

select is(pg_temp.err_as(:L2, $$select public.th_mark_transfer((select id from public.th_transfers where from_flat = 'fsz-2'), true)$$), 'ok', 'utalás: a fizető lakás jelöli');
select is(pg_temp.err_as(:L2, $$select public.th_mark_transfer((select id from public.th_transfers where from_flat = 'em-3'), true)$$), '42501', 'utalás: más lakás utalását nem jelölheti');
select is(pg_temp.err_as(:L1, $$select public.th_mark_transfer((select id from public.th_transfers where from_flat = 'em-3'), true)$$), 'ok', 'utalás: a fogadó lakás is jelölheti');
select is((select count(*)::int from public.th_transfers where paid_at is not null), 2, 'utalás: kettő megérkezett');

select is(pg_temp.err_as(:K, $$select public.th_reopen_period((select pid from ids))$$), '22023', 'újranyitás: beérkezett utalásnál csak megerősítéssel');
select is(pg_temp.err_as(:K, $$select public.th_reopen_period((select pid from ids), true)$$), 'ok', 'újranyitás: megerősítéssel');
select is((select count(*)::int from public.th_transfers), 0, 'újranyitás: az utalások törlődnek');

-- ---------------------------------------------------------------- törlés
select is(pg_temp.err_as(:L1, $$select public.th_delete_period((select pid from ids))$$), '42501', 'időszak törlése: lakó nem törölhet');
select is(pg_temp.err_as(:K, $$select public.th_delete_period((select pid from ids))$$), 'ok', 'időszak törlése: kezelő törli');
select is((select count(*)::int from public.th_periods) + (select count(*)::int from public.th_items) + (select count(*)::int from public.th_item_shares), 0,
  'időszak törlése: a tételek és a részek is törlődnek');
-- létszám-bejegyzés törlése (a 2025-07-01-i beállítás a teszt elején készült)
select is(pg_temp.err_as(:K, $$select public.th_save_residents('2026-11-18', '{"fsz-1":1,"fsz-2":4,"em-3":4,"em-4":4}')$$), 'ok', 'létszám: egy újabb bejegyzés');
select is(pg_temp.err_as(:L1, $$select public.th_delete_residents('2026-11-18')$$), '42501', 'létszám törlése: lakó nem törölhet');
select is(pg_temp.err_as(:K, $$select public.th_delete_residents('2026-11-18')$$), 'ok', 'létszám törlése: kezelő törli');
select is((select string_agg(distinct valid_from::text, ',') from public.th_residents), '2025-07-01', 'létszám törlése: csak az a nap törlődött');
select is((select count(*)::int from pg_proc where proname in ('th_import', 'th_reset')), 0, 'a betöltés és a kiürítés nincs többé');

-- lezárás egyedi utalásokkal, kerekítési tűréssel, azonnal kiegyenlítve
select is(pg_temp.err_as(:K, $$select public.th_open_period('Régi időszak', '2026-03-01')$$), 'ok', 'egyedi lezárás: új időszak');
delete from ids; insert into ids select id from public.th_periods where status = 'open';
select is(pg_temp.err_as(:K, $$select public.th_save_item(jsonb_build_object('period_id', (select pid from ids), 'name', 'Biztosítás', 'category', 'egyeb',
  'amount', 1001, 'paid_by', 'fsz-1', 'method', 'egyenlo', 'participants', '["fsz-2","em-3"]'::jsonb, 'shares', '{"fsz-2":501,"em-3":500}'::jsonb))$$), 'ok', 'egyedi lezárás: egy tétel');
select is(pg_temp.err_as(:K, $$select public.th_close_period((select pid from ids),
  '[{"from":"fsz-2","to":"fsz-1","amount":500},{"from":"em-3","to":"fsz-1","amount":502}]', 10, true)$$), 'ok', 'egyedi lezárás: 1–2 Ft kerekítési eltéréssel elfogadva');
select is((select count(*)::int from public.th_transfers where paid_at is not null), 2, 'egyedi lezárás: az utalások azonnal kiegyenlítve');

select * from finish();
rollback;
