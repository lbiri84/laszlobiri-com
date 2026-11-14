-- Harmadik gyerektéma: 'sky' (égkék, világos: #1B90DD, #5FCEEA, #FFFFFF).

alter table public.pupils drop constraint pupils_theme_check;
alter table public.pupils add constraint pupils_theme_check check (theme in ('slate', 'rose', 'sky'));
