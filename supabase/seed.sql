-- Csak HELYI fejlesztéshez (`supabase start` / `supabase db reset` futtatja).
-- Kitalált adatok; valódi e-mail cím és gyerek becenév nem kerülhet ide.
-- Az éles beállítás lépései: supabase/README.md.

insert into public.households (id, name)
values ('00000000-0000-0000-0000-00000000a001', 'Teszt háztartás');

insert into private.allowed_emails (email, household_id, app_role) values
  ('szulo1@example.invalid', '00000000-0000-0000-0000-00000000a001', 'admin'),
  ('szulo2@example.invalid', '00000000-0000-0000-0000-00000000a001', 'user');
