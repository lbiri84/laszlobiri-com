-- Oldalankénti hozzáférés és admin felület (laszlobiri.com/admin/).
--
-- Eddig minden engedélyezett cím minden aloldalt elérte. Mostantól minden címhez
-- tartozik, mely aloldalakat nyithatja meg (apps). A családi adatokat továbbra is a
-- háztartás-tagság védi az RLS-ben; aki nincs a háztartásban (pl. egy lakótárs),
-- az ott akkor sem lát semmit, ha az aloldal kapuját megkerüli.
--
-- Az admin (profiles.app_role = 'admin') a felületen:
--   * látja az engedélyezett címeket, hogy van-e már fiókjuk, és mikor léptek be utoljára;
--   * felvesz címet, beállítja az aloldalakat és a háztartás-tagságot, megjegyzést ír;
--   * visszavonja a hozzáférést (a cím kikerül, a háztartás-tagság megszűnik; a fiók
--     megmarad, de semmihez nem fér hozzá).
-- Az admin szerepet csak SQL-lel lehet adni vagy elvenni; a felület nem változtatja.

-- ---------------------------------------------------------------------------
-- Az aloldalak kódjai. Új aloldal: ide és a kliens SITES listájába (lib/v1/access.js).
-- ---------------------------------------------------------------------------
create function private.app_codes() returns text[]
language sql immutable set search_path = '' as $$
  select array['ebed', 'bevasarlas', 'gyakorlas', 'elszamolas']::text[]
$$;
revoke all on function private.app_codes() from public, anon;
grant execute on function private.app_codes() to authenticated;

alter table private.allowed_emails
  add column apps text[] not null default '{}'
    check (apps <@ array['ebed', 'bevasarlas', 'gyakorlas', 'elszamolas']::text[]),
  add column updated_at timestamptz not null default now();

alter table private.allowed_emails
  add constraint allowed_emails_note_len check (note is null or char_length(note) <= 80);

-- A meglévő címek (a család) eddig mindent elértek: ez így marad.
update private.allowed_emails set apps = array['ebed', 'bevasarlas', 'gyakorlas'];

-- ---------------------------------------------------------------------------
-- Segédfüggvények
-- ---------------------------------------------------------------------------
create function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p where p.id = (select auth.uid()) and p.app_role = 'admin'
  )
$$;
revoke all on function private.is_admin() from public, anon;
grant execute on function private.is_admin() to authenticated;

-- Az admin háztartása (ebbe vesz fel új tagot). Egy háztartás van; ha több lenne,
-- a legrégebbi tagság számít.
create function private.admin_household() returns uuid
language sql stable security definer set search_path = '' as $$
  select m.household_id from public.household_members m
  where m.user_id = (select auth.uid())
  order by m.created_at limit 1
$$;
revoke all on function private.admin_household() from public, anon;
grant execute on function private.admin_household() to authenticated;

-- ---------------------------------------------------------------------------
-- A belépett felhasználó hozzáférése: { apps: [...], admin: bool }.
-- Névtelen fiók (gyerek tablet) és ismeretlen cím: üres lista.
-- ---------------------------------------------------------------------------
create function public.my_access() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'apps', coalesce((
      select to_jsonb(a.apps) from private.allowed_emails a
      join auth.users u on lower(u.email) = a.email
      where u.id = (select auth.uid())
    ), '[]'::jsonb),
    'admin', private.is_admin()
  )
