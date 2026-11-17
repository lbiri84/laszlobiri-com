-- Az oldal-pipák az adatokat is védik; a „Család” pipa megszűnik.
--
-- Eddig a családi adatokhoz a háztartás-tagság adott jogot, az oldal-pipa (apps) csak azt,
-- hogy az oldal megnyílik-e. Mostantól:
--   * a bevásárlólista adataihoz (lists, items, item_history, bump_history) a 'bevasarlas',
--   * a gyakorló szülői adataihoz (pupils, results, pupil_badges, devices, device_pupils,
--     question_reports, chapter_access, párosítás) a 'gyakorlas'
-- pipa is kell, a háztartás-tagság mellett. A gyerek tablet (eszközfiók) nem változik.
--
-- A háztartás-tagság a háttérben marad (az adatok a családhoz tartoznak), de magától
-- állítódik: aki a 'bevasarlas' vagy a 'gyakorlas' oldalt megkapja, tag; akinek mindkettő
-- lekerül, kikerül. Az admin felület ezért nem kér külön „Család” pipát.

-- ---------------------------------------------------------------------------
-- A belépett felhasználó megnyithatja-e az adott oldalt.
-- ---------------------------------------------------------------------------
create function private.has_app(code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from private.allowed_emails a
    join auth.users u on lower(u.email) = a.email
    where u.id = (select auth.uid()) and code = any (a.apps)
  )
$$;
revoke all on function private.has_app(text) from public, anon;
grant execute on function private.has_app(text) to authenticated;

-- A családi oldalak: ezek bármelyike háztartás-tagságot jelent.
create function private.family_apps() returns text[]
language sql immutable set search_path = '' as $$
  select array['bevasarlas', 'gyakorlas']::text[]
$$;
revoke all on function private.family_apps() from public, anon;
grant execute on function private.family_apps() to authenticated;

-- ---------------------------------------------------------------------------
-- Gyakorló: minden szülői szabály az is_parent()-en megy át (policyk, pupils_guard,
-- create_pairing), ezért elég ezt kiegészíteni.
-- ---------------------------------------------------------------------------
create or replace function private.is_parent(hid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = hid and m.user_id = (select auth.uid()) and m.role = 'parent'
  ) and private.has_app('gyakorlas')
$$;

