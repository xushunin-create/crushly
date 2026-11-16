-- Campus Spaces & private matching. Implements docs/CAMPUS_SPACES_DESIGN.md (§4–§7).
--
-- Replaces the Pulse / Around / Heart Signal / Crossed Hearts / Find Each Other / Shield model.
-- The live project has no real users (decision 2026-11-16), so conflicting tables are dropped, not migrated.
--
-- Privacy invariants enforced here (each has a SQL test in supabase/tests):
--   * The server never receives coordinates. Participation = (user, space, boundary version, 60 s lease).
--   * At most one participation row per user; rows are DELETED when they end. No history.
--   * Every revoke bumps participation_state.consent_epoch, so a delayed/replayed "open" is rejected.
--   * Interests reference sessions and cascade-delete when either session ends.
--   * Matches store no place. Messages are reachable only through participant-checked RPCs.
--   * Clients have no direct access to sessions, interests, matches, messages, evidence or rate limits.
--
-- Conventions as in 20261110000000_init.sql: security definer RPCs, search_path = public, contract
-- errors raised as `raise exception using errcode = 'P0001', message = '<code>'`.

-- ---------------------------------------------------------------------------
-- 0. Remove the old model
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array[
         'start_pulse', 'pause_pulse', 'resume_pulse', 'end_pulse', 'enter_space_code', 'around_profiles',
         'recent_encounters', 'send_heart_signal', 'my_signal_receipts', 'my_sent_signals', 'my_matches',
         'set_connection_status', 'send_connection_action', 'respond_connection_action', 'connection_instagram',
         'require_find_eligible', 'request_find', 'respond_find', 'cancel_find', 'complete_find',
         'enter_shield', 'exit_shield', 'report_user', 'is_shielded', 'live_session', 'is_discoverable_to',
         'has_recent_encounter', 'can_view_profile', 'make_public_profile', 'effective_connection',
         'end_open_finds', 'match_other', 'match_between', 'require_open_connection', 'touch_connection',
         'notify_find_accepted', 'crushly_tick', 'my_state', 'notification_still_relevant', 'pref_enabled',
         'update_notification_prefs'])
  loop
    execute 'drop function ' || r.sig || ' cascade';
  end loop;
end $$;

drop table if exists
  public.find_requests, public.connection_actions, public.connections, public.heart_signals,
  public.encounters, public.space_codes, public.pulse_sessions, public.shield_states, public.matches,
  public.campus_spaces, public.notification_prefs
cascade;

drop type if exists public.public_profile, public.space_kind, public.signal_status, public.match_kind,
  public.connection_status, public.connection_action_kind, public.request_status cascade;

-- Instagram exchange is gone; don't keep the handle.
alter table public.profile_private drop column if exists instagram_handle;

-- Old notification kinds can never be sent again.
delete from public.notification_outbox;

-- ---------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------
delete from public.app_settings where key in (
  'pulse_durations_minutes', 'signals_per_session', 'signal_validity_hours', 'encounter_window_hours',
  'receipt_delay_min_seconds', 'receipt_delay_max_seconds', 'receipt_time_bucket_minutes',
  'receipt_space_min_crowd', 'connection_confirm_hours', 'connection_inactive_days',
  'find_request_timeout_minutes', 'find_active_minutes', 'shield_durations_minutes',
  'require_own_pulse_to_view_around', 'analytics_allowed_events');

insert into public.app_settings (key, value) values
  -- Participation lease and location-evidence plausibility (design §3.3). The server cannot verify
  -- location; it rejects implausible or stale claims.
  ('participation_lease_seconds',             '60'),
  ('evidence_max_accuracy_m',                 '30'),
  ('evidence_max_fix_age_seconds',            '15'),
  ('evidence_stationary_max_fix_age_seconds', '300'),
  ('allow_draft_spaces',                      'false'),
  -- Discovery (design §5.2).
  ('discovery_min_participants',              '4'),
  ('discovery_max_results',                   '8'),
  -- Interests (design §5.3).
  ('interests_per_session',                   '5'),
  ('receipt_delay_min_seconds',               '30'),
  ('receipt_delay_max_seconds',               '90'),
  -- Pause durations offered by the app (null = until resumed).
  ('pause_durations_minutes',                 '[60, 240, 1440]'),
  -- Chat (design §6).
  ('message_max_chars',                       '2000'),
  ('report_evidence_retention_days',          '90'),
  ('deletion_tombstone_retention_days',       '14'),
  -- Rate limits: bucket -> [[max, window_seconds], ...].
  ('rate_limits', '{
     "open":     [[30, 3600]],
     "renew":    [[12, 60]],
     "discover": [[1, 15], [60, 3600]],
     "interest": [[30, 3600]],
     "message":  [[20, 60], [500, 86400]],
     "report":   [[10, 86400]]
   }'),
  -- Analytics: no presence, participation, interest or match events (they would form a movement trail).
  ('analytics_allowed_events', '["app_open","onboarding_step","onboarding_completed","profile_updated","photo_uploaded","conversation_left","user_blocked","user_unblocked","user_reported","notification_opened","notification_prefs_changed","account_deleted"]')
on conflict (key) do update set value = excluded.value;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------

