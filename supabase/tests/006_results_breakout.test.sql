-- Minijáték-eredmények: a falbontó ('breakout') is menthető, ismeretlen fajta nem.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(3);

insert into public.households (id, name) values ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás');
insert into private.allowed_emails (email, household_id) values ('a1@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000');
insert into auth.users (id, email) values ('a1a1a1a1-0000-0000-0000-000000000000', 'a1@example.invalid');
insert into public.pupils (id, household_id, nickname) values ('11111111-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000000', 'Mókus');

select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.results (pupil_id, kind, points) values ('11111111-0000-0000-0000-00000000000a', 'breakout', 10)$$), 'ok', 'falbontó-győzelem menthető');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.results (pupil_id, kind, points) values ('11111111-0000-0000-0000-00000000000a', 'hangman', 10)$$), 'ok', 'az akasztófa továbbra is menthető');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.results (pupil_id, kind, points) values ('11111111-0000-0000-0000-00000000000a', 'tetris', 10)$$), '23514', 'ismeretlen minijáték nem menthető');

select * from finish();
rollback;