-- ---------------------------------------------------------------------------
-- Bevásárlólista: saját segédfüggvény, a policyk és a bump_history erre állnak át.
-- (Az is_member marad a háztartás és a tagok láthatóságához.)
-- ---------------------------------------------------------------------------
create function private.can_list(hid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_member(hid) and private.has_app('bevasarlas')
$$;
revoke all on function private.can_list(uuid) from public, anon;
grant execute on function private.can_list(uuid) to authenticated;

drop policy lists_select on public.lists;
drop policy lists_update on public.lists;
drop policy items_select on public.items;
drop policy items_insert on public.items;
drop policy items_update on public.items;
drop policy item_history_select on public.item_history;

create policy lists_select on public.lists
  for select to authenticated using (private.can_list(household_id));
create policy lists_update on public.lists
  for update to authenticated
  using (private.can_list(household_id)) with check (private.can_list(household_id));

create policy items_select on public.items
  for select to authenticated using (private.can_list(private.list_household(list_id)));
create policy items_insert on public.items
  for insert to authenticated with check (private.can_list(private.list_household(list_id)));
create policy items_update on public.items
  for update to authenticated
  using (private.can_list(private.list_household(list_id)))
  with check (private.can_list(private.list_household(list_id)));

create policy item_history_select on public.item_history
  for select to authenticated using (private.can_list(household_id));

create or replace function public.bump_history(p_household uuid, p_name_key text, p_name text, p_cat text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.can_list(p_household) then
    raise exception 'nincs jogosultság' using errcode = '42501';
  end if;
  insert into public.item_history (household_id, name_key, name, cat)
  values (p_household, p_name_key, p_name, p_cat)
  on conflict (household_id, name_key) do update
    set count = public.item_history.count + 1,
        name = excluded.name,
        cat = excluded.cat,
        last_used = now();
end $$;

-- ---------------------------------------------------------------------------
-- Admin: a háztartás-tagság az oldalakból következik; a „Család” paraméter megszűnik.
-- ---------------------------------------------------------------------------
drop function public.admin_access_set(text, text[], boolean, text);

create function public.admin_access_set(p_email text, p_apps text[], p_note text default null)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  e    text := lower(btrim(coalesce(p_email, '')));
  hid  uuid := private.admin_household();
  uid  uuid;
  me   text;
  napp text[];
  fam  boolean;
begin
  if not private.is_admin() then
    raise exception 'Csak admin.' using errcode = '42501';
  end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(e) > 254 then
    raise exception 'Érvénytelen e-mail cím.' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into napp from unnest(coalesce(p_apps, '{}')) x;
  if not napp <@ private.app_codes() then
    raise exception 'Ismeretlen oldal.' using errcode = '22023';
  end if;
  if p_note is not null and char_length(btrim(p_note)) > 80 then
    raise exception 'A megjegyzés legfeljebb 80 karakter.' using errcode = '22023';
  end if;
  fam := napp && private.family_apps();
  if fam and hid is null then
    raise exception 'Az adminnak nincs háztartása.' using errcode = '22023';
  end if;

  -- Az admin ne zárja ki magát a családból (különben új családtagot sem tudna felvenni).
  select lower(u.email) into me from auth.users u where u.id = (select auth.uid());
  if e = me and not fam and hid is not null then
    raise exception 'Saját magadnál a Lista vagy a Gyakorló maradjon meg.' using errcode = '22023';
  end if;

  insert into private.allowed_emails as a (email, household_id, apps, note)
  values (e, case when fam then hid end, napp, nullif(btrim(p_note), ''))
  on conflict (email) do update
    set apps = excluded.apps,
        household_id = case when fam then hid
                            when a.household_id = hid then null
                            else a.household_id end,
        note = excluded.note,
        updated_at = now();

  -- Ha már van fiókja, a háztartás-tagság most változik (különben az első belépéskor).
  select u.id into uid from auth.users u where lower(u.email) = e and not u.is_anonymous;
  if uid is not null and hid is not null and exists (select 1 from public.profiles p where p.id = uid) then
    if fam then
      insert into public.household_members (household_id, user_id, role)
      values (hid, uid, 'parent') on conflict do nothing;
    else
      delete from public.household_members m where m.household_id = hid and m.user_id = uid;
    end if;
  end if;
end
$$;
revoke all on function public.admin_access_set(text, text[], text) from public, anon;
grant execute on function public.admin_access_set(text, text[], text) to authenticated;

-- ---------------------------------------------------------------------------
-- Egyszeri rendrakás: a háztartás-tagság igazodjon az oldalakhoz (ha az előző
-- változat „Család” pipájával valaki eltérően lett beállítva). Csak egy háztartásnál.
-- ---------------------------------------------------------------------------
do $$
declare
  hid uuid;
begin
  if (select count(*) from public.households) <> 1 then return; end if;
  select id into hid from public.households;

  update private.allowed_emails a set household_id = hid
  where a.household_id is null and a.apps && private.family_apps();
  update private.allowed_emails a set household_id = null
  where a.household_id = hid and not (a.apps && private.family_apps());

  insert into public.household_members (household_id, user_id, role)
  select hid, p.id, 'parent'
  from private.allowed_emails a
  join auth.users u on lower(u.email) = a.email and not u.is_anonymous
  join public.profiles p on p.id = u.id
  where a.household_id = hid
  on conflict do nothing;

  delete from public.household_members m
  using auth.users u
  where m.household_id = hid and u.id = m.user_id
    and not exists (select 1 from private.allowed_emails a where a.email = lower(u.email) and a.household_id = hid);
end $$;
