-- Gyerekprofil színtémája: a szülő állíthatja, ismeretlen téma nem írható, az eszköz nem módosíthatja.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(6);

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
  $$update public.pupils set theme = 'slate'$$), 0, 'a tablet nem módosíthatja');

select * from finish();
rollback;