-- Matching preferences are private (never shown to others).
alter table public.profile_private
  add column match_gender text check (match_gender in ('woman', 'man', 'nonbinary')),
  add column show_me      text[] not null default '{}'
    check (show_me <@ array['woman', 'man', 'nonbinary']::text[]),
  add column age_min      int not null default 18 check (age_min between 18 and 120),
  add column age_max      int not null default 120 check (age_max between 18 and 120),
  add constraint profile_private_age_range check (age_min <= age_max);

-- Supported spaces. Boundaries are evaluated ON THE DEVICE; the server only stores them for distribution.
-- `slug` is the stable identifier. Changing a boundary must bump boundary_version.
create table public.campus_spaces (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{2,63}$'),
  name              text not null check (char_length(name) between 1 and 80),
  subtitle          text check (subtitle is null or char_length(subtitle) <= 120),
  boundary          jsonb not null check (
                      boundary ->> 'type' = 'Polygon'
                      and jsonb_typeof(boundary -> 'coordinates') = 'array'
                      and jsonb_array_length(boundary -> 'coordinates') >= 1),
  boundary_version  int not null default 1 check (boundary_version >= 1),
  source_refs       jsonb not null default '[]' check (jsonb_typeof(source_refs) = 'array'),
  validation_status text not null default 'draft' check (validation_status in ('draft', 'field_validated')),
  enabled           boolean not null default false,
  sort_order        int not null default 0,
  updated_at        timestamptz not null default now()
);

create table public.participation_state (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  consent_epoch   bigint not null default 0 check (consent_epoch >= 0),
  matching_paused boolean not null default false,
  paused_until    timestamptz   -- null with matching_paused = until resumed
);

create table public.participation_sessions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null unique references auth.users (id) on delete cascade,
  space_id          uuid not null references public.campus_spaces (id) on delete cascade,
  boundary_version  int not null,
  consent_epoch     bigint not null,
  client_request_id uuid not null,
  started_at        timestamptz not null default now(),
  lease_expires_at  timestamptz not null,
  last_seq          bigint not null default 0,
  last_fix_ts_ms    bigint not null,   -- device clock; only compared with itself (monotonic check)
  interests_sent    int not null default 0 check (interests_sent >= 0)
);
create index participation_sessions_space_idx on public.participation_sessions (space_id, lease_expires_at);

create table public.interests (
  id                   uuid primary key default gen_random_uuid(),
  sender_session_id    uuid not null references public.participation_sessions (id) on delete cascade,
  recipient_session_id uuid not null references public.participation_sessions (id) on delete cascade,
  created_at           timestamptz not null default now(),
  visible_at           timestamptz not null,
  unique (sender_session_id, recipient_session_id),
  check (sender_session_id <> recipient_session_id)
);
create index interests_recipient_idx on public.interests (recipient_session_id);

-- Who discovery has shown to whom during the current visits. Interest is only possible toward someone
-- you were actually shown, so a known user id can't be probed to learn whether that person is present
-- (which would bypass sampling, rate limits and the low-population safeguard). Cascades with either session.
create table public.discovery_exposures (
  viewer_session_id uuid not null references public.participation_sessions (id) on delete cascade,
  target_session_id uuid not null references public.participation_sessions (id) on delete cascade,
  primary key (viewer_session_id, target_session_id)
);
create index discovery_exposures_target_idx on public.discovery_exposures (target_session_id);

create table public.matches (
  id             uuid primary key default gen_random_uuid(),
  user_a         uuid not null references auth.users (id) on delete cascade,
  user_b         uuid not null references auth.users (id) on delete cascade,
  created_at     timestamptz not null default now(),
  last_read_at_a timestamptz,
  last_read_at_b timestamptz,
  check (user_a < user_b),
  unique (user_a, user_b)
);
create index matches_user_b_idx on public.matches (user_b);

create table public.messages (
  id              uuid primary key,   -- client-generated; the idempotency key for retries
  match_id        uuid not null references public.matches (id) on delete cascade,
  sender_id       uuid not null references auth.users (id) on delete cascade,
  body            text not null check (char_length(body) between 1 and 2000),
  payload_version smallint not null default 1 check (payload_version = 1),  -- 2+ reserved for E2EE
  created_at      timestamptz not null default clock_timestamp()
);
create index messages_match_idx on public.messages (match_id, created_at desc, id desc);

-- Ids only: lets a restore runbook re-apply deletions that happened after the backup was taken.
create table public.deletion_tombstones (
  match_id   uuid primary key,
  deleted_at timestamptz not null default now()
);

-- Evidence the reporter explicitly chose to submit. Service role only; purged after retention.
create table public.report_evidence (
  id                 uuid primary key default gen_random_uuid(),
  report_id          uuid not null references public.reports (id) on delete cascade,
  message_id         uuid not null,
  sent_by_reported   boolean not null,
  body               text not null,
  sent_at            timestamptz not null,
  purge_after        timestamptz not null
);
create index report_evidence_purge_idx on public.report_evidence (purge_after);

create table public.rate_limits (
  user_id      uuid not null references auth.users (id) on delete cascade,
  bucket       text not null,
  window_start timestamptz not null,
  hits         int not null default 0,
  primary key (user_id, bucket, window_start)
);

create table public.notification_prefs (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  new_matches boolean not null default true,
  messages    boolean not null default true
);

