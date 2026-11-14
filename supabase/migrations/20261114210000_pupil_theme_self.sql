-- A gyerek a saját színtémáját maga választja a gyakorló oldalon, a saját
-- tabletjén is (párosított eszközfiók). A tablet csak a hozzá rendelt gyerek
-- témáját írhatja; a becenevet és az ikont továbbra is csak a szülő.

create policy pupils_update_device on public.pupils for update to authenticated
  using (private.is_device_for(id)) with check (private.is_device_for(id));

-- Aki nem a háztartás szülője (azaz a tablet), annak csak a theme változhat.
create function private.pupils_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not private.is_parent(old.household_id) then
    new.nickname := old.nickname;
    new.avatar := old.avatar;
  end if;
  new.household_id := old.household_id;
  return new;
end $$;
revoke all on function private.pupils_guard() from public, anon, authenticated;

create trigger pupils_guard before update on public.pupils
  for each row execute function private.pupils_guard();
