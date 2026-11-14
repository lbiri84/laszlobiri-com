-- Harmadik minijáték a gyakorló oldalon: falbontó ('breakout').

alter table public.results drop constraint results_kind_check;
alter table public.results add constraint results_kind_check check (kind in ('round', 'hangman', 'wordsearch', 'breakout'));
