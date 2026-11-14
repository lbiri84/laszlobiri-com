-- Hibás feladat jelentése: ki küldhet be, ki láthatja, és mi rögzül.

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
\ir 000_helpers.sql

select plan(14);

insert into public.households (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000000', 'A háztartás'),
  ('bbbbbbbb-0000-0000-0000-000000000000', 'B háztartás');
insert into private.allowed_emails (email, household_id) values
  ('a1@example.invalid', 'aaaaaaaa-0000-0000-0000-000000000000'),
  ('b@example.invalid',  'bbbbbbbb-0000-0000-0000-000000000000');
insert into auth.users (id, email) values
  ('a1a1a1a1-0000-0000-0000-000000000000', 'a1@example.invalid'),
  ('b0b0b0b0-0000-0000-0000-000000000000', 'b@example.invalid');
insert into auth.users (id, is_anonymous) values ('d1d1d1d1-0000-0000-0000-000000000000', true);
insert into public.pupils (id, household_id, nickname) values
  ('11111111-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000000', 'Mókus'),
  ('11111111-0000-0000-0000-00000000000b', 'aaaaaaaa-0000-0000-0000-000000000000', 'Süni');
insert into public.devices (user_id, household_id, label) values ('d1d1d1d1-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000000', 'Tablet');
insert into public.device_pupils values ('d1d1d1d1-0000-0000-0000-000000000000', '11111111-0000-0000-0000-00000000000a');

select is(pg_temp.err_as('d1d1d1d1-0000-0000-0000-000000000000',
  $$insert into public.question_reports (id, pupil_id, topic, prompt, body, choices, correct, picked, reason)
    values ('33333333-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'mondat', 'Milyen mondat?', 'Esik az eső!', array['kijelentő','felkiáltó'], 0, 1, 'bad_question')$$),
  'ok', 'a tablet jelentést küld a hozzá rendelt gyerekről');
select is((select household_id from public.question_reports where id = '33333333-0000-0000-0000-000000000001'),
  'aaaaaaaa-0000-0000-0000-000000000000'::uuid, 'a háztartás a gyerekprofilból jön');
select is((select recorded_by from public.question_reports where id = '33333333-0000-0000-0000-000000000001'),
  'd1d1d1d1-0000-0000-0000-000000000000'::uuid, 'a beküldő a szerverről jön');
select is(pg_temp.err_as('d1d1d1d1-0000-0000-0000-000000000000',
  $$insert into public.question_reports (pupil_id, topic, reason) values ('11111111-0000-0000-0000-00000000000b', 'abc', 'other')$$),
  '42501', 'a tablet más gyerek nevében nem jelenthet');
select is(pg_temp.count_as('d1d1d1d1-0000-0000-0000-000000000000', 'select * from public.question_reports'), 0, 'a tablet nem látja a jelentéseket');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.question_reports (pupil_id, topic, reason, status) values ('11111111-0000-0000-0000-00000000000b', 'abc', 'wrong_answer', 'fixed')$$),
  '42501', 'beküldéskor az állapot nem adható meg');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.question_reports (pupil_id, topic, reason) values ('11111111-0000-0000-0000-00000000000b', 'abc', 'csak úgy')$$),
  '23514', 'ismeretlen okkód nem írható');
select is(pg_temp.err_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$insert into public.question_reports (pupil_id, topic, reason) values (null, 'abc', 'other')$$),
  '42501', 'gyerek nélkül nem küldhető be');
select is(pg_temp.err_as('b0b0b0b0-0000-0000-0000-000000000000',
  $$insert into public.question_reports (pupil_id, topic, reason) values ('11111111-0000-0000-0000-00000000000a', 'abc', 'other')$$),
  '42501', 'B nem jelenthet A gyerekéről');
select is(pg_temp.count_as('a1a1a1a1-0000-0000-0000-000000000000', 'select * from public.question_reports'), 1, 'a szülő látja a jelentést');
select is(pg_temp.count_as('b0b0b0b0-0000-0000-0000-000000000000', 'select * from public.question_reports'), 0, 'B nem látja A jelentéseit');
select is(pg_temp.n_as('a1a1a1a1-0000-0000-0000-000000000000',
  $$update public.question_reports set status = 'fixed' where id = '33333333-0000-0000-0000-000000000001'$$), 1, 'a szülő „Javítva” állapotra teszi');
select isnt((select resolved_at from public.question_reports where id = '33333333-0000-0000-0000-000000000001'), null, '…és rögzül a lezárás ideje');
select is(pg_temp.n_as('d1d1d1d1-0000-0000-0000-000000000000',
  $$update public.question_reports set status = 'new'$$), 0, 'a tablet nem módosíthat állapotot');

select * from finish();
rollback;
