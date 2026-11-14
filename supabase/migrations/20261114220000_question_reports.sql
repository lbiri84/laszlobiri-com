-- Hibás feladat jelentése a gyakorló oldalon („⚑ Jelentem”).
-- A gyerek (szülői fiókkal vagy a saját tabletjén) jelenti az épp látott kérdést; a
-- szülő a szülői nézetben látja, és „Javítva” / „Elvetés” állapotra teszi.
--
-- Adatvédelem: szabad szöveg nincs; a jelentés a generált kérdés pillanatképe
-- (téma, kérdés, válaszlehetőségek, helyes és megjelölt válasz, magyarázat) és egy
-- okkód. A gyerekhez csak a pupil_id köti.

create table public.question_reports (
  id           uuid primary key default gen_random_uuid(),       -- a kliens generálja (offline, ismétlés)
  household_id uuid not null references public.households (id) on delete cascade,  -- a trigger tölti
  pupil_id     uuid references public.pupils (id) on delete set null,
  topic        text not null check (topic ~ '^[a-z0-9]{1,32}$'),
  qkey         text check (char_length(qkey) <= 100),
  prompt       text not null default '' check (char_length(prompt) <= 300),
  body         text not null default '' check (char_length(body) <= 500),
  choices      text[] not null default '{}' check (cardinality(choices) <= 6 and char_length(array_to_string(choices, '')) <= 720),
  correct      smallint check (correct between 0 and 5),
  picked       smallint check (picked between 0 and 5),
  explain      text not null default '' check (char_length(explain) <= 600),
  reason       text not null check (reason in ('wrong_answer', 'bad_question', 'other')),
  app_version  text check (char_length(app_version) <= 20),
  status       text not null default 'new' check (status in ('new', 'fixed', 'dismissed')),
  created_at   timestamptz not null default now(),
  recorded_by  uuid references auth.users (id) on delete set null,
  resolved_at  timestamptz
);
create index question_reports_household_idx on public.question_reports (household_id, status, created_at desc);

-- A háztartás a gyerekprofilból jön (a kliens nem adhatja meg), a beküldő a szerverről.
create function private.question_reports_stamp() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.household_id := (select p.household_id from public.pupils p where p.id = new.pupil_id);
    new.recorded_by := (select auth.uid());
    new.status := 'new';
    new.resolved_at := null;
    new.created_at := now();
  else
    new.resolved_at := case when new.status = 'new' then null else coalesce(new.resolved_at, now()) end;
  end if;
  return new;
end $$;
revoke all on function private.question_reports_stamp() from public, anon, authenticated;
create trigger question_reports_stamp before insert or update on public.question_reports
  for each row execute function private.question_reports_stamp();

revoke all on public.question_reports from public, anon, authenticated;
grant insert (id, pupil_id, topic, qkey, prompt, body, choices, correct, picked, explain, reason, app_version)
  on public.question_reports to authenticated;
grant select, delete on public.question_reports to authenticated;
grant update (status) on public.question_reports to authenticated;

alter table public.question_reports enable row level security;

-- Beküldés: a szülő a saját gyerekére, a tablet a hozzá rendelt gyerekre.
create policy question_reports_insert on public.question_reports for insert to authenticated
  with check (pupil_id is not null
              and (private.is_parent(private.pupil_household(pupil_id)) or private.is_device_for(pupil_id)));
-- Olvasni, állapotot váltani, törölni csak a szülő.
create policy question_reports_select on public.question_reports for select to authenticated
  using (private.is_parent(household_id));
create policy question_reports_update on public.question_reports for update to authenticated
  using (private.is_parent(household_id)) with check (private.is_parent(household_id));
create policy question_reports_delete on public.question_reports for delete to authenticated
  using (private.is_parent(household_id));
