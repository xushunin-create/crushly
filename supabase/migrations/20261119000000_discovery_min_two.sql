-- Lower the low-population safeguard for discovery from 4 to 2 participants (counting the caller), so matches
-- show as soon as one other person is in the same space. Tradeoff (docs/CAMPUS_SPACES_DESIGN.md §5.2): with only
-- two people present, each can tell exactly who the other is.
update public.app_settings set value = '2' where key = 'discovery_min_participants';
