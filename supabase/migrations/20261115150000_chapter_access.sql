-- Gyakorló: a szülő tantárgyanként beállítja, mely tankönyvi fejezetek érhetők el a
-- gyerekeknek (a háztartásban közösen), hogy ne szaladjanak előre az iskolai anyaghoz képest.
--
-- Egy sor = egy háztartás egy tantárgya; a chapters a bepipált fejezetek kódjai
-- (a kódokat a kliens ismeri, pl. 'k11', 'm2-3'). Ha egy tantárgynak nincs sora,
-- minden fejezete elérhető (így a beállítás bevezetése előtti állapot nem változik).
-- A gyerek tablet olvassa, de nem írhatja.

create table public.chapter_access (
  household_id uuid not null references public.households (id) on delete cascade,
  subject      text not null check (subject in ('matek', 'nyelvtan', 'kornyezet')),
  chapters     text[] not null default '{}'
               check (cardinality(chapters) <= 300
                      and array_to_string(chapters, ',') ~ '^([a-z0-9-]{1,32}(,|$))*$'),
  updated_at   timestamptz not null default now(),
  primary key (household_id, subject)
);

-- Az eszköz (gyerek tablet) melyik háztartáshoz tartozik.
create function private.is_device_in(hid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.devices d where d.user_id = (select auth.uid()) and d.household_id = hid)
$$;
revoke all on function private.is_device_in(uuid) from public, anon;
grant execute on function private.is_device_in(uuid) to authenticated;

revoke all on public.chapter_access from public, anon, authenticated;
grant select, delete on public.chapter_access to authenticated;
grant insert (household_id, subject, chapters, updated_at) on public.chapter_access to authenticated;
grant update (chapters, updated_at) on public.chapter_access to authenticated;

alter table public.chapter_access enable row level security;

create policy chapter_access_select on public.chapter_access for select to authenticated
  using (private.is_parent(household_id) or private.is_device_in(household_id));
create policy chapter_access_insert on public.chapter_access for insert to authenticated
  with check (private.is_parent(household_id));
create policy chapter_access_update on public.chapter_access for update to authenticated
  using (private.is_parent(household_id)) with check (private.is_parent(household_id));
create policy chapter_access_delete on public.chapter_access for delete to authenticated
  using (private.is_parent(household_id));
