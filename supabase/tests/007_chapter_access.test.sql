-- Elérhető fejezetek: a szülő tantárgyanként beállítja; a háztartás gyerek tabletje
-- olvassa, de nem írja; más háztartás nem látja.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(12);

insert into public.households (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'B háztartás');
insert into private.allowed_emails (email, household_id) values
  ('a1@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000'),
  ('b@example.invalid',  'bbbbbbbb-0000-0000-0000-000000000000');
-- A családtagok a két családi oldalt is megkapják (lásd 008: az oldal-pipa az adatot is védi).
update private.allowed_emails set apps = '{ebed,bevasarlas,gyakorlas}' where household_id is not null;
insert into auth.users (id, email) values
  ('a1a1a1a1-0000-0000-0000-000000000000', 'a1@example.invalid'),
  ('b0b0b0b0-0000-0000-0000-000000000000', 'b@example.invalid');
insert into auth.users (id, is_anonymous) values ('d1d1d1d1-0000-0000-0000-000000000000', true);
insert into public.devices (user_id, household_id, label) values ('d1d1d1d1-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000000', 'Tablet');

\set A1 '''a1a1a1a1-0000-0000-0000-000000000000'''
\set B  '''b0b0b0b0-0000-0000-0000-000000000000'''
\set D1 '''d1d1d1d1-0000-0000-0000-000000000000'''

select is(pg_temp.err_as(:A1, $$insert into public.chapter_access (household_id, subject, chapters) values ('aaaaaaaa-0000-0000-0000-000000000000', 'matek', '{m1-1,m1-2}')$$),
  'ok', 'A1 beállítja a matek elérhető fejezeteit');
select is(pg_temp.err_as(:A1, $$insert into public.chapter_access (household_id, subject, chapters) values ('aaaaaaaa-0000-0000-0000-000000000000', 'matek', '{m1-1}')
  on conflict (household_id, subject) do update set chapters = excluded.chapters, updated_at = now()$$),
  'ok', 'A1 módosítja (upsert)');
select is(pg_temp.q_as(:A1, 'select chapters from public.chapter_access')->0->'chapters', '["m1-1"]'::jsonb, 'A1 látja a módosított listát');
select is(pg_temp.q_as(:D1, 'select subject, chapters from public.chapter_access'), '[{"subject":"matek","chapters":["m1-1"]}]'::jsonb, 'a háztartás tabletje olvassa');
select is(pg_temp.n_as(:D1, $$update public.chapter_access set chapters = '{m1-1,m1-2,m1-3}'$$), 0, 'a tablet nem írhatja át');
select is(pg_temp.err_as(:D1, $$insert into public.chapter_access (household_id, subject, chapters) values ('aaaaaaaa-0000-0000-0000-000000000000', 'nyelvtan', '{}')$$),
  '42501', 'a tablet nem hozhat létre beállítást');
select is(pg_temp.count_as(:B, 'select * from public.chapter_access'), 0, 'B nem látja A beállítását');
select is(pg_temp.err_as(:B, $$insert into public.chapter_access (household_id, subject, chapters) values ('aaaaaaaa-0000-0000-0000-000000000000', 'nyelvtan', '{}')$$),
  '42501', 'B nem írhat A háztartásába');
select is(pg_temp.err_as(:A1, $$insert into public.chapter_access (household_id, subject, chapters) values ('aaaaaaaa-0000-0000-0000-000000000000', 'rajz', '{}')$$),
  '23514', 'ismeretlen tantárgy nem lehet');
select is(pg_temp.err_as(:A1, $$insert into public.chapter_access (household_id, subject, chapters) values ('aaaaaaaa-0000-0000-0000-000000000000', 'nyelvtan', '{"rossz kód"}')$$),
  '23514', 'a fejezetkód csak kisbetű, szám és kötőjel lehet');
select is(pg_temp.err_as(null, 'select * from public.chapter_access'), '42501', 'anon nem olvassa');
select is(pg_temp.n_as(:A1, $$delete from public.chapter_access where subject = 'matek'$$), 1, 'A1 törölheti (újra minden elérhető)');

select * from finish();
rollback;
