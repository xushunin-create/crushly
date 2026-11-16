-- Development seed data (applied by `supabase db reset` / `supabase start`).
--
-- Campus spaces are NOT seeded here yet. Draft USC zone boundaries are added in Phase 3
-- (see docs/CAMPUS_SPACES_DESIGN.md §8.3) as validation_status = 'draft', which production
-- rejects while app_settings.allow_draft_spaces = false.
select 1;