$$;
revoke all on function public.my_access() from public, anon;
grant execute on function public.my_access() to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: lista
-- ---------------------------------------------------------------------------
create function public.admin_access_list()
returns table (
  email           text,
  apps            text[],
  in_household    boolean,
  app_role        text,
  note            text,
  display_name    text,
  has_account     boolean,
  last_sign_in_at timestamptz,
  added_at        timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then
    raise exception 'Csak admin.' using errcode = '42501';
  end if;
  return query
    select a.email, a.apps,
           a.household_id is not null and a.household_id = private.admin_household(),
           a.app_role, a.note, p.display_name, u.id is not null, u.last_sign_in_at, a.created_at
    from private.allowed_emails a
    left join auth.users u on lower(u.email) = a.email and not u.is_anonymous
    left join public.profiles p on p.id = u.id
    order by a.created_at, a.email;
end
$$;
revoke all on function public.admin_access_list() from public, anon;
grant execute on function public.admin_access_list() to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: felvétel vagy módosítás
-- ---------------------------------------------------------------------------
create function public.admin_access_set(p_email text, p_apps text[], p_household boolean, p_note text default null)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  e    text := lower(btrim(coalesce(p_email, '')));
  hid  uuid := private.admin_household();
  uid  uuid;
  me   text;
  napp text[];
begin
  if not private.is_admin() then
    raise exception 'Csak admin.' using errcode = '42501';
  end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(e) > 254 then
    raise exception 'Érvénytelen e-mail cím.' using errcode = '22023';
  end if;
  -- egyedi, rendezett lista
  select coalesce(array_agg(distinct x order by x), '{}') into napp from unnest(coalesce(p_apps, '{}')) x;
  if not napp <@ private.app_codes() then
    raise exception 'Ismeretlen oldal.' using errcode = '22023';
  end if;
  if p_note is not null and char_length(btrim(p_note)) > 80 then
    raise exception 'A megjegyzés legfeljebb 80 karakter.' using errcode = '22023';
  end if;
  if coalesce(p_household, false) and hid is null then
    raise exception 'Az adminnak nincs háztartása.' using errcode = '22023';
  end if;

  -- Saját magát ne zárja ki a háztartásból.
  select lower(u.email) into me from auth.users u where u.id = (select auth.uid());
  if e = me and not coalesce(p_household, false) and hid is not null then
    raise exception 'Saját magadat nem veheted ki a háztartásból.' using errcode = '22023';
  end if;

  insert into private.allowed_emails as a (email, household_id, apps, note)
  values (e, case when p_household then hid end, napp, nullif(btrim(p_note), ''))
  on conflict (email) do update
    set apps = excluded.apps,
        household_id = case when p_household then hid
                            when a.household_id = hid then null
                            else a.household_id end,
        note = excluded.note,
        updated_at = now();

  -- Ha már van fiókja, a háztartás-tagság most változik (különben az első belépéskor).
  select u.id into uid from auth.users u where lower(u.email) = e and not u.is_anonymous;
  if uid is not null and hid is not null and exists (select 1 from public.profiles p where p.id = uid) then
    if p_household then
      insert into public.household_members (household_id, user_id, role)
      values (hid, uid, 'parent') on conflict do nothing;
    else
      delete from public.household_members m where m.household_id = hid and m.user_id = uid;
    end if;
  end if;
end
$$;
revoke all on function public.admin_access_set(text, text[], boolean, text) from public, anon;
grant execute on function public.admin_access_set(text, text[], boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: visszavonás
-- ---------------------------------------------------------------------------
create function public.admin_access_remove(p_email text)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  e   text := lower(btrim(coalesce(p_email, '')));
  hid uuid := private.admin_household();
  uid uuid;
  me  text;
begin
  if not private.is_admin() then
    raise exception 'Csak admin.' using errcode = '42501';
  end if;
  select lower(u.email) into me from auth.users u where u.id = (select auth.uid());
  if e = me then
    raise exception 'Saját magadat nem vonhatod vissza.' using errcode = '22023';
  end if;

  delete from private.allowed_emails a where a.email = e;
  select u.id into uid from auth.users u where lower(u.email) = e and not u.is_anonymous;
  if uid is not null and hid is not null then
    delete from public.household_members m where m.household_id = hid and m.user_id = uid;
  end if;
end
$$;
revoke all on function public.admin_access_remove(text) from public, anon;
grant execute on function public.admin_access_remove(text) to authenticated;