-- ---------------------------------------------------------------------------
-- 3. Privileges and RLS for the new tables
-- ---------------------------------------------------------------------------
alter table public.campus_spaces          enable row level security;
alter table public.participation_state    enable row level security;
alter table public.participation_sessions enable row level security;
alter table public.interests              enable row level security;
alter table public.discovery_exposures    enable row level security;
alter table public.matches                enable row level security;
alter table public.messages               enable row level security;
alter table public.deletion_tombstones    enable row level security;
alter table public.report_evidence        enable row level security;
alter table public.rate_limits            enable row level security;
alter table public.notification_prefs     enable row level security;

-- Supabase grants new tables to anon/authenticated by default; start from nothing.
revoke all on public.campus_spaces, public.participation_state, public.participation_sessions,
  public.interests, public.discovery_exposures, public.matches, public.messages, public.deletion_tombstones, public.report_evidence,
  public.rate_limits, public.notification_prefs
from public, anon, authenticated;
grant all on public.campus_spaces, public.participation_state, public.participation_sessions,
  public.interests, public.discovery_exposures, public.matches, public.messages, public.deletion_tombstones, public.report_evidence,
  public.rate_limits, public.notification_prefs
to service_role;

-- The static list of usable spaces is public to signed-in users (the device needs boundaries).
grant select on public.campus_spaces to authenticated;
create policy campus_spaces_read on public.campus_spaces for select to authenticated
  using (enabled and (validation_status = 'field_validated'
                      or coalesce((select (s.value #>> '{}')::boolean from public.app_settings s
                                    where s.key = 'allow_draft_spaces'), false)));

-- Everything else: no grants, no policies. Access only through the RPCs below.

-- ---------------------------------------------------------------------------
-- 4. Helpers (internal; never granted to clients)
-- ---------------------------------------------------------------------------
create function public.raise_code(code text) returns void
language plpgsql volatile as $$
begin
  raise exception using errcode = 'P0001', message = code;
end $$;

-- Fixed-window rate limiting. Buckets and limits come from app_settings.rate_limits.
create function public.enforce_rate_limit(u uuid, p_bucket text) returns void
language plpgsql set search_path = public as $$
declare v_rule jsonb; v_max int; v_window int; v_start timestamptz; v_hits int;
begin
  for v_rule in select * from jsonb_array_elements(coalesce(public.setting_json('rate_limits') -> p_bucket, '[]')) loop
    v_max := (v_rule ->> 0)::int;
    v_window := (v_rule ->> 1)::int;
    v_start := to_timestamp(floor(extract(epoch from now()) / v_window) * v_window);
    insert into public.rate_limits as rl (user_id, bucket, window_start, hits)
    values (u, p_bucket || ':' || v_window, v_start, 1)
    on conflict (user_id, bucket, window_start) do update set hits = rl.hits + 1
    returning rl.hits into v_hits;
    if v_hits > v_max then
      perform public.raise_code('rate_limited');
    end if;
  end loop;
end $$;

create function public.is_paused(u uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from public.participation_state ps
                  where ps.user_id = u and ps.matching_paused
                    and (ps.paused_until is null or ps.paused_until > now()))
$$;

-- The user's session if its lease is still valid (null row otherwise).
create function public.active_session(u uuid) returns public.participation_sessions
language sql stable set search_path = public as $$
  select s.* from public.participation_sessions s where s.user_id = u and s.lease_expires_at > now()
$$;

-- Ends a user's participation: deletes the session (interests cascade) and bumps the consent epoch so
-- no in-flight "open" from before this moment can succeed. Returns the new epoch.
create function public.end_participation(u uuid) returns bigint
language plpgsql set search_path = public as $$
declare v_epoch bigint;
begin
  insert into public.participation_state (user_id) values (u) on conflict (user_id) do nothing;
  update public.participation_state ps set consent_epoch = ps.consent_epoch + 1
   where ps.user_id = u returning ps.consent_epoch into v_epoch;
  delete from public.participation_sessions s where s.user_id = u;
  return v_epoch;
end $$;

-- Validates a device's location-evidence claim (design §3.3). Shape:
--   {"fix_ts_ms": <device epoch ms of the fix>, "fix_age_ms": <age when sent>,
--    "horizontal_accuracy_m": <metres>, "stationary": <bool>}
-- Returns the fix timestamp. Device-reported, so plausibility only: it cannot prove location.
create function public.check_evidence(e jsonb, prev_fix_ts_ms bigint, allow_stationary boolean) returns bigint
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
  if v_acc > public.setting_int('evidence_max_accuracy_m') then
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

create or replace function public.is_blocked_between(a uuid, b uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (
    select 1 from public.blocks bl
    where (bl.blocker_id = a and bl.blocked_id = b) or (bl.blocker_id = b and bl.blocked_id = a))
$$;

create function public.match_between(a uuid, b uuid) returns uuid
language sql stable set search_path = public as $$
  select m.id from public.matches m where m.user_a = least(a, b) and m.user_b = greatest(a, b)
$$;

-- Returns the other participant, or raises not_found if the caller is not one (or the match is gone).
create function public.match_other(p_match_id uuid, u uuid) returns uuid
language plpgsql stable set search_path = public as $$
declare v_other uuid;
begin
  select case when m.user_a = u then m.user_b else m.user_a end into v_other
    from public.matches m where m.id = p_match_id and (m.user_a = u or m.user_b = u);
  if v_other is null then perform public.raise_code('not_found'); end if;
  return v_other;
end $$;

-- Ready to take part in matching at all (profile, terms, preferences).
create function public.matching_ready(u uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (
    select 1 from public.profiles p join public.profile_private q on q.user_id = p.id
     where p.id = u and p.is_complete
       and q.age_confirmed_at is not null and q.terms_version is not null and q.privacy_version is not null
       and q.match_gender is not null and cardinality(q.show_me) > 0)
$$;

-- The single eligibility predicate (design §5.1), used at discovery, interest and match creation.
create function public.can_match(a uuid, b uuid) returns boolean
language sql stable set search_path = public as $$
  select a is not null and b is not null and a <> b
    and public.matching_ready(a) and public.matching_ready(b)
    and exists (
      select 1 from public.participation_sessions sa
        join public.participation_sessions sb
          on sb.space_id = sa.space_id and sb.boundary_version = sa.boundary_version
       where sa.user_id = a and sb.user_id = b
         and sa.lease_expires_at > now() and sb.lease_expires_at > now())
    and exists (
      select 1
        from public.profiles pa join public.profile_private qa on qa.user_id = pa.id,
             public.profiles pb join public.profile_private qb on qb.user_id = pb.id
       where pa.id = a and pb.id = b
         and qb.match_gender = any (qa.show_me) and qa.match_gender = any (qb.show_me)
         and pb.age between qa.age_min and qa.age_max
         and pa.age between qb.age_min and qb.age_max
         and not (public.setting_bool('hide_rejected_photos')
                  and (pa.photo_review_status = 'rejected' or pb.photo_review_status = 'rejected'))
         and (not qa.verified_only_discovery or pb.photo_review_status = 'approved')
         and (not qb.verified_only_discovery or pa.photo_review_status = 'approved'))
    and not public.is_paused(a) and not public.is_paused(b)
    and not public.is_blocked_between(a, b)
$$;

create function public.can_view_profile(viewer uuid, target uuid) returns boolean
language sql stable set search_path = public as $$
  select viewer is not null and target is not null
    and not public.is_blocked_between(viewer, target)
    and (viewer = target or public.can_match(viewer, target) or public.match_between(viewer, target) is not null)
$$;

-- What other users may see. No space, session, timestamps of activity, status or private fields.
create type public.public_profile as (
  id                  uuid,
  first_name          text,
  age                 int,
  pronouns            text,
  gender              text,
  interests           text[],
  vibe_tags           text[],
  prompt_question     text,
  prompt_answer       text,
  intention           public.intention,
  availability        public.availability,
  photo_paths         text[],
  photo_review_status public.review_status
);

create function public.make_public_profile(target uuid) returns public.public_profile
language sql stable set search_path = public as $$
  select row(
    p.id, p.first_name, p.age, p.pronouns, p.gender, p.interests, p.vibe_tags,
    p.prompt_question, p.prompt_answer, p.intention, p.availability,
    case when p.photo_review_status = 'rejected' and public.setting_bool('hide_rejected_photos')
         then '{}'::text[] else p.photo_paths end,
    p.photo_review_status
  )::public.public_profile
  from public.profiles p where p.id = target
$$;

create function public.pref_enabled(u uuid, kind text) returns boolean
language sql stable set search_path = public as $$
  select coalesce((
    select case kind
      when 'new_match'   then np.new_matches
      when 'new_message' then np.messages
      else false end                       -- unknown kinds are never sent
    from public.notification_prefs np where np.user_id = u), kind in ('new_match', 'new_message'))
$$;

-- Re-checked at send time by claim_due_notifications().
create function public.notification_still_relevant(o public.notification_outbox) returns boolean
language plpgsql stable set search_path = public as $$
declare v_match public.matches;
begin
  if o.deliver_after < now() - interval '6 hours' then return false; end if;
  if o.attempts >= 5 then return false; end if;
  if not public.pref_enabled(o.user_id, o.kind) then return false; end if;
  select * into v_match from public.matches m where m.id = (o.payload ->> 'match_id')::uuid;
  if not found then return false; end if;
  if public.is_blocked_between(v_match.user_a, v_match.user_b) then return false; end if;
  return true;
end $$;

-- Deletes a match and everything hanging off it; cancels queued pushes; leaves an id-only tombstone.
create function public.delete_match(p_match_id uuid) returns void
language plpgsql set search_path = public as $$
begin
  update public.notification_outbox o set cancelled_at = now()
   where o.sent_at is null and o.cancelled_at is null and o.payload ->> 'match_id' = p_match_id::text;
  delete from public.matches m where m.id = p_match_id;
  if found then
    insert into public.deletion_tombstones (match_id) values (p_match_id) on conflict do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. RPCs: account state and preferences
-- ---------------------------------------------------------------------------
create function public.my_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); v_prefs public.notification_prefs;
begin
  select * into v_prefs from public.notification_prefs np where np.user_id = v_uid;
  if not found then v_prefs := row(v_uid, true, true)::public.notification_prefs; end if;
  return jsonb_build_object(
    'now',      now(),
    'profile',  (select to_jsonb(p) from public.profiles p where p.id = v_uid),
    'private',  (select to_jsonb(pp) from public.profile_private pp where pp.user_id = v_uid),
    'prefs',    to_jsonb(v_prefs),
    'settings', (select jsonb_object_agg(s.key, s.value) from public.app_settings s)
  );
end $$;

create function public.update_match_preferences(p_match_gender text, p_show_me text[], p_age_min int, p_age_max int)
returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid();
begin
  if p_match_gender is null or p_match_gender not in ('woman', 'man', 'nonbinary')
     or p_show_me is null or cardinality(p_show_me) = 0
     or not (p_show_me <@ array['woman', 'man', 'nonbinary']::text[])
     or p_age_min is null or p_age_max is null
     or p_age_min < 18 or p_age_max > 120 or p_age_min > p_age_max then
    perform public.raise_code('invalid_input');
  end if;
  insert into public.profile_private as q (user_id, match_gender, show_me, age_min, age_max)
  values (v_uid, p_match_gender, array(select distinct x from unnest(p_show_me) x order by 1), p_age_min, p_age_max)
  on conflict (user_id) do update set
    match_gender = excluded.match_gender, show_me = excluded.show_me,
    age_min = excluded.age_min, age_max = excluded.age_max;
end $$;

create function public.update_notification_prefs(p jsonb) returns public.notification_prefs
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); r public.notification_prefs;
begin
  if p is null or jsonb_typeof(p) <> 'object' then perform public.raise_code('invalid_input'); end if;
  insert into public.notification_prefs (user_id) values (v_uid) on conflict (user_id) do nothing;
  begin
    update public.notification_prefs np set
      new_matches = coalesce((p ->> 'new_matches')::boolean, np.new_matches),
      messages    = coalesce((p ->> 'messages')::boolean, np.messages)
    where np.user_id = v_uid
    returning np.* into r;
  exception when others then
    perform public.raise_code('invalid_input');
  end;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 6. RPCs: participation (design §4.2)
-- ---------------------------------------------------------------------------
create function public.my_participation() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); st public.participation_state; s public.participation_sessions;
begin
  insert into public.participation_state (user_id) values (v_uid) on conflict (user_id) do nothing;
  select * into st from public.participation_state where user_id = v_uid;
  s := public.active_session(v_uid);
  return jsonb_build_object(
    'now',             now(),
    'consent_epoch',   st.consent_epoch,
    'matching_paused', public.is_paused(v_uid),
    'paused_until',    case when public.is_paused(v_uid) then st.paused_until end,
    'session',         case when s.id is null then null else jsonb_build_object(
                         'id', s.id,
                         'space_slug', (select cs.slug from public.campus_spaces cs where cs.id = s.space_id),
                         'boundary_version', s.boundary_version,
                         'lease_expires_at', s.lease_expires_at,
                         'last_seq', s.last_seq) end
  );
end $$;

create function public.open_participation(p_space_slug text, p_boundary_version int, p_consent_epoch bigint,
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

  v_fix := public.check_evidence(p_evidence, null, false);   -- entry needs a fresh, moving-or-not real fix

  -- Never transfer consent: whatever existed before (any space) ends now, interests included.
  delete from public.participation_sessions s where s.user_id = v_uid;

  insert into public.participation_sessions as ps
    (user_id, space_id, boundary_version, consent_epoch, client_request_id, lease_expires_at, last_seq, last_fix_ts_ms)
  values (v_uid, sp.id, sp.boundary_version, st.consent_epoch, p_client_request_id,
          now() + make_interval(secs => public.setting_int('participation_lease_seconds')), 0, v_fix)
  returning ps.* into r;

  return jsonb_build_object('session_id', r.id, 'lease_expires_at', r.lease_expires_at, 'now', now());
end $$;

create function public.renew_participation(p_session_id uuid, p_seq bigint, p_evidence jsonb) returns jsonb
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

  v_fix := public.check_evidence(p_evidence, s.last_fix_ts_ms, true);

  v_until := now() + make_interval(secs => public.setting_int('participation_lease_seconds'));
  update public.participation_sessions ps
     set lease_expires_at = v_until, last_seq = p_seq, last_fix_ts_ms = v_fix
   where ps.id = s.id;
  return jsonb_build_object('session_id', s.id, 'lease_expires_at', v_until, 'now', now());
end $$;

-- Go invisible / confirmed exit / sign-out. Idempotent. Returns the new consent epoch.
create function public.revoke_participation() returns bigint
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid();
begin
  perform 1 from public.participation_state where user_id = v_uid for update;
  return public.end_participation(v_uid);
end $$;

create function public.set_matching_paused(p_paused boolean, p_minutes int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); v_epoch bigint;
begin
  if p_paused is null then perform public.raise_code('invalid_input'); end if;
  if p_paused and p_minutes is not null
     and not (coalesce(public.setting_json('pause_durations_minutes'), '[]') @> to_jsonb(p_minutes)) then
    perform public.raise_code('invalid_duration');
  end if;
  insert into public.participation_state (user_id) values (v_uid) on conflict (user_id) do nothing;
  perform 1 from public.participation_state where user_id = v_uid for update;
  if p_paused then
    v_epoch := public.end_participation(v_uid);
    update public.participation_state ps
       set matching_paused = true,
           paused_until = case when p_minutes is null then null else now() + make_interval(mins => p_minutes) end
     where ps.user_id = v_uid;
  else
    -- Resuming never opens a session; the user must be in a space and consent again.
    update public.participation_state ps set matching_paused = false, paused_until = null where ps.user_id = v_uid;
  end if;
  return public.my_participation();
end $$;

-- ---------------------------------------------------------------------------
-- 7. RPCs: discovery, interests, matching (design §5)
-- ---------------------------------------------------------------------------
create function public.discover_candidates() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); s public.participation_sessions; v_pop int; v_profiles jsonb;
begin
  s := public.active_session(v_uid);
  if s.id is null then perform public.raise_code('not_participating'); end if;
  perform public.enforce_rate_limit(v_uid, 'discover');

  select count(*) into v_pop from public.participation_sessions ps
   where ps.space_id = s.space_id and ps.boundary_version = s.boundary_version and ps.lease_expires_at > now();
  if v_pop < public.setting_int('discovery_min_participants') then
    return jsonb_build_object('status', 'quiet', 'profiles', '[]'::jsonb);   -- never an exact count
  end if;

  with picked as (
    select ps.id as session_id, ps.user_id from public.participation_sessions ps
           where ps.space_id = s.space_id and ps.boundary_version = s.boundary_version
             and ps.lease_expires_at > now() and ps.user_id <> v_uid
             and public.match_between(v_uid, ps.user_id) is null
             and public.can_match(v_uid, ps.user_id)
           order by random()                                   -- no stable order to diff between calls
           limit public.setting_int('discovery_max_results')
  ), exposed as (
    insert into public.discovery_exposures (viewer_session_id, target_session_id)
    select s.id, p.session_id from picked p
    on conflict do nothing
  )
  select coalesce(jsonb_agg(to_jsonb(public.make_public_profile(p.user_id))), '[]'::jsonb) into v_profiles
    from picked p;
  return jsonb_build_object('status', 'ok', 'profiles', v_profiles);
end $$;

create function public.express_interest(p_target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_uid();
  me public.participation_sessions;
  them public.participation_sessions;
  v_match uuid;
  v_min int := public.setting_int('receipt_delay_min_seconds');
  v_max int := public.setting_int('receipt_delay_max_seconds');
begin
  if p_target is null or p_target = v_uid then perform public.raise_code('invalid_input'); end if;
  perform public.enforce_rate_limit(v_uid, 'interest');

  -- Serialize the pair, then lock both sessions so a concurrent revoke can't slip between check and insert.
  perform pg_advisory_xact_lock(hashtextextended(least(v_uid, p_target)::text || greatest(v_uid, p_target)::text, 0));
  select * into me from public.participation_sessions ps
   where ps.user_id = v_uid and ps.lease_expires_at > now() for share;
  if me.id is null then perform public.raise_code('not_participating'); end if;
  select * into them from public.participation_sessions ps
   where ps.user_id = p_target and ps.lease_expires_at > now() for share;
  if them.id is null or not public.can_match(v_uid, p_target)
     or not exists (select 1 from public.discovery_exposures x
                     where x.viewer_session_id = me.id and x.target_session_id = them.id) then
    perform public.raise_code('not_available');
  end if;
  if public.match_between(v_uid, p_target) is not null then perform public.raise_code('already_matched'); end if;
  if exists (select 1 from public.interests i
              where i.sender_session_id = me.id and i.recipient_session_id = them.id) then
    perform public.raise_code('already_sent');
  end if;
  if me.interests_sent >= public.setting_int('interests_per_session') then
    perform public.raise_code('limit_reached');
  end if;

  update public.participation_sessions ps set interests_sent = ps.interests_sent + 1 where ps.id = me.id;

  if exists (select 1 from public.interests i
              where i.sender_session_id = them.id and i.recipient_session_id = me.id) then
    insert into public.matches (user_a, user_b) values (least(v_uid, p_target), greatest(v_uid, p_target))
    on conflict (user_a, user_b) do nothing
    returning id into v_match;
    if v_match is null then v_match := public.match_between(v_uid, p_target); end if;
    delete from public.interests i
     where (i.sender_session_id = them.id and i.recipient_session_id = me.id);
    perform public.enqueue_notification(u.uid, 'new_match', 'new_match:' || v_match::text || ':' || u.uid::text,
                                        jsonb_build_object('match_id', v_match), now())
       from (values (v_uid), (p_target)) u(uid);
    return jsonb_build_object('result', 'matched', 'match_id', v_match,
                              'remaining', public.setting_int('interests_per_session') - me.interests_sent - 1);
  end if;

  insert into public.interests (sender_session_id, recipient_session_id, visible_at)
  values (me.id, them.id, now() + make_interval(secs => v_min + floor(random() * (v_max - v_min + 1))::int));
  return jsonb_build_object('result', 'sent', 'match_id', null,
                            'remaining', public.setting_int('interests_per_session') - me.interests_sent - 1);
end $$;

-- How many people in my current visit have anonymously expressed interest (after the random delay).
-- No ids, times or places.
create function public.my_interest_receipts() returns int
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); s public.participation_sessions;
begin
  s := public.active_session(v_uid);
  if s.id is null then return 0; end if;
  return (select count(*) from public.interests i
            join public.participation_sessions snd on snd.id = i.sender_session_id
           where i.recipient_session_id = s.id and i.visible_at <= now()
             and snd.lease_expires_at > now()
             and not public.is_blocked_between(v_uid, snd.user_id));
end $$;

-- Whom I've expressed interest in during my current visit (so the UI can show "sent").
create function public.my_sent_interests() returns uuid[]
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); s public.participation_sessions;
begin
  s := public.active_session(v_uid);
  if s.id is null then return '{}'; end if;
  return coalesce((select array_agg(r.user_id) from public.interests i
                     join public.participation_sessions r on r.id = i.recipient_session_id
                    where i.sender_session_id = s.id and r.lease_expires_at > now()), '{}');
end $$;

-- ---------------------------------------------------------------------------
-- 8. RPCs: conversations (design §6)
-- ---------------------------------------------------------------------------
create function public.my_conversations()
returns table (match_id uuid, created_at timestamptz, other public.public_profile,
               last_message_at timestamptz, last_message_preview text, last_message_from_me boolean, unread boolean)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid();
begin
  return query
  select m.id, m.created_at,
         public.make_public_profile(case when m.user_a = v_uid then m.user_b else m.user_a end),
         lm.created_at, left(lm.body, 80), lm.sender_id = v_uid,
         coalesce(lm.sender_id <> v_uid
                  and lm.created_at > coalesce(case when m.user_a = v_uid then m.last_read_at_a else m.last_read_at_b end,
                                               '-infinity'::timestamptz), false)
    from public.matches m
    left join lateral (select msg.body, msg.created_at, msg.sender_id from public.messages msg
                        where msg.match_id = m.id order by msg.created_at desc, msg.id desc limit 1) lm on true
   where (m.user_a = v_uid or m.user_b = v_uid)
     and not public.is_blocked_between(m.user_a, m.user_b)
   order by coalesce(lm.created_at, m.created_at) desc;
