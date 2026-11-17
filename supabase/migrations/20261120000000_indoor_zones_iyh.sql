-- Indoor zones and Iovine and Young Hall (docs/CAMPUS_SPACES_DESIGN.md §3.1a, §8.2b).
--
-- Buildings are too small for the whole-accuracy-circle rule: indoor fixes are typically 20-65 m, and a fix only counts
-- under that rule if its whole circle (+5 m) fits inside. So each zone can now say how it is judged:
--   membership_rule 'circle' (default, unchanged for every existing zone) or 'point' (the fix's position must be inside),
--   max_accuracy_m  per-zone override of app_settings.evidence_max_accuracy_m (null = global; 5..100).
-- The app applies the same rules on device (SpaceZone / MembershipEngine). Tradeoff for 'point' zones: someone just
-- outside the walls can count when their GPS errs inward. Accepted by product decision for IYH (2026-11-17).

alter table public.campus_spaces
  add column membership_rule text not null default 'circle' check (membership_rule in ('circle', 'point')),
  add column max_accuracy_m int check (max_accuracy_m is null or max_accuracy_m between 5 and 100);

-- Evidence check with a per-space accuracy limit. The 3-argument version stays for callers that have no space.
create function public.check_evidence(e jsonb, prev_fix_ts_ms bigint, allow_stationary boolean, max_accuracy_m int)
returns bigint
language plpgsql stable set search_path = public as $$
declare v_ts bigint; v_age bigint; v_acc numeric; v_stationary boolean; v_max_age int;
begin
  if e is null or jsonb_typeof(e) <> 'object' then perform public.raise_code('invalid_input'); end if;
  begin
    v_ts := (e ->> 'fix_ts_ms')::bigint;
    v_age := (e ->> 'fix_age_ms')::bigint;
    v_acc := (e ->> 'horizontal_accuracy_m')::numeric;
    v_stationary := coalesce((e ->> 'stationary')::boolean, false);
  exception when others then
    perform public.raise_code('invalid_input');
  end;
  if v_ts is null or v_age is null or v_acc is null or v_age < 0 or v_acc <= 0 then
    perform public.raise_code('invalid_input');
  end if;
  if v_stationary and not allow_stationary then
    perform public.raise_code('stale_evidence');
  end if;
  if v_acc > coalesce(max_accuracy_m, public.setting_int('evidence_max_accuracy_m')) then
    perform public.raise_code('insufficient_accuracy');
  end if;
  v_max_age := case when v_stationary then public.setting_int('evidence_stationary_max_fix_age_seconds')
                    else public.setting_int('evidence_max_fix_age_seconds') end;
  if v_age > v_max_age::bigint * 1000 then
    perform public.raise_code('stale_evidence');
  end if;
  -- A heartbeat that cites no newer fix is not evidence. A stationary renewal may re-cite the last fix.
  if prev_fix_ts_ms is not null
     and ((not v_stationary and v_ts <= prev_fix_ts_ms) or (v_stationary and v_ts < prev_fix_ts_ms)) then
    perform public.raise_code('stale_evidence');
  end if;
  return v_ts;
end $$;

create or replace function public.check_evidence(e jsonb, prev_fix_ts_ms bigint, allow_stationary boolean) returns bigint
language sql stable set search_path = public as $$
  select public.check_evidence(e, prev_fix_ts_ms, allow_stationary, null::int)
$$;

-- Internal helper: never callable by clients (matches §11 of the campus_spaces migration).
revoke all on function public.check_evidence(jsonb, bigint, boolean, int) from public, anon, authenticated;
grant execute on function public.check_evidence(jsonb, bigint, boolean, int) to service_role;

-- open/renew: unchanged except that the evidence check uses the space's own accuracy limit.
create or replace function public.open_participation(p_space_slug text, p_boundary_version int, p_consent_epoch bigint,
                                          p_client_request_id uuid, p_evidence jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_uid();
  st public.participation_state;
  sp public.campus_spaces;
  cur public.participation_sessions;
  v_fix bigint;
  r public.participation_sessions;
begin
  if p_space_slug is null or p_boundary_version is null or p_consent_epoch is null or p_client_request_id is null then
    perform public.raise_code('invalid_input');
  end if;

  insert into public.participation_state (user_id) values (v_uid) on conflict (user_id) do nothing;
  select * into st from public.participation_state where user_id = v_uid for update;   -- serializes transitions

  -- Idempotent retry of the request that created the current, still-valid session.
  select * into cur from public.participation_sessions s where s.user_id = v_uid;
  if cur.id is not null and cur.client_request_id = p_client_request_id
     and cur.consent_epoch = p_consent_epoch and cur.lease_expires_at > now() then
    return jsonb_build_object('session_id', cur.id, 'lease_expires_at', cur.lease_expires_at, 'now', now());
  end if;

  perform public.enforce_rate_limit(v_uid, 'open');
  if public.is_paused(v_uid) then perform public.raise_code('matching_paused'); end if;
  if p_consent_epoch <> st.consent_epoch then perform public.raise_code('consent_stale'); end if;
  if not public.matching_ready(v_uid) then perform public.raise_code('profile_incomplete'); end if;

  select * into sp from public.campus_spaces cs
   where cs.slug = p_space_slug and cs.enabled
     and (cs.validation_status = 'field_validated' or public.setting_bool('allow_draft_spaces'));
  if sp.id is null then perform public.raise_code('space_unavailable'); end if;
  if sp.boundary_version <> p_boundary_version then perform public.raise_code('boundary_outdated'); end if;

  v_fix := public.check_evidence(p_evidence, null, false, sp.max_accuracy_m);   -- entry needs a fresh, moving-or-not real fix

  -- Never transfer consent: whatever existed before (any space) ends now, interests included.
  delete from public.participation_sessions s where s.user_id = v_uid;

  insert into public.participation_sessions as ps
    (user_id, space_id, boundary_version, consent_epoch, client_request_id, lease_expires_at, last_seq, last_fix_ts_ms)
  values (v_uid, sp.id, sp.boundary_version, st.consent_epoch, p_client_request_id,
          now() + make_interval(secs => public.setting_int('participation_lease_seconds')), 0, v_fix)
  returning ps.* into r;

  return jsonb_build_object('session_id', r.id, 'lease_expires_at', r.lease_expires_at, 'now', now());
end $$;

create or replace function public.renew_participation(p_session_id uuid, p_seq bigint, p_evidence jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); s public.participation_sessions; v_fix bigint; v_until timestamptz;
begin
  if p_session_id is null or p_seq is null then perform public.raise_code('invalid_input'); end if;
  perform public.enforce_rate_limit(v_uid, 'renew');

  select * into s from public.participation_sessions ps where ps.id = p_session_id and ps.user_id = v_uid for update;
  if s.id is null then perform public.raise_code('session_expired'); end if;
  if s.lease_expires_at <= now() then
    perform public.raise_code('session_expired');   -- expired is final; the tick deletes the row
  end if;
  if public.is_paused(v_uid) then perform public.raise_code('matching_paused'); end if;
  if p_seq <= s.last_seq then perform public.raise_code('stale_request'); end if;

  v_fix := public.check_evidence(p_evidence, s.last_fix_ts_ms, true,
                                 (select cs.max_accuracy_m from public.campus_spaces cs where cs.id = s.space_id));

  v_until := now() + make_interval(secs => public.setting_int('participation_lease_seconds'));
  update public.participation_sessions ps
     set lease_expires_at = v_until, last_seq = p_seq, last_fix_ts_ms = v_fix
   where ps.id = s.id;
  return jsonb_build_object('session_id', s.id, 'lease_expires_at', v_until, 'now', now());
end $$;

-- Iovine and Young Hall: OpenStreetMap building outline (ODbL, © OpenStreetMap contributors). Draft until walked.
insert into public.campus_spaces (slug, name, subtitle, boundary, boundary_version, source_refs, validation_status, enabled,
                                  sort_order, membership_rule, max_accuracy_m)
values
  ('upc-iovine-young-hall', 'Iovine and Young Hall', 'USC Iovine and Young Academy',
   $geo${"type":"Polygon","coordinates":[[[-118.2886529,34.0186619],[-118.2885243,34.0186017],[-118.2885214,34.0184359],[-118.2881906,34.0184346],[-118.2881552,34.0184387],[-118.288041,34.0186172],[-118.2885436,34.0188373],[-118.2886529,34.0186619]]]}$geo$::jsonb, 1,
   $src$[{"kind": "openstreetmap", "way": 727901784, "url": "https://www.openstreetmap.org/way/727901784", "license": "ODbL, © OpenStreetMap contributors", "retrieved": "2026-11-17"}, {"kind": "note", "text": "Indoor zone: building footprint (3 levels). Uses membership_rule 'point' and max_accuracy_m 40 because indoor fixes are too coarse for the whole-circle rule. OSM tags it 'USC Iovine and Young Academy, 3738 Watt Way'; confirm on site that this is the right building and outline."}]$src$::jsonb,
   'draft', true, 40, 'point', 40)
on conflict (slug) do nothing;
