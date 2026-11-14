-- Gyerekprofil színtémája: a szülő és a hozzá rendelt tablet állíthatja; a tablet csak a színt írhatja.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(12);

insert into public.households (id, name) values ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás');
insert into private.allowed_emails (email, household_id) values ('a1@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000');
insert into auth.users (id, email) values ('a1a1a1a1-0000-0000-0000-000000000000', 'a1@example.invalid');
insert into auth.users (id, is_anonymous) values ('d1d1d1d1-0000-0000-0000-000000000000', true);
insert into public.pupils (id, household_id, nickname) values ('11111111-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000000', 'Mókus');
insert into public.devices (user_id, household_id, label) values ('d1d1d1d1-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000000', 'Tablet');
insert into public.device_pupils values ('d1d1d1d1-0000-0000-0000-000000000000', '11111111-0000-0000-0000-00000000000a');

select is((select theme from public.pupils where id = '11111111-0000-0000-0000-00000000000a'), 'slate', 'alapértelmezés: palakék');
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.pupils set theme = 'rose' where id = '11111111-0000-0000-0000-00000000000a'$$), 1, 'a szülő rózsaszínre állítja');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.pupils set theme = 'neon' where id = '11111111-0000-0000-0000-00000000000a'$$), '23514', 'ismeretlen téma nem írható');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.pupils (household_id, nickname, theme) values ('aaaaaaaa-0000-0000-0000-000000000000', 'Süni', 'rose')$$), 'ok', 'létrehozáskor is megadható');
select is(pg_temp.q_as('d1d1d1d1-0000-0000-0000-000000000000', 'select theme from public.pupils'), '[{"theme": "rose"}]'::jsonb, 'a tablet látja a hozzá rendelt gyerek témáját');
select is(pg_temp.n_as('d1d1d1d1-0000-0000-0000-000000000000',
  $$update public.pupils set theme = 'slate' where id = '11111111-0000-0000-0000-00000000000a'$$), 1, 'a tablet a hozzá rendelt gyerek színét átállíthatja');
select is((select theme from public.pupils where id = '11111111-0000-0000-0000-00000000000a'), 'slate', '…és a szín tényleg megváltozott');
select is(pg_temp.n_as('d1d1d1d1-0000-0000-0000-000000000000',
  $$update public.pupils set nickname = 'Feltört', avatar = 'bee', theme = 'rose' where id = '11111111-0000-0000-0000-00000000000a'$$), 1, 'a tablet egyszerre próbál becenevet, ikont és színt írni…');
select is((select nickname || '/' || avatar || '/' || theme from public.pupils where id = '11111111-0000-0000-0000-00000000000a'), 'Mókus/fox/rose', '…de csak a szín változik');
select is(pg_temp.n_as('d1d1d1d1-0000-0000-0000-000000000000',
  $$update public.pupils set theme = 'rose' where nickname = 'Süni'$$), 0, 'a tablet más gyerek színét nem írhatja');
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.pupils set nickname = 'Mókuska' where id = '11111111-0000-0000-0000-00000000000a'$$), 1, 'a szülő továbbra is átnevezheti');
select is((select nickname from public.pupils where id = '11111111-0000-0000-0000-00000000000a'), 'Mókuska', '…és az átnevezés megmarad');

select * from finish();
rollback;
