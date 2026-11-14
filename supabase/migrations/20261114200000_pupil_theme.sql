-- Gyerekprofilonként választható színtéma a gyakorló oldalon.
-- 'slate': a laszlobiri alap (palakék); 'rose': rózsaszín paletta.
-- A téma a profilhoz tartozik, így a gyerek neve nem kerül a kódba.

alter table public.pupils
  add column theme text not null default 'slate' check (theme in ('slate', 'rose'));

grant insert (theme) on public.pupils to authenticated;
grant update (theme) on public.pupils to authenticated;
