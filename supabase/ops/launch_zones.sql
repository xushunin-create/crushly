-- Launch: the four shipped zones were walked and confirmed good (2026-11-26), so mark them field-validated and
-- turn draft zones off in production. Outlines are unchanged, so boundary_version stays the same (consent remains
-- valid). Run once against production, then re-run verify_production.sql.
begin;

update public.campus_spaces
   set validation_status = 'field_validated'
 where slug in ('upc-alumni-park-tommy-trojan', 'upc-mccarthy-quad', 'usc-village-great-lawn', 'upc-iovine-young-hall');

update public.app_settings set value = 'false'::jsonb where key = 'allow_draft_spaces';

select slug, validation_status, enabled, boundary_version from public.campus_spaces order by sort_order;
select key, value from public.app_settings where key = 'allow_draft_spaces';

commit;