end $$;

create function public.fetch_messages(p_match_id uuid, p_before_created_at timestamptz default null,
                                      p_before_id uuid default null, p_limit int default 50)
returns table (id uuid, sender_is_me boolean, body text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_other uuid;
begin
  v_other := public.match_other(p_match_id, v_uid);
  if public.is_blocked_between(v_uid, v_other) then perform public.raise_code('not_found'); end if;
  if (p_before_created_at is null) <> (p_before_id is null) then perform public.raise_code('invalid_input'); end if;
  return query
  select msg.id, msg.sender_id = v_uid, msg.body, msg.created_at
    from public.messages msg
   where msg.match_id = p_match_id
     and (p_before_created_at is null or (msg.created_at, msg.id) < (p_before_created_at, p_before_id))
   order by msg.created_at desc, msg.id desc
   limit greatest(1, least(coalesce(p_limit, 50), 50));
end $$;

create function public.send_message(p_match_id uuid, p_client_message_id uuid, p_body text)
returns table (id uuid, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_other uuid; v_body text := btrim(p_body); existing public.messages;
begin
  if p_client_message_id is null then perform public.raise_code('invalid_input'); end if;
  v_other := public.match_other(p_match_id, v_uid);
  if public.is_blocked_between(v_uid, v_other) then perform public.raise_code('not_found'); end if;

  -- Retry of a message that already landed: return it, never insert twice.
  select * into existing from public.messages msg where msg.id = p_client_message_id;
  if existing.id is not null then
    if existing.sender_id <> v_uid or existing.match_id <> p_match_id then perform public.raise_code('invalid_input'); end if;
    return query select existing.id, existing.created_at;
    return;
  end if;

  if v_body is null or char_length(v_body) = 0 or char_length(v_body) > public.setting_int('message_max_chars') then
    perform public.raise_code('invalid_input');
  end if;
  perform public.enforce_rate_limit(v_uid, 'message');

  -- Lock the match row: a concurrent leave/delete either waits for us or makes us fail with not_found.
  perform 1 from public.matches m where m.id = p_match_id for share;
  if not found then perform public.raise_code('not_found'); end if;

  insert into public.messages (id, match_id, sender_id, body) values (p_client_message_id, p_match_id, v_uid, v_body);
  -- One generic push per conversation per 2-minute window.
  perform public.enqueue_notification(v_other, 'new_message',
            'new_message:' || p_match_id::text || ':' || v_other::text || ':' || floor(extract(epoch from now()) / 120)::bigint::text,
            jsonb_build_object('match_id', p_match_id), now());
  return query select msg.id, msg.created_at from public.messages msg where msg.id = p_client_message_id;
end $$;

create function public.mark_conversation_read(p_match_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid();
begin
  perform public.match_other(p_match_id, v_uid);
  update public.matches m
     set last_read_at_a = case when m.user_a = v_uid then clock_timestamp() else m.last_read_at_a end,
         last_read_at_b = case when m.user_b = v_uid then clock_timestamp() else m.last_read_at_b end
   where m.id = p_match_id;
end $$;

-- Ends the match and deletes the conversation for both participants.
create function public.leave_conversation(p_match_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid();
begin
  perform public.match_other(p_match_id, v_uid);    -- not_found if not a participant or already gone
  perform public.delete_match(p_match_id);
end $$;

-- ---------------------------------------------------------------------------
-- 9. RPCs: safety
-- ---------------------------------------------------------------------------
create or replace function public.block_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); v_match uuid;
begin
  if target is null or target = v_uid then perform public.raise_code('invalid_input'); end if;
  if not exists (select 1 from auth.users u where u.id = target) then perform public.raise_code('not_found'); end if;
  insert into public.blocks (blocker_id, blocked_id) values (v_uid, target) on conflict do nothing;
  v_match := public.match_between(v_uid, target);
  if v_match is not null then perform public.delete_match(v_match); end if;
  delete from public.interests i
   using public.participation_sessions a, public.participation_sessions b
   where a.user_id = v_uid and b.user_id = target
     and ((i.sender_session_id = a.id and i.recipient_session_id = b.id)
       or (i.sender_session_id = b.id and i.recipient_session_id = a.id));
end $$;

create function public.report_user(target uuid, category public.report_category, details text default null,
                                   evidence_message_ids uuid[] default '{}')
returns uuid
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_id uuid; v_match uuid; v_n int;
begin
  if report_user.target is null or report_user.target = v_uid or report_user.category is null
     or (report_user.details is not null and char_length(report_user.details) > 2000)
     or cardinality(coalesce(report_user.evidence_message_ids, '{}')) > 50 then
    perform public.raise_code('invalid_input');
  end if;
  if not exists (select 1 from auth.users u where u.id = report_user.target) then perform public.raise_code('not_found'); end if;
  perform public.enforce_rate_limit(v_uid, 'report');

  insert into public.reports as r (reporter_id, reported_id, reported_snapshot, category, details, context)
  values (v_uid, report_user.target,
          jsonb_build_object('profile', (select to_jsonb(p) from public.profiles p where p.id = report_user.target),
                             'snapshot_at', now()),
          report_user.category, nullif(btrim(report_user.details), ''), '{}')
  returning r.id into v_id;

  if cardinality(coalesce(report_user.evidence_message_ids, '{}')) > 0 then
    v_match := public.match_between(v_uid, report_user.target);
    -- Only messages from the conversation with this person, and only those the reporter selected.
    insert into public.report_evidence (report_id, message_id, sent_by_reported, body, sent_at, purge_after)
    select v_id, msg.id, msg.sender_id = report_user.target, msg.body, msg.created_at,
           now() + make_interval(days => public.setting_int('report_evidence_retention_days'))
      from public.messages msg
     where msg.match_id = v_match and msg.id = any (report_user.evidence_message_ids);
    get diagnostics v_n = row_count;
    if v_match is null or v_n <> (select count(distinct x) from unnest(report_user.evidence_message_ids) x) then
      perform public.raise_code('invalid_input');
    end if;
  end if;

  perform public.block_user(report_user.target);   -- reporting also blocks and ends the conversation
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Scheduled maintenance (read paths never depend on it)
-- ---------------------------------------------------------------------------
create function public.crushly_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare n_sessions int; n_evidence int; n_tomb int;
begin
  delete from public.participation_sessions s where s.lease_expires_at <= now();    -- interests cascade
  get diagnostics n_sessions = row_count;
  update public.participation_state ps set matching_paused = false, paused_until = null
   where ps.matching_paused and ps.paused_until is not null and ps.paused_until <= now();
  delete from public.report_evidence e where e.purge_after <= now();
  get diagnostics n_evidence = row_count;
  delete from public.deletion_tombstones t
   where t.deleted_at <= now() - make_interval(days => public.setting_int('deletion_tombstone_retention_days'));
  get diagnostics n_tomb = row_count;
  delete from public.rate_limits rl where rl.window_start < now() - interval '2 days';
  delete from public.notification_outbox o
   where (o.sent_at is not null or o.cancelled_at is not null) and coalesce(o.sent_at, o.cancelled_at) < now() - interval '7 days';
  return jsonb_build_object('sessions_expired', n_sessions, 'evidence_purged', n_evidence, 'tombstones_purged', n_tomb);
end $$;

-- ---------------------------------------------------------------------------
-- 11. Function privileges
-- ---------------------------------------------------------------------------
revoke all on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

grant execute on function
  public.server_now(),
  public.my_state(),
  public.upsert_profile(jsonb),
  public.accept_terms(text, text, boolean),
  public.update_match_preferences(text, text[], int, int),
  public.update_notification_prefs(jsonb),
  public.register_device(text, text, text),
  public.unregister_device(text),
  public.track_event(text, jsonb),
  public.my_participation(),
  public.open_participation(text, int, bigint, uuid, jsonb),
  public.renew_participation(uuid, bigint, jsonb),
  public.revoke_participation(),
  public.set_matching_paused(boolean, int),
  public.discover_candidates(),
  public.express_interest(uuid),
  public.my_interest_receipts(),
  public.my_sent_interests(),
  public.my_conversations(),
  public.fetch_messages(uuid, timestamptz, uuid, int),
  public.send_message(uuid, uuid, text),
  public.mark_conversation_read(uuid),
  public.leave_conversation(uuid),
  public.block_user(uuid),
  public.unblock_user(uuid),
  public.my_blocks(),
  public.report_user(uuid, public.report_category, text, uuid[]),
  public.can_view_profile_photo(text)  -- used by the storage.objects read policy
to authenticated;
