-- Development seed data (applied by `supabase db reset` / `supabase start`).
insert into public.campus_spaces (id, name, kind, subtitle, starts_at, ends_at, is_active, sort_order) values
  ('5a000000-0000-4000-8000-000000000001', 'USC Village',          'place', 'Courtyard & dining',         null, null, true, 10),
  ('5a000000-0000-4000-8000-000000000002', 'Leavey Library',       'place', 'Open 24 hours',              null, null, true, 20),
  ('5a000000-0000-4000-8000-000000000003', 'Tutor Campus Center',  'place', 'TCC',                        null, null, true, 30),
  ('5a000000-0000-4000-8000-000000000004', 'Trojan Hacks',         'event', 'Hackathon · Ronald Tutor Hall', now() - interval '1 hour', now() + interval '30 days', true, 100),
  ('5a000000-0000-4000-8000-000000000005', 'Spring Social Mixer',  'event', 'Mixer · Ground Zero Cafe',      now() - interval '1 hour', now() + interval '14 days', true, 110)
on conflict (id) do nothing;

insert into public.space_codes (code, space_id) values
  ('HACK26', '5a000000-0000-4000-8000-000000000004'),
  ('MIXER',  '5a000000-0000-4000-8000-000000000005')
on conflict (code) do nothing; 