-- Crushly initial schema. Implements docs/BACKEND_CONTRACT.md.
-- Conventions: every RPC is security definer, search_path = public, granted to
-- `authenticated` only, resolves the caller via auth.uid(), and raises contract
-- errors as `raise exception using errcode = 'P0001', message = '<code>'`.
-- All time checks compare against now(); nothing on a read path depends on
-- crushly_tick() having run.

-- ---------------------------------------------------------------------------
-- 0. Enums
-- ---------------------------------------------------------------------------
create type public.availability as enum ('meet_now', 'connect_later', 'either');
create type public.intention as enum ('something_serious', 'something_casual', 'new_friends', 'figuring_it_out');
create type public.review_status as enum ('pending', 'approved', 'rejected');
create type public.selfie_status as enum ('not_started', 'pending', 'verified', 'rejected');
create type public.space_kind as enum ('place', 'event');
create type public.signal_status as enum ('pending', 'matched', 'expired', 'withdrawn');
create type public.match_kind as enum ('heart_sync', 'crossed_hearts');
create type public.connection_status as enum ('pending_confirmation', 'met_tonight', 'find_later', 'expired', 'removed');
create type public.connection_action_kind as enum ('coffee', 'study_break', 'starter', 'instagram_exchange');
create type public.request_status as enum ('pending', 'accepted', 'declined', 'cancelled', 'timed_out', 'completed');
create type public.report_category as enum ('harassment', 'fake_profile', 'under_18', 'unsafe_behavior', 'hate_speech', 'spam', 'other');
create type public.report_status as enum ('open', 'reviewing', 'actioned', 'dismissed');

-- ---------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------
create table public.app_settings (
  key   text primary key,
  value jsonb not null
);

insert into public.app_settings (key, value) values
  ('allowed_email_domains',            '["usc.edu"]'),
  ('pulse_durations_minutes',          '[30, 60]'),
  ('signals_per_session',              '5'),
  ('signal_validity_hours',            '72'),
  ('encounter_window_hours',           '24'),
  ('receipt_delay_min_seconds',        '120'),
  ('receipt_delay_max_seconds',        '600'),
  ('receipt_time_bucket_minutes',      '15'),
  ('receipt_space_min_crowd',          '5'),
  ('connection_confirm_hours',         '24'),
  ('connection_inactive_days',         '7'),
  ('find_request_timeout_minutes',     '10'),
  ('find_active_minutes',              '30'),
  ('shield_durations_minutes',         '[60, 240, 1440]'),
  ('require_own_pulse_to_view_around', 'true'),
  ('hide_rejected_photos',             'true'),
  -- Not in the contract's seeded list; read only by track_event().
  ('analytics_allowed_events', '["app_open","onboarding_step","onboarding_completed","profile_updated","photo_uploaded","pulse_started","pulse_paused","pulse_resumed","pulse_ended","space_code_entered","around_viewed","profile_viewed","signal_sent","receipt_viewed","match_viewed","connection_status_set","connection_action_sent","connection_action_responded","find_requested","find_responded","shield_entered","shield_exited","user_blocked","user_unblocked","user_reported","notification_opened","notification_prefs_changed","account_deleted"]');

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create table public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  first_name          text check (first_name is null or char_length(first_name) between 1 and 40),
  age                 int  check (age is null or age between 18 and 120),
  pronouns            text check (pronouns is null or char_length(pronouns) <= 40),
  gender              text check (gender is null or char_length(gender) <= 40),
  interests           text[] not null default '{}' check (cardinality(interests) <= 3),
  vibe_tags           text[] not null default '{}' check (cardinality(vibe_tags) <= 5),
  prompt_question     text check (prompt_question is null or char_length(prompt_question) <= 200),
  prompt_answer       text check (prompt_answer is null or char_length(prompt_answer) <= 160),
  intention           public.intention,
  availability        public.availability,
  photo_paths         text[] not null default '{}' check (cardinality(photo_paths) <= 6),
  photo_review_status public.review_status not null default 'pending',
  selfie_status       public.selfie_status not null default 'not_started',
  university_domain   text,
  is_complete         boolean generated always as (
                        coalesce(char_length(btrim(first_name)), 0) > 0
                        and coalesce(age >= 18, false)
                        and cardinality(interests) = 3
                        and intention is not null
                        and availability is not null
                        and cardinality(photo_paths) >= 1
                      ) stored,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table public.profile_private (
  user_id                 uuid primary key references auth.users (id) on delete cascade,
  instagram_handle        text check (instagram_handle is null or instagram_handle ~ '^[A-Za-z0-9._]{1,30}$'),
  age_confirmed_at        timestamptz,
  terms_version           text,
  terms_accepted_at       timestamptz,
  privacy_version         text,
  privacy_accepted_at     timestamptz,
  verified_only_discovery boolean not null default false
);

create table public.campus_spaces (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  kind       public.space_kind not null,
  subtitle   text,
  starts_at  timestamptz,
  ends_at    timestamptz,
  is_active  boolean not null default true,
  sort_order int not null default 0,
  check (ends_at is null or starts_at is null or ends_at > starts_at)
);

create table public.space_codes (
  code     text primary key check (code = upper(code) and char_length(code) between 3 and 32),
  space_id uuid not null references public.campus_spaces (id) on delete cascade
);
create index space_codes_space_idx on public.space_codes (space_id);

create table public.pulse_sessions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  space_id     uuid not null references public.campus_spaces (id) on delete cascade,
  availability public.availability not null,
  started_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  paused_at    timestamptz,
  ended_at     timestamptz,
  end_reason   text check (end_reason in ('user', 'expired', 'shield', 'account')),
  signals_sent int not null default 0 check (signals_sent >= 0),
  check (expires_at > started_at),
  check ((ended_at is null) = (end_reason is null))
);
create unique index pulse_sessions_one_live on public.pulse_sessions (user_id) where ended_at is null;
create index pulse_sessions_space_live on public.pulse_sessions (space_id, expires_at) where ended_at is null;

create table public.encounters (
  viewer_id    uuid not null references auth.users (id) on delete cascade,
  seen_id      uuid not null references auth.users (id) on delete cascade,
  space_id     uuid references public.campus_spaces (id) on delete set null,
  last_seen_at timestamptz not null default now(),
  primary key (viewer_id, seen_id),
  check (viewer_id <> seen_id)
);
create index encounters_seen_idx on public.encounters (seen_id);

create table public.matches (
  id         uuid primary key default gen_random_uuid(),
  user_a     uuid not null references auth.users (id) on delete cascade,
  user_b     uuid not null references auth.users (id) on delete cascade,
  kind       public.match_kind not null,
  space_id   uuid references public.campus_spaces (id) on delete set null,
  created_at timestamptz not null default now(),
  check (user_a < user_b),
  unique (user_a, user_b)
);
create index matches_user_b_idx on public.matches (user_b);

create table public.heart_signals (
  id                uuid primary key default gen_random_uuid(),
  sender_id         uuid not null references auth.users (id) on delete cascade,
  recipient_id      uuid not null references auth.users (id) on delete cascade,
  session_id        uuid references public.pulse_sessions (id) on delete set null,
  space_id          uuid references public.campus_spaces (id) on delete set null,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz not null,
  visible_at        timestamptz not null,
  space_disclosable boolean not null default false,
  status            public.signal_status not null default 'pending',
  match_id          uuid references public.matches (id) on delete set null,
  check (sender_id <> recipient_id)
);
create unique index heart_signals_one_pending on public.heart_signals (sender_id, recipient_id) where status = 'pending';
create index heart_signals_recipient_idx on public.heart_signals (recipient_id, status);
create index heart_signals_expiry_idx on public.heart_signals (expires_at) where status = 'pending';

create table public.connections (
  match_id         uuid primary key references public.matches (id) on delete cascade,
  status           public.connection_status not null default 'pending_confirmation',
  confirm_by       timestamptz not null,
  active_until     timestamptz,
  confirmed_at     timestamptz,
  last_activity_at timestamptz,
  removed_by       uuid references auth.users (id) on delete set null,
  updated_at       timestamptz not null default now()
);

create table public.connection_actions (
  id           uuid primary key default gen_random_uuid(),
  match_id     uuid not null references public.matches (id) on delete cascade,
  actor_id     uuid references auth.users (id) on delete cascade,
  kind         public.connection_action_kind not null,
  payload      jsonb not null default '{}' check (octet_length(payload::text) <= 1024),
  status       public.request_status not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz
);
create unique index connection_actions_one_pending on public.connection_actions (match_id, kind) where status = 'pending';

create table public.find_requests (
  id            uuid primary key default gen_random_uuid(),
  match_id      uuid not null references public.matches (id) on delete cascade,
  requester_id  uuid references auth.users (id) on delete cascade,
  status        public.request_status not null default 'pending',
  meeting_point text check (meeting_point is null or char_length(meeting_point) <= 120),
  created_at    timestamptz not null default now(),
  respond_by    timestamptz not null,
  accepted_at   timestamptz,
  active_until  timestamptz,
  ended_at      timestamptz,
  end_reason    text
);
create unique index find_requests_one_open on public.find_requests (match_id) where status in ('pending', 'accepted');

create table public.blocks (
  blocker_id uuid not null references auth.users (id) on delete cascade,
  blocked_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked_idx on public.blocks (blocked_id);

create table public.shield_states (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  started_at   timestamptz not null default now(),
  active_until timestamptz,
  ended_at     timestamptz
);

create table public.reports (
  id                uuid primary key default gen_random_uuid(),
  reporter_id       uuid references auth.users (id) on delete set null,
  reported_id       uuid references auth.users (id) on delete set null,
  reported_snapshot jsonb,
  category          public.report_category not null,
  details           text check (details is null or char_length(details) <= 2000),
  context           jsonb not null default '{}' check (octet_length(context::text) <= 4096),
  status            public.report_status not null default 'open',
  created_at        timestamptz not null default now(),
  reviewed_at       timestamptz,
  reviewer_note     text
);
create index reports_status_idx on public.reports (status, created_at);

create table public.notification_prefs (
  user_id              uuid primary key references auth.users (id) on delete cascade,
  anonymous_signals    boolean not null default true,
  heart_sync           boolean not null default true,
  crossed_hearts       boolean not null default true,
  find_requests        boolean not null default true,
  connection_reminders boolean not null default true,
  connection_expiry    boolean not null default true,
  pulse_expiry         boolean not null default true,
  campus_events        boolean not null default true,
  signals_muted_until  timestamptz
);

create table public.device_tokens (
  token      text primary key check (char_length(token) between 1 and 512),
  user_id    uuid not null references auth.users (id) on delete cascade,
  platform   text not null default 'ios' check (platform in ('ios')),
  apns_env   text not null check (apns_env in ('sandbox', 'production')),
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);

create table public.notification_outbox (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  kind          text not null,
  dedupe_key    text not null unique,
  payload       jsonb not null default '{}',
  deliver_after timestamptz not null default now(),
  sent_at       timestamptz,
  cancelled_at  timestamptz,
  attempts      int not null default 0
);
create index notification_outbox_due on public.notification_outbox (deliver_after) where sent_at is null and cancelled_at is null;

create table public.analytics_events (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users (id) on delete cascade,
  name       text not null check (name ~ '^[a-z][a-z0-9_]{0,63}$'),
  props      jsonb not null default '{}' check (octet_length(props::text) <= 1024),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3. Helpers (internal; never granted to clients)
-- ---------------------------------------------------------------------------
create function public.setting_json(key text) returns jsonb
language sql stable set search_path = public as $$
  select s.value from public.app_settings s where s.key = setting_json.key
$$;

create function public.setting_int(key text) returns int
language sql stable set search_path = public as $$
  select (public.setting_json(key) #>> '{}')::int
$$;

create function public.setting_bool(key text) returns boolean
language sql stable set search_path = public as $$
  select coalesce((public.setting_json(key) #>> '{}')::boolean, false)
$$;

create function public.require_uid() returns uuid
language plpgsql stable set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;
  return v;
end $$;

create function public.is_blocked_between(a uuid, b uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (
    select 1 from public.blocks bl
    where (bl.blocker_id = a and bl.blocked_id = b) or (bl.blocker_id = b and bl.blocked_id = a)
  )
$$;

create function public.is_shielded(u uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (
    select 1 from public.shield_states s
    where s.user_id = u and s.ended_at is null and (s.active_until is null or s.active_until > now())
  )
$$;

-- The user's live session: not ended, not paused, not expired. NULL if none.
create function public.live_session(u uuid) returns public.pulse_sessions
language sql stable set search_path = public as $$
  select ps.* from public.pulse_sessions ps
  where ps.user_id = u and ps.ended_at is null and ps.paused_at is null and ps.expires_at > now()
  limit 1
$$;

create function public.is_profile_complete(u uuid) returns boolean
language sql stable set search_path = public as $$
  select coalesce((select p.is_complete from public.profiles p where p.id = u), false)
$$;

create function public.is_discoverable_to(viewer uuid, target uuid) returns boolean
language sql stable set search_path = public as $$
  select viewer is not null and target is not null and viewer <> target
    and exists (
      select 1
      from public.profiles vp
      join public.profiles tp on tp.id = target
      left join public.profile_private vpp on vpp.user_id = vp.id
      left join public.profile_private tpp on tpp.user_id = tp.id
      where vp.id = viewer
        and vp.is_complete and tp.is_complete
        and not (tp.photo_review_status = 'rejected' and public.setting_bool('hide_rejected_photos'))
        and (not coalesce(vpp.verified_only_discovery, false) or tp.photo_review_status = 'approved')
        and (not coalesce(tpp.verified_only_discovery, false) or vp.photo_review_status = 'approved')
    )
    and exists (
      select 1
      from public.pulse_sessions vs
      join public.pulse_sessions ts on ts.space_id = vs.space_id
      where vs.user_id = viewer and vs.ended_at is null and vs.paused_at is null and vs.expires_at > now()
        and ts.user_id = target and ts.ended_at is null and ts.paused_at is null and ts.expires_at > now()
    )
    and not public.is_shielded(viewer)
    and not public.is_shielded(target)
    and not public.is_blocked_between(viewer, target)
$$;

create function public.has_recent_encounter(viewer uuid, target uuid) returns boolean
language sql stable set search_path = public as $$
  select exists (
    select 1 from public.encounters e
    where e.viewer_id = viewer and e.seen_id = target
      and e.last_seen_at > now() - make_interval(hours => public.setting_int('encounter_window_hours'))
  )
$$;

create function public.match_between(a uuid, b uuid) returns uuid
language sql stable set search_path = public as $$
  select m.id from public.matches m where m.user_a = least(a, b) and m.user_b = greatest(a, b)
$$;

-- Encounter path additionally requires the target not to be shielded
-- (Shield = invisible); matches stay viewable.
create function public.can_view_profile(viewer uuid, target uuid) returns boolean
language sql stable set search_path = public as $$
  select viewer is not null and target is not null
    and not public.is_blocked_between(viewer, target)
    and (
      viewer = target
      or public.is_discoverable_to(viewer, target)
      or (public.has_recent_encounter(viewer, target) and not public.is_shielded(target))
      or public.match_between(viewer, target) is not null
    )
$$;

-- Storage read policy helper: may the current user read objects in this folder?
create function public.can_view_profile_photo(object_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_folder text := split_part(object_name, '/', 1);
begin
  if auth.uid() is null or v_folder !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  return public.can_view_profile(auth.uid(), v_folder::uuid);
end $$;

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
  photo_review_status public.review_status,
  space_id            uuid,
  space_name          text,
  session_paused      boolean
);

-- Builds the public view of `target`, labelled with `p_space_id` (the space the
-- caller shares / encountered / matched in). Callers are responsible for
-- checking can_view_profile first.
create function public.make_public_profile(target uuid, p_space_id uuid) returns public.public_profile
language sql stable set search_path = public as $$
  select row(
    p.id, p.first_name, p.age, p.pronouns, p.gender, p.interests, p.vibe_tags,
    p.prompt_question, p.prompt_answer, p.intention,
    coalesce(
      (select ps.availability from public.pulse_sessions ps
        where ps.user_id = p.id and ps.ended_at is null and ps.expires_at > now() limit 1),
      p.availability),
    case when p.photo_review_status = 'rejected' and public.setting_bool('hide_rejected_photos')
         then '{}'::text[] else p.photo_paths end,
    p.photo_review_status,
    p_space_id,
    (select cs.name from public.campus_spaces cs where cs.id = p_space_id),
    exists (select 1 from public.pulse_sessions ps
             where ps.user_id = p.id and ps.ended_at is null and ps.expires_at > now()
               and ps.paused_at is not null)
  )::public.public_profile
  from public.profiles p where p.id = target
$$;

-- Read-time status, independent of the tick.
create function public.effective_connection(c public.connections) returns public.connections
language plpgsql stable set search_path = public as $$
begin
  if c.match_id is null then return null; end if;
  if c.status = 'pending_confirmation' and c.confirm_by <= now() then
    c.status := 'expired';
  elsif c.status in ('met_tonight', 'find_later') and c.active_until is not null and c.active_until <= now() then
    c.status := 'expired';
  end if;
  return c;
end $$;

create function public.pref_enabled(u uuid, kind text) returns boolean
language sql stable set search_path = public as $$
  select coalesce((
    select case kind
      when 'anonymous_signal'     then np.anonymous_signals and (np.signals_muted_until is null or np.signals_muted_until <= now())
      when 'heart_sync'           then np.heart_sync
      when 'crossed_hearts'       then np.crossed_hearts
      when 'find_request'         then np.find_requests
      when 'connection_reminder'  then np.connection_reminders
      when 'connection_expired'   then np.connection_expiry
      when 'pulse_expiring'       then np.pulse_expiry
      when 'campus_event'         then np.campus_events
      else true end
    from public.notification_prefs np where np.user_id = u), true)
$$;

create function public.enqueue_notification(u uuid, kind text, dedupe_key text, payload jsonb, deliver_after timestamptz default now())
returns void language plpgsql set search_path = public as $$
begin
  if not public.pref_enabled(u, kind) then return; end if;
  insert into public.notification_outbox (user_id, kind, dedupe_key, payload, deliver_after)
  values (u, kind, dedupe_key, coalesce(payload, '{}'), coalesce(deliver_after, now()))
  on conflict on constraint notification_outbox_dedupe_key_key do nothing;
end $$;

-- Ends open (pending/accepted) find requests involving `u` (optionally only with `other`).
create function public.end_open_finds(u uuid, reason text, other uuid default null) returns void
language sql set search_path = public as $$
  update public.find_requests fr
     set status = 'cancelled', ended_at = now(), end_reason = reason
   where fr.status in ('pending', 'accepted')
     and fr.match_id in (
       select m.id from public.matches m
        where (m.user_a = u or m.user_b = u)
          and (other is null or m.user_a = other or m.user_b = other))
$$;

-- Returns the other participant, or raises not_found if the caller is not one.
create function public.match_other(p_match_id uuid, u uuid) returns uuid
language plpgsql stable set search_path = public as $$
declare v_other uuid;
begin
  select case when m.user_a = u then m.user_b else m.user_a end into v_other
    from public.matches m where m.id = p_match_id and (m.user_a = u or m.user_b = u);
  if v_other is null then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  return v_other;
end $$;

-- Locks and returns the connection for a match the caller may still act on.
create function public.require_open_connection(p_match_id uuid, u uuid) returns public.connections
language plpgsql set search_path = public as $$
declare v_other uuid := public.match_other(p_match_id, u); c public.connections;
begin
  if public.is_blocked_between(u, v_other) then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  select * into c from public.connections where match_id = p_match_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  c := public.effective_connection(c);
  if c.status = 'removed' then
    raise exception using errcode = 'P0001', message = 'not_permitted';
  elsif c.status = 'expired' then
    raise exception using errcode = 'P0001', message = 'request_expired';
  end if;
  return c;
end $$;

-- Records activity on a connection; an accepted action confirms a pending one.
create function public.touch_connection(p_match_id uuid, confirm_as public.connection_status default null) returns void
language sql set search_path = public as $$
  update public.connections c set
    last_activity_at = now(),
    status       = case when c.status = 'pending_confirmation' and confirm_as is not null then confirm_as else c.status end,
    confirmed_at = case when c.status = 'pending_confirmation' and confirm_as is not null then now() else c.confirmed_at end,
    active_until = case when c.status in ('met_tonight', 'find_later') or confirm_as is not null
                        then now() + make_interval(days => public.setting_int('connection_inactive_days'))
                        else c.active_until end,
    updated_at   = now()
  where c.match_id = p_match_id
$$;

-- ---------------------------------------------------------------------------
-- 4. Triggers
-- ---------------------------------------------------------------------------

-- 4.1 Allowed email domains on auth.users (insert and email change).
create function public.enforce_allowed_email_domain() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_domain text := lower(split_part(coalesce(new.email, ''), '@', 2));
begin
  if new.email is null or position('@' in new.email) = 0 or v_domain = ''
     or not exists (
       select 1 from jsonb_array_elements_text(coalesce(public.setting_json('allowed_email_domains'), '[]')) d
        where lower(d) = v_domain) then
    raise exception using errcode = 'P0001', message = 'domain_not_allowed';
  end if;
  return new;
end $$;

create trigger crushly_enforce_email_domain
  before insert or update of email on auth.users
  for each row execute function public.enforce_allowed_email_domain();

-- 4.2 Keep a moderation snapshot on reports about a user who is being deleted.
create function public.snapshot_reported_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.reports r
     set reported_snapshot = coalesce(r.reported_snapshot, '{}'::jsonb)
           || jsonb_build_object('account_deleted_at', now(), 'email', old.email)
   where r.reported_id = old.id;
  return old;
end $$;

create trigger crushly_snapshot_reported_user
  before delete on auth.users
  for each row execute function public.snapshot_reported_user();

-- 4.3 Profiles: server-derived university_domain, protected server-only columns,
-- photo path ownership, photo re-review on change, timestamps.
create function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  -- `role` reflects SET ROLE (PostgREST / tests) and is not changed by security definer.
  v_client boolean := coalesce(current_setting('role', true), 'none') in ('authenticated', 'anon');
  v_path text;
begin
  if tg_op = 'INSERT' then
    new.university_domain := (select lower(split_part(u.email, '@', 2)) from auth.users u where u.id = new.id);
    if v_client then
      new.photo_review_status := 'pending';
      new.selfie_status := 'not_started';
    end if;
    new.created_at := now();
  else
    new.id := old.id;
    new.university_domain := old.university_domain;
    new.created_at := old.created_at;
    if v_client then
      new.photo_review_status := old.photo_review_status;
      new.selfie_status := old.selfie_status;
    end if;
    if new.photo_paths is distinct from old.photo_paths
       and new.photo_review_status is not distinct from old.photo_review_status then
      new.photo_review_status := 'pending';
    end if;
  end if;
  new.updated_at := now();
  foreach v_path in array coalesce(new.photo_paths, '{}') loop
    if v_path is null or v_path !~ ('^' || new.id::text || '/[A-Za-z0-9._-]{1,128}$') then
      raise exception using errcode = 'P0001', message = 'invalid_input';
    end if;
  end loop;
  return new;
end $$;

create trigger profiles_guard
  before insert or update on public.profiles
  for each row execute function public.profiles_guard();

-- ---------------------------------------------------------------------------
-- 5. Row level security and table privileges
-- ---------------------------------------------------------------------------
alter table public.app_settings        enable row level security;
alter table public.profiles            enable row level security;
alter table public.profile_private     enable row level security;
alter table public.campus_spaces       enable row level security;
alter table public.space_codes         enable row level security;
alter table public.pulse_sessions      enable row level security;
alter table public.encounters          enable row level security;
alter table public.heart_signals       enable row level security;
alter table public.matches             enable row level security;
alter table public.connections         enable row level security;
alter table public.connection_actions  enable row level security;
alter table public.find_requests       enable row level security;
alter table public.blocks              enable row level security;
alter table public.shield_states       enable row level security;
alter table public.reports             enable row level security;
alter table public.notification_prefs  enable row level security;
alter table public.device_tokens       enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.analytics_events    enable row level security;

-- Start from nothing (Supabase grants everything to anon/authenticated by default).
revoke all on all tables in schema public from public, anon, authenticated;
grant all on all tables in schema public to service_role;
grant usage on schema public to anon, authenticated, service_role;

grant select on public.app_settings to authenticated;
create policy app_settings_read on public.app_settings for select to authenticated using (true);

grant select on public.profiles to authenticated;
grant insert (id, first_name, age, pronouns, gender, interests, vibe_tags, prompt_question, prompt_answer, intention, availability, photo_paths)
  on public.profiles to authenticated;
grant update (first_name, age, pronouns, gender, interests, vibe_tags, prompt_question, prompt_answer, intention, availability, photo_paths)
  on public.profiles to authenticated;
create policy profiles_owner_select on public.profiles for select to authenticated using (id = auth.uid());
create policy profiles_owner_insert on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_owner_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Terms / age fields are written only by accept_terms().
grant select on public.profile_private to authenticated;
grant insert (user_id, instagram_handle, verified_only_discovery) on public.profile_private to authenticated;
grant update (instagram_handle, verified_only_discovery) on public.profile_private to authenticated;
create policy profile_private_owner_select on public.profile_private for select to authenticated using (user_id = auth.uid());
create policy profile_private_owner_insert on public.profile_private for insert to authenticated with check (user_id = auth.uid());
create policy profile_private_owner_update on public.profile_private for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select on public.campus_spaces to authenticated;
create policy campus_spaces_read on public.campus_spaces for select to authenticated using (is_active);

-- space_codes: no grants, no policies.

grant select on public.pulse_sessions to authenticated;
create policy pulse_sessions_owner_select on public.pulse_sessions for select to authenticated using (user_id = auth.uid());

grant select on public.encounters to authenticated;
create policy encounters_viewer_select on public.encounters for select to authenticated using (viewer_id = auth.uid());

-- heart_signals: sender only. There is deliberately NO policy for recipients.
grant select on public.heart_signals to authenticated;
create policy heart_signals_sender_select on public.heart_signals for select to authenticated using (sender_id = auth.uid());

grant select on public.matches to authenticated;
create policy matches_participant_select on public.matches for select to authenticated
  using (auth.uid() in (user_a, user_b));

grant select on public.connections to authenticated;
create policy connections_participant_select on public.connections for select to authenticated
  using (exists (select 1 from public.matches m where m.id = match_id and auth.uid() in (m.user_a, m.user_b)));

grant select on public.connection_actions to authenticated;
create policy connection_actions_participant_select on public.connection_actions for select to authenticated
  using (exists (select 1 from public.matches m where m.id = match_id and auth.uid() in (m.user_a, m.user_b)));

grant select on public.find_requests to authenticated;
create policy find_requests_participant_select on public.find_requests for select to authenticated
  using (exists (select 1 from public.matches m where m.id = match_id and auth.uid() in (m.user_a, m.user_b)));

grant select, delete on public.blocks to authenticated;
create policy blocks_blocker_select on public.blocks for select to authenticated using (blocker_id = auth.uid());
create policy blocks_blocker_delete on public.blocks for delete to authenticated using (blocker_id = auth.uid());

grant select on public.shield_states to authenticated;
create policy shield_states_owner_select on public.shield_states for select to authenticated using (user_id = auth.uid());

-- reports: no grants, no policies (insert via report_user only).

grant select, insert, update on public.notification_prefs to authenticated;
create policy notification_prefs_owner_select on public.notification_prefs for select to authenticated using (user_id = auth.uid());
create policy notification_prefs_owner_insert on public.notification_prefs for insert to authenticated with check (user_id = auth.uid());
create policy notification_prefs_owner_update on public.notification_prefs for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, delete on public.device_tokens to authenticated;
create policy device_tokens_owner_select on public.device_tokens for select to authenticated using (user_id = auth.uid());
create policy device_tokens_owner_insert on public.device_tokens for insert to authenticated with check (user_id = auth.uid());
create policy device_tokens_owner_delete on public.device_tokens for delete to authenticated using (user_id = auth.uid());

-- notification_outbox, analytics_events: no grants, no policies.

-- ---------------------------------------------------------------------------
-- 6. RPCs
-- ---------------------------------------------------------------------------

create function public.server_now() returns timestamptz
language sql stable security definer set search_path = public as $$ select now() $$;

create function public.my_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_uid();
  v_pulse public.pulse_sessions;
  v_shield public.shield_states;
  v_prefs public.notification_prefs;
begin
  select * into v_pulse from public.pulse_sessions ps where ps.user_id = v_uid and ps.ended_at is null;
  select * into v_shield from public.shield_states s
   where s.user_id = v_uid and s.ended_at is null and (s.active_until is null or s.active_until > now());
  select * into v_prefs from public.notification_prefs np where np.user_id = v_uid;
  if not found then
    v_prefs := row(v_uid, true, true, true, true, true, true, true, true, null)::public.notification_prefs;
  end if;
  return jsonb_build_object(
    'now',      now(),
    'profile',  (select to_jsonb(p) from public.profiles p where p.id = v_uid),
    'private',  (select to_jsonb(pp) from public.profile_private pp where pp.user_id = v_uid),
    'pulse',    case when v_pulse.id is null then null
                     else to_jsonb(v_pulse) || jsonb_build_object('now', now(), 'is_expired', v_pulse.expires_at <= now()) end,
    'shield',   case when v_shield.user_id is null then null else to_jsonb(v_shield) end,
    'prefs',    to_jsonb(v_prefs),
    'settings', (select jsonb_object_agg(s.key, s.value) from public.app_settings s)
  );
end $$;

create function public.upsert_profile(p jsonb) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_uid();
  cur public.profiles;
  v_first text; v_age int; v_pronouns text; v_gender text; v_interests text[]; v_vibes text[];
  v_pq text; v_pa text; v_intention public.intention; v_avail public.availability; v_photos text[];
  r public.profiles;
  v_elem text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  select * into cur from public.profiles where id = v_uid;

  begin
    v_first    := case when p ? 'first_name' then nullif(btrim(p->>'first_name'), '') else cur.first_name end;
    v_age      := case when p ? 'age' then (p->>'age')::int else cur.age end;
    v_pronouns := case when p ? 'pronouns' then nullif(btrim(p->>'pronouns'), '') else cur.pronouns end;
    v_gender   := case when p ? 'gender' then nullif(btrim(p->>'gender'), '') else cur.gender end;
    v_pq       := case when p ? 'prompt_question' then nullif(btrim(p->>'prompt_question'), '') else cur.prompt_question end;
    v_pa       := case when p ? 'prompt_answer' then nullif(btrim(p->>'prompt_answer'), '') else cur.prompt_answer end;
    v_intention := case when p ? 'intention' then (p->>'intention')::public.intention else cur.intention end;
    v_avail    := case when p ? 'availability' then (p->>'availability')::public.availability else cur.availability end;
    if p ? 'interests' then
      if jsonb_typeof(p->'interests') <> 'array' then raise exception 'bad'; end if;
      v_interests := array(select btrim(x) from jsonb_array_elements_text(p->'interests') x);
    else v_interests := coalesce(cur.interests, '{}'); end if;
    if p ? 'vibe_tags' then
      if jsonb_typeof(p->'vibe_tags') <> 'array' then raise exception 'bad'; end if;
      v_vibes := array(select btrim(x) from jsonb_array_elements_text(p->'vibe_tags') x);
    else v_vibes := coalesce(cur.vibe_tags, '{}'); end if;
    if p ? 'photo_paths' then
      if jsonb_typeof(p->'photo_paths') <> 'array' then raise exception 'bad'; end if;
      v_photos := array(select x from jsonb_array_elements_text(p->'photo_paths') x);
    else v_photos := coalesce(cur.photo_paths, '{}'); end if;
  exception when others then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end;

  if (v_first is not null and char_length(v_first) > 40)
     or (v_age is not null and (v_age < 18 or v_age > 120))
     or (v_pronouns is not null and char_length(v_pronouns) > 40)
     or (v_gender is not null and char_length(v_gender) > 40)
     or (v_pq is not null and char_length(v_pq) > 200)
     or (v_pa is not null and char_length(v_pa) > 160)
     or (p ? 'interests' and (cardinality(v_interests) <> 3
         or (select count(distinct lower(x)) from unnest(v_interests) x) <> 3))
     or cardinality(v_vibes) > 5
     or cardinality(v_photos) > 6 then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  foreach v_elem in array v_interests || v_vibes loop
    if v_elem is null or char_length(v_elem) not between 1 and 40 then
      raise exception using errcode = 'P0001', message = 'invalid_input';
    end if;
  end loop;
  -- Photo paths are validated (own folder only) by the profiles_guard trigger.

  insert into public.profiles as pr (id, first_name, age, pronouns, gender, interests, vibe_tags,
                                     prompt_question, prompt_answer, intention, availability, photo_paths)
  values (v_uid, v_first, v_age, v_pronouns, v_gender, v_interests, v_vibes, v_pq, v_pa, v_intention, v_avail, v_photos)
  on conflict (id) do update set
    first_name = excluded.first_name, age = excluded.age, pronouns = excluded.pronouns, gender = excluded.gender,
    interests = excluded.interests, vibe_tags = excluded.vibe_tags, prompt_question = excluded.prompt_question,
    prompt_answer = excluded.prompt_answer, intention = excluded.intention, availability = excluded.availability,
    photo_paths = excluded.photo_paths
  returning pr.* into r;
  return r;
end $$;

create function public.accept_terms(terms_version text, privacy_version text, age_confirmed boolean) returns void
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid();
begin
  if coalesce(accept_terms.age_confirmed, false) is not true
     or nullif(btrim(accept_terms.terms_version), '') is null
     or nullif(btrim(accept_terms.privacy_version), '') is null then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  insert into public.profile_private as pp (user_id, age_confirmed_at, terms_version, terms_accepted_at, privacy_version, privacy_accepted_at)
  values (v_uid, now(), accept_terms.terms_version, now(), accept_terms.privacy_version, now())
  on conflict (user_id) do update set
    age_confirmed_at = coalesce(pp.age_confirmed_at, now()),
    terms_version = excluded.terms_version, terms_accepted_at = now(),
    privacy_version = excluded.privacy_version, privacy_accepted_at = now();
end $$;

create function public.start_pulse(space_id uuid, duration_minutes int, until_event_end boolean, availability public.availability)
returns public.pulse_sessions
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_uid uuid := public.require_uid();
  v_space public.campus_spaces;
  v_expires timestamptz;
  r public.pulse_sessions;
begin
  if not public.is_profile_complete(v_uid) then
    raise exception using errcode = 'P0001', message = 'profile_incomplete';
  end if;
  if not exists (select 1 from public.profile_private pp
                  where pp.user_id = v_uid and pp.terms_accepted_at is not null and pp.age_confirmed_at is not null) then
    raise exception using errcode = 'P0001', message = 'terms_required';
  end if;
  if public.is_shielded(v_uid) then
    raise exception using errcode = 'P0001', message = 'shielded';
  end if;
  if start_pulse.availability is null then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  select * into v_space from public.campus_spaces cs
   where cs.id = start_pulse.space_id and cs.is_active and (cs.ends_at is null or cs.ends_at > now());
  if not found then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  if coalesce(start_pulse.until_event_end, false) then
    if v_space.ends_at is null then
      raise exception using errcode = 'P0001', message = 'invalid_duration';
    end if;
    v_expires := v_space.ends_at;
  else
    if start_pulse.duration_minutes is null
       or not (coalesce(public.setting_json('pulse_durations_minutes'), '[]') @> to_jsonb(start_pulse.duration_minutes)) then
      raise exception using errcode = 'P0001', message = 'invalid_duration';
    end if;
    v_expires := now() + make_interval(mins => start_pulse.duration_minutes);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('pulse:' || v_uid::text, 0));
  if (public.live_session(v_uid)).id is not null then
    raise exception using errcode = 'P0001', message = 'not_permitted';
  end if;
  -- End any paused or stale (expired but un-ticked) session.
  update public.pulse_sessions ps
     set ended_at = now(), end_reason = case when ps.expires_at <= now() then 'expired' else 'user' end
   where ps.user_id = v_uid and ps.ended_at is null;

  insert into public.pulse_sessions as ps (user_id, space_id, availability, started_at, expires_at)
  values (v_uid, start_pulse.space_id, start_pulse.availability, now(), v_expires)
  returning ps.* into r;
  return r;
end $$;

create function public.pause_pulse() returns public.pulse_sessions
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); r public.pulse_sessions;
begin
  select * into r from public.pulse_sessions ps where ps.user_id = v_uid and ps.ended_at is null for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'no_live_session';
  end if;
  if r.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'session_expired';
  end if;
  if r.paused_at is null then
    update public.pulse_sessions ps set paused_at = now() where ps.id = r.id returning ps.* into r;
  end if;
  return r;
end $$;

create function public.resume_pulse() returns public.pulse_sessions
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); r public.pulse_sessions;
begin
  select * into r from public.pulse_sessions ps where ps.user_id = v_uid and ps.ended_at is null for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'no_live_session';
  end if;
  if r.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'session_expired';
  end if;
  if public.is_shielded(v_uid) then
    raise exception using errcode = 'P0001', message = 'shielded';
  end if;
  if r.paused_at is not null then
    update public.pulse_sessions ps set paused_at = null where ps.id = r.id returning ps.* into r;
  end if;
  return r;
end $$;

create function public.end_pulse() returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid();
begin
  update public.pulse_sessions ps
     set ended_at = now(), end_reason = case when ps.expires_at <= now() then 'expired' else 'user' end
   where ps.user_id = v_uid and ps.ended_at is null;
  perform public.end_open_finds(v_uid, 'pulse_ended');
end $$;

create function public.enter_space_code(code text) returns public.campus_spaces
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); r public.campus_spaces;
begin
  select cs.* into r
    from public.space_codes sc join public.campus_spaces cs on cs.id = sc.space_id
   where sc.code = upper(btrim(coalesce(enter_space_code.code, '')))
     and cs.is_active and (cs.ends_at is null or cs.ends_at > now());
  if not found then
    raise exception using errcode = 'P0001', message = 'invalid_code';
  end if;
  return r;
end $$;

create function public.around_profiles() returns setof public.public_profile
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); v_s public.pulse_sessions;
begin
  v_s := public.live_session(v_uid);
  if v_s.id is null then
    if public.setting_bool('require_own_pulse_to_view_around') then
      raise exception using errcode = 'P0001', message = 'no_live_session';
    end if;
    return;
  end if;

  insert into public.encounters as e (viewer_id, seen_id, space_id, last_seen_at)
  select v_uid, ts.user_id, v_s.space_id, now()
    from public.pulse_sessions ts
   where ts.space_id = v_s.space_id and ts.ended_at is null and ts.paused_at is null and ts.expires_at > now()
     and ts.user_id <> v_uid and public.is_discoverable_to(v_uid, ts.user_id)
  on conflict (viewer_id, seen_id) do update set space_id = excluded.space_id, last_seen_at = excluded.last_seen_at;

  return query
  select pp.*
    from public.pulse_sessions ts
    cross join lateral public.make_public_profile(ts.user_id, v_s.space_id) pp
   where ts.space_id = v_s.space_id and ts.ended_at is null and ts.paused_at is null and ts.expires_at > now()
     and ts.user_id <> v_uid and public.is_discoverable_to(v_uid, ts.user_id)
   order by hashtextextended(v_s.id::text || ts.user_id::text, 0);
end $$;

create function public.recent_encounters() returns setof public.public_profile
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid();
begin
  return query
  select pp.*
    from public.encounters e
    cross join lateral public.make_public_profile(e.seen_id, e.space_id) pp
   where e.viewer_id = v_uid
     and e.last_seen_at > now() - make_interval(hours => public.setting_int('encounter_window_hours'))
     and not public.is_discoverable_to(v_uid, e.seen_id)
     and public.can_view_profile(v_uid, e.seen_id)
     and pp.id is not null
   order by e.last_seen_at desc;
end $$;

create function public.send_heart_signal(recipient uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := public.require_uid();
  v_s public.pulse_sessions;
  v_rs public.pulse_sessions;
  v_limit int := public.setting_int('signals_per_session');
  v_signal public.heart_signals;
  v_other public.heart_signals;
  v_match_id uuid;
  v_kind public.match_kind;
  v_space uuid;
  v_crowd int;
  v_delay int;
  v_min int := public.setting_int('receipt_delay_min_seconds');
  v_max int := public.setting_int('receipt_delay_max_seconds');
  v_remaining int;
begin
  -- 1
  if recipient is null then
    raise exception using errcode = 'P0001', message = 'not_available';
  end if;
  if recipient = v_uid then
    raise exception using errcode = 'P0001', message = 'self_signal';
  end if;
  -- 2
  perform pg_advisory_xact_lock(hashtextextended(least(v_uid, recipient)::text || greatest(v_uid, recipient)::text, 0));
  -- 3
  if public.is_shielded(v_uid) then
    raise exception using errcode = 'P0001', message = 'shielded';
  end if;
  select * into v_s from public.pulse_sessions ps
   where ps.user_id = v_uid and ps.ended_at is null and ps.paused_at is null and ps.expires_at > now()
   for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'no_live_session';
  end if;
  if not public.is_profile_complete(v_uid) then
    raise exception using errcode = 'P0001', message = 'profile_incomplete';
  end if;
  if public.is_shielded(recipient) or public.is_blocked_between(v_uid, recipient) then
    raise exception using errcode = 'P0001', message = 'not_available';
  end if;
  -- 4
  if not (public.is_discoverable_to(v_uid, recipient) or public.has_recent_encounter(v_uid, recipient)) then
    raise exception using errcode = 'P0001', message = 'not_available';
  end if;
  -- 5
  if v_s.signals_sent >= v_limit then
    raise exception using errcode = 'P0001', message = 'limit_reached';
  end if;
  -- 6
  update public.heart_signals hs set status = 'expired'
   where hs.sender_id = v_uid and hs.recipient_id = recipient and hs.status = 'pending' and hs.expires_at <= now();
  if exists (select 1 from public.heart_signals hs
              where hs.sender_id = v_uid and hs.recipient_id = recipient and hs.status = 'pending') then
    raise exception using errcode = 'P0001', message = 'already_signaled';
  end if;
  if public.match_between(v_uid, recipient) is not null then
    raise exception using errcode = 'P0001', message = 'already_matched';
  end if;
  -- 7
  select count(*) into v_crowd from public.pulse_sessions ps
   where ps.space_id = v_s.space_id and ps.ended_at is null and ps.paused_at is null and ps.expires_at > now();
  v_delay := v_min + floor(random() * (greatest(v_max - v_min, 0) + 1))::int;
  insert into public.heart_signals as hs (sender_id, recipient_id, session_id, space_id, created_at, expires_at, visible_at, space_disclosable)
  values (v_uid, recipient, v_s.id, v_s.space_id, now(),
          now() + make_interval(hours => public.setting_int('signal_validity_hours')),
          now() + make_interval(secs => v_delay),
          v_crowd >= public.setting_int('receipt_space_min_crowd'))
  returning hs.* into v_signal;
  update public.pulse_sessions ps set signals_sent = ps.signals_sent + 1 where ps.id = v_s.id
  returning v_limit - ps.signals_sent into v_remaining;

  -- 8
  select * into v_other from public.heart_signals hs
   where hs.sender_id = recipient and hs.recipient_id = v_uid and hs.status = 'pending' and hs.expires_at > now()
   for update;
  if found then
    v_rs := public.live_session(recipient);
    if v_rs.id is not null and v_rs.space_id = v_s.space_id then
      v_kind := 'heart_sync';
      v_space := v_s.space_id;
    else
      v_kind := 'crossed_hearts';
      v_space := coalesce(
        (select e.space_id from public.encounters e where e.viewer_id = v_uid and e.seen_id = recipient),
        (select e.space_id from public.encounters e where e.viewer_id = recipient and e.seen_id = v_uid),
        v_other.space_id, v_s.space_id);
    end if;
    insert into public.matches as m (user_a, user_b, kind, space_id)
    values (least(v_uid, recipient), greatest(v_uid, recipient), v_kind, v_space)
    on conflict (user_a, user_b) do nothing
    returning m.id into v_match_id;
    if v_match_id is null then
      v_match_id := public.match_between(v_uid, recipient);
    else
      insert into public.connections (match_id, status, confirm_by, updated_at)
      values (v_match_id, 'pending_confirmation', now() + make_interval(hours => public.setting_int('connection_confirm_hours')), now())
      on conflict (match_id) do nothing;
    end if;
    update public.heart_signals hs set status = 'matched', match_id = v_match_id
     where hs.id in (v_signal.id, v_other.id);
    -- The earlier anonymous receipt notification is superseded by the match.
    update public.notification_outbox o set cancelled_at = now()
     where o.dedupe_key = 'signal:' || v_other.id::text and o.sent_at is null and o.cancelled_at is null;
    perform public.enqueue_notification(v_uid, v_kind::text, 'match:' || v_match_id::text || ':' || v_uid::text,
                                        jsonb_build_object('match_id', v_match_id, 'kind', v_kind));
    perform public.enqueue_notification(recipient, v_kind::text, 'match:' || v_match_id::text || ':' || recipient::text,
                                        jsonb_build_object('match_id', v_match_id, 'kind', v_kind));
    return jsonb_build_object('result', 'matched', 'match_id', v_match_id, 'remaining', v_remaining);
  end if;

  -- 9
  perform public.enqueue_notification(recipient, 'anonymous_signal', 'signal:' || v_signal.id::text,
                                      jsonb_build_object('signal_id', v_signal.id), v_signal.visible_at);
  return jsonb_build_object('result', 'sent', 'match_id', null, 'remaining', v_remaining);
end $$;

create function public.my_signal_receipts()
returns table (id uuid, received_bucket timestamptz, space_name text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_bucket int := public.setting_int('receipt_time_bucket_minutes');
begin
  return query
  select hs.id,
         date_bin(make_interval(mins => v_bucket), hs.created_at, timestamptz '2000-01-01 00:00:00+00'),
         case when hs.space_disclosable then cs.name end
    from public.heart_signals hs
    left join public.campus_spaces cs on cs.id = hs.space_id
   where hs.recipient_id = v_uid
     and hs.status = 'pending'
     and hs.visible_at <= now()
     and hs.expires_at > now()
     and not public.is_blocked_between(v_uid, hs.sender_id)
   order by 2 desc, 1;
end $$;

create function public.my_sent_signals()
returns table (id uuid, recipient public.public_profile, created_at timestamptz, expires_at timestamptz, status public.signal_status)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid();
begin
  return query
  select hs.id,
         public.make_public_profile(hs.recipient_id, hs.space_id),
         hs.created_at,
         hs.expires_at,
         case when hs.status = 'pending' and hs.expires_at <= now() then 'expired'::public.signal_status else hs.status end
    from public.heart_signals hs
   where hs.sender_id = v_uid
     and not public.is_blocked_between(v_uid, hs.recipient_id)
   order by hs.created_at desc;
end $$;

create function public.my_matches()
returns table (match_id uuid, kind public.match_kind, created_at timestamptz, space_name text,
               other public.public_profile, connection public.connections,
               open_find public.find_requests, actions public.connection_actions[])
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid();
begin
  return query
  select m.id,
         m.kind,
         m.created_at,
         (select cs.name from public.campus_spaces cs where cs.id = m.space_id),
         public.make_public_profile(o.other_id, m.space_id),
         public.effective_connection(c),
         (select fr from public.find_requests fr
           where fr.match_id = m.id
             and ((fr.status = 'pending' and fr.respond_by > now())
                  or (fr.status = 'accepted' and fr.active_until > now()))
           order by fr.created_at desc limit 1),
         coalesce((select array_agg(ca order by ca.created_at) from public.connection_actions ca where ca.match_id = m.id),
                  '{}'::public.connection_actions[])
    from public.matches m
    cross join lateral (select case when m.user_a = v_uid then m.user_b else m.user_a end as other_id) o
    left join public.connections c on c.match_id = m.id
   where (m.user_a = v_uid or m.user_b = v_uid)
     and not public.is_blocked_between(m.user_a, m.user_b)
   order by m.created_at desc;
end $$;

create function public.set_connection_status(match_id uuid, status public.connection_status) returns public.connections
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); c public.connections;
begin
  if set_connection_status.status is null or set_connection_status.status not in ('met_tonight', 'find_later', 'removed') then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  c := public.require_open_connection(set_connection_status.match_id, v_uid);
  if set_connection_status.status = 'removed' then
    update public.connections cc set status = 'removed', removed_by = v_uid, updated_at = now()
     where cc.match_id = set_connection_status.match_id returning cc.* into c;
    perform public.end_open_finds(v_uid, 'removed', public.match_other(set_connection_status.match_id, v_uid));
  else
    update public.connections cc set
      status = set_connection_status.status,
      confirmed_at = coalesce(cc.confirmed_at, now()),
      active_until = now() + make_interval(days => public.setting_int('connection_inactive_days')),
      last_activity_at = now(),
      updated_at = now()
     where cc.match_id = set_connection_status.match_id returning cc.* into c;
  end if;
  return c;
end $$;

create function public.send_connection_action(match_id uuid, kind public.connection_action_kind, payload jsonb default '{}')
returns public.connection_actions
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_other uuid; r public.connection_actions;
begin
  if send_connection_action.kind is null
     or (send_connection_action.payload is not null and (jsonb_typeof(send_connection_action.payload) <> 'object'
         or octet_length(send_connection_action.payload::text) > 1024)) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  perform public.require_open_connection(send_connection_action.match_id, v_uid);
  v_other := public.match_other(send_connection_action.match_id, v_uid);
  if exists (select 1 from public.connection_actions ca
              where ca.match_id = send_connection_action.match_id and ca.kind = send_connection_action.kind and ca.status = 'pending') then
    raise exception using errcode = 'P0001', message = 'not_permitted';
  end if;
  insert into public.connection_actions as ca (match_id, actor_id, kind, payload)
  values (send_connection_action.match_id, v_uid, send_connection_action.kind, coalesce(send_connection_action.payload, '{}'))
  returning ca.* into r;
  perform public.touch_connection(send_connection_action.match_id);
  perform public.enqueue_notification(v_other, 'connection_action', 'action:' || r.id::text,
                                      jsonb_build_object('match_id', r.match_id, 'action_id', r.id, 'kind', r.kind));
  return r;
end $$;

create function public.respond_connection_action(action_id uuid, accept boolean) returns public.connection_actions
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); r public.connection_actions;
begin
  select * into r from public.connection_actions ca where ca.id = respond_connection_action.action_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  perform public.require_open_connection(r.match_id, v_uid);
  if r.actor_id = v_uid or r.status <> 'pending' or respond_connection_action.accept is null then
    raise exception using errcode = 'P0001', message = 'not_permitted';
  end if;
  update public.connection_actions ca
     set status = case when respond_connection_action.accept then 'accepted'::public.request_status else 'declined'::public.request_status end,
         responded_at = now()
   where ca.id = r.id returning ca.* into r;
  perform public.touch_connection(r.match_id, case when respond_connection_action.accept then 'find_later'::public.connection_status end);
  return r;
end $$;

create function public.connection_instagram(match_id uuid) returns text
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_other uuid;
begin
  v_other := public.match_other(connection_instagram.match_id, v_uid);
  if public.is_blocked_between(v_uid, v_other) then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  if not exists (select 1 from public.connection_actions ca
                  where ca.match_id = connection_instagram.match_id and ca.kind = 'instagram_exchange' and ca.status = 'accepted') then
    return null;
  end if;
  return (select pp.instagram_handle from public.profile_private pp where pp.user_id = v_other);
end $$;

-- Shared eligibility check for Find Each Other.
create function public.require_find_eligible(u uuid, other uuid) returns void
language plpgsql set search_path = public as $$
begin
  if public.is_shielded(u) then
    raise exception using errcode = 'P0001', message = 'shielded';
  end if;
  if (public.live_session(u)).id is null then
    raise exception using errcode = 'P0001', message = 'no_live_session';
  end if;
  if public.is_shielded(other) or public.is_blocked_between(u, other) or (public.live_session(other)).id is null then
    raise exception using errcode = 'P0001', message = 'not_available';
  end if;
end $$;

create function public.request_find(match_id uuid, meeting_point text) returns public.find_requests
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_other uuid; r public.find_requests;
begin
  if request_find.meeting_point is not null and char_length(request_find.meeting_point) > 120 then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  perform public.require_open_connection(request_find.match_id, v_uid);
  v_other := public.match_other(request_find.match_id, v_uid);
  perform public.require_find_eligible(v_uid, v_other);
  if exists (select 1 from public.find_requests fr
              where fr.match_id = request_find.match_id
                and ((fr.status = 'pending' and fr.respond_by > now()) or (fr.status = 'accepted' and fr.active_until > now()))) then
    raise exception using errcode = 'P0001', message = 'not_permitted';
  end if;
  -- Close stale open rows (past their deadline, not yet ticked) so the partial unique index allows a new one.
  update public.find_requests fr
     set status = case when fr.status = 'pending' then 'timed_out'::public.request_status else 'completed'::public.request_status end,
         ended_at = now(), end_reason = 'expired'
   where fr.match_id = request_find.match_id and fr.status in ('pending', 'accepted');
  insert into public.find_requests as fr (match_id, requester_id, meeting_point, respond_by)
  values (request_find.match_id, v_uid, nullif(btrim(request_find.meeting_point), ''),
          now() + make_interval(mins => public.setting_int('find_request_timeout_minutes')))
  returning fr.* into r;
  perform public.enqueue_notification(v_other, 'find_request', 'find:' || r.id::text,
                                      jsonb_build_object('match_id', r.match_id, 'request_id', r.id), now());
  return r;
end $$;

create function public.respond_find(request_id uuid, accept boolean) returns public.find_requests
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_other uuid; r public.find_requests;
begin
  select * into r from public.find_requests fr where fr.id = respond_find.request_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  v_other := public.match_other(r.match_id, v_uid);
  if public.is_blocked_between(v_uid, v_other) then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  if r.requester_id = v_uid or r.status <> 'pending' or respond_find.accept is null then
    raise exception using errcode = 'P0001', message = 'not_permitted';
  end if;
  if r.respond_by <= now() then
    raise exception using errcode = 'P0001', message = 'request_expired';
  end if;
  if respond_find.accept then
    perform public.require_find_eligible(v_uid, v_other);
    update public.find_requests fr
       set status = 'accepted', accepted_at = now(),
           active_until = now() + make_interval(mins => public.setting_int('find_active_minutes'))
     where fr.id = r.id returning fr.* into r;
  else
    update public.find_requests fr set status = 'declined', ended_at = now(), end_reason = 'declined'
     where fr.id = r.id returning fr.* into r;
  end if;
  return r;
end $$;

create function public.cancel_find(request_id uuid) returns public.find_requests
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); r public.find_requests;
begin
  select * into r from public.find_requests fr where fr.id = cancel_find.request_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  perform public.match_other(r.match_id, v_uid);
  if r.status not in ('pending', 'accepted') then
    raise exception using errcode = 'P0001', message = 'not_permitted';
  end if;
  update public.find_requests fr set status = 'cancelled', ended_at = now(), end_reason = 'cancelled'
   where fr.id = r.id returning fr.* into r;
  return r;
end $$;

create function public.complete_find(request_id uuid) returns public.find_requests
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); r public.find_requests;
begin
  select * into r from public.find_requests fr where fr.id = complete_find.request_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  perform public.match_other(r.match_id, v_uid);
  if r.status <> 'accepted' then
    raise exception using errcode = 'P0001', message = 'not_permitted';
  end if;
  if r.active_until <= now() then
    raise exception using errcode = 'P0001', message = 'request_expired';
  end if;
  update public.find_requests fr set status = 'completed', ended_at = now(), end_reason = 'completed'
   where fr.id = r.id returning fr.* into r;
  perform public.touch_connection(r.match_id, 'met_tonight');
  return r;
end $$;

create function public.enter_shield(duration_minutes int default null) returns public.shield_states
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); r public.shield_states;
begin
  if enter_shield.duration_minutes is not null
     and not (coalesce(public.setting_json('shield_durations_minutes'), '[]') @> to_jsonb(enter_shield.duration_minutes)) then
    raise exception using errcode = 'P0001', message = 'invalid_duration';
  end if;
  insert into public.shield_states as s (user_id, started_at, active_until, ended_at)
  values (v_uid, now(), case when enter_shield.duration_minutes is null then null
                             else now() + make_interval(mins => enter_shield.duration_minutes) end, null)
  on conflict (user_id) do update set started_at = excluded.started_at, active_until = excluded.active_until, ended_at = null
  returning s.* into r;
  update public.pulse_sessions ps set ended_at = now(), end_reason = 'shield'
   where ps.user_id = v_uid and ps.ended_at is null;
  perform public.end_open_finds(v_uid, 'shield');
  return r;
end $$;

create function public.exit_shield() returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid();
begin
  update public.shield_states s set ended_at = now() where s.user_id = v_uid and s.ended_at is null;
end $$;

create function public.block_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid();
begin
  if target is null or target = v_uid then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if not exists (select 1 from auth.users u where u.id = target) then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  insert into public.blocks (blocker_id, blocked_id) values (v_uid, target) on conflict do nothing;
  update public.notification_outbox o set cancelled_at = now()
   where o.sent_at is null and o.cancelled_at is null
     and o.dedupe_key in (
       select 'signal:' || hs.id::text from public.heart_signals hs
        where hs.status = 'pending'
          and ((hs.sender_id = v_uid and hs.recipient_id = target) or (hs.sender_id = target and hs.recipient_id = v_uid)));
  update public.heart_signals hs set status = 'withdrawn'
   where hs.status = 'pending'
     and ((hs.sender_id = v_uid and hs.recipient_id = target) or (hs.sender_id = target and hs.recipient_id = v_uid));
  perform public.end_open_finds(v_uid, 'blocked', target);
end $$;

create function public.unblock_user(target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid();
begin
  delete from public.blocks b where b.blocker_id = v_uid and b.blocked_id = target;
end $$;

create function public.my_blocks() returns table (user_id uuid, first_name text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid();
begin
  return query
  select b.blocked_id, p.first_name, b.created_at
    from public.blocks b left join public.profiles p on p.id = b.blocked_id
   where b.blocker_id = v_uid
   order by b.created_at desc;
end $$;

create function public.report_user(target uuid, category public.report_category, details text default null, context jsonb default '{}')
returns uuid
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_id uuid;
begin
  if report_user.target is null or report_user.target = v_uid or report_user.category is null
     or (report_user.details is not null and char_length(report_user.details) > 2000)
     or (report_user.context is not null and (jsonb_typeof(report_user.context) <> 'object'
         or octet_length(report_user.context::text) > 4096)) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if not exists (select 1 from auth.users u where u.id = report_user.target) then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  insert into public.reports as r (reporter_id, reported_id, reported_snapshot, category, details, context)
  values (v_uid, report_user.target,
          jsonb_build_object('profile', (select to_jsonb(p) from public.profiles p where p.id = report_user.target),
                             'snapshot_at', now()),
          report_user.category, nullif(btrim(report_user.details), ''), coalesce(report_user.context, '{}'))
  returning r.id into v_id;
  perform public.block_user(report_user.target);
  return v_id;
end $$;

create function public.update_notification_prefs(p jsonb) returns public.notification_prefs
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); r public.notification_prefs;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  insert into public.notification_prefs (user_id) values (v_uid) on conflict (user_id) do nothing;
  begin
    update public.notification_prefs np set
      anonymous_signals    = coalesce((p->>'anonymous_signals')::boolean, np.anonymous_signals),
      heart_sync           = coalesce((p->>'heart_sync')::boolean, np.heart_sync),
      crossed_hearts       = coalesce((p->>'crossed_hearts')::boolean, np.crossed_hearts),
      find_requests        = coalesce((p->>'find_requests')::boolean, np.find_requests),
      connection_reminders = coalesce((p->>'connection_reminders')::boolean, np.connection_reminders),
      connection_expiry    = coalesce((p->>'connection_expiry')::boolean, np.connection_expiry),
      pulse_expiry         = coalesce((p->>'pulse_expiry')::boolean, np.pulse_expiry),
      campus_events        = coalesce((p->>'campus_events')::boolean, np.campus_events),
      signals_muted_until  = case when p ? 'signals_muted_until' then (p->>'signals_muted_until')::timestamptz
                                  else np.signals_muted_until end
    where np.user_id = v_uid
    returning np.* into r;
  exception when others then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end;
  return r;
end $$;

create function public.register_device(token text, platform text, apns_env text) returns void
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid();
begin
  if register_device.token is null or char_length(register_device.token) not between 1 and 512
     or coalesce(register_device.platform, 'ios') <> 'ios'
     or register_device.apns_env is null or register_device.apns_env not in ('sandbox', 'production') then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  insert into public.device_tokens as d (token, user_id, platform, apns_env, updated_at)
  values (register_device.token, v_uid, coalesce(register_device.platform, 'ios'), register_device.apns_env, now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform,
                                    apns_env = excluded.apns_env, updated_at = now();
end $$;

create function public.unregister_device(token text) returns void
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid();
begin
  delete from public.device_tokens d where d.token = unregister_device.token and d.user_id = v_uid;
end $$;

create function public.track_event(name text, props jsonb default '{}') returns void
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid();
begin
  if track_event.name is null
     or not (coalesce(public.setting_json('analytics_allowed_events'), '[]') @> to_jsonb(track_event.name))
     or (track_event.props is not null and (jsonb_typeof(track_event.props) <> 'object'
         or octet_length(track_event.props::text) > 1024)) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  insert into public.analytics_events (user_id, name, props) values (v_uid, track_event.name, coalesce(track_event.props, '{}'));
end $$;

-- ---------------------------------------------------------------------------
-- 7. Scheduled maintenance
-- ---------------------------------------------------------------------------
create function public.crushly_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n_sessions int; n_signals int; n_conn int; n_finds int; n_shields int; v_match uuid;
begin
  -- Pulse-expiry reminders (5 minutes before), deduped per session.
  perform public.enqueue_notification(ps.user_id, 'pulse_expiring', 'pulse_expiring:' || ps.id::text,
                                      jsonb_build_object('session_id', ps.id), now())
     from public.pulse_sessions ps
    where ps.ended_at is null and ps.paused_at is null
      and ps.expires_at > now() and ps.expires_at <= now() + interval '5 minutes';

  update public.pulse_sessions ps set ended_at = ps.expires_at, end_reason = 'expired'
   where ps.ended_at is null and ps.expires_at <= now();
  get diagnostics n_sessions = row_count;

  update public.notification_outbox o set cancelled_at = now()
   where o.sent_at is null and o.cancelled_at is null and o.kind = 'anonymous_signal'
     and o.dedupe_key in (select 'signal:' || hs.id::text from public.heart_signals hs
                           where hs.status = 'pending' and hs.expires_at <= now());
  update public.heart_signals hs set status = 'expired' where hs.status = 'pending' and hs.expires_at <= now();
  get diagnostics n_signals = row_count;

  -- Connection reminders at 4 h and 1 h before the relevant deadline.
  perform public.enqueue_notification(u.uid, 'connection_reminder',
            'conn_reminder:' || c.match_id::text || ':' || u.uid::text || ':' || w.label || ':' || extract(epoch from d.deadline)::bigint::text,
            jsonb_build_object('match_id', c.match_id, 'window', w.label), now())
     from public.connections c
     join public.matches m on m.id = c.match_id
     cross join lateral (select case when c.status = 'pending_confirmation' then c.confirm_by
                                     when c.status in ('met_tonight', 'find_later') then c.active_until end as deadline) d
     cross join lateral (values ('4h', interval '4 hours', interval '1 hour'), ('1h', interval '1 hour', interval '0')) w(label, hi, lo)
     cross join lateral (values (m.user_a), (m.user_b)) u(uid)
    where d.deadline is not null and d.deadline > now()
      and d.deadline <= now() + w.hi and d.deadline > now() + w.lo
      and not public.is_blocked_between(m.user_a, m.user_b);

  n_conn := 0;
  for v_match in
    update public.connections c set status = 'expired', updated_at = now()
     where (c.status = 'pending_confirmation' and c.confirm_by <= now())
        or (c.status in ('met_tonight', 'find_later') and c.active_until is not null and c.active_until <= now())
    returning c.match_id
  loop
    n_conn := n_conn + 1;
    perform public.enqueue_notification(u.uid, 'connection_expired', 'conn_expired:' || m.id::text || ':' || u.uid::text,
                                        jsonb_build_object('match_id', m.id), now())
       from public.matches m cross join lateral (values (m.user_a), (m.user_b)) u(uid)
      where m.id = v_match and not public.is_blocked_between(m.user_a, m.user_b);
  end loop;

  update public.find_requests fr
     set status = case when fr.status = 'pending' then 'timed_out'::public.request_status else 'completed'::public.request_status end,
         ended_at = now(), end_reason = 'expired'
   where (fr.status = 'pending' and fr.respond_by <= now())
      or (fr.status = 'accepted' and fr.active_until <= now());
  get diagnostics n_finds = row_count;
  -- Open finds where a participant no longer has a (paused or unpaused) session.
  update public.find_requests fr set status = 'cancelled', ended_at = now(), end_reason = 'pulse_ended'
    from public.matches m
   where m.id = fr.match_id and fr.status in ('pending', 'accepted')
     and (not exists (select 1 from public.pulse_sessions ps where ps.user_id = m.user_a and ps.ended_at is null and ps.expires_at > now())
       or not exists (select 1 from public.pulse_sessions ps where ps.user_id = m.user_b and ps.ended_at is null and ps.expires_at > now()));

  update public.shield_states s set ended_at = s.active_until
   where s.ended_at is null and s.active_until is not null and s.active_until <= now();
  get diagnostics n_shields = row_count;

  return jsonb_build_object('sessions_ended', n_sessions, 'signals_expired', n_signals,
                            'connections_expired', n_conn, 'finds_timed_out', n_finds, 'shields_ended', n_shields);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Function privileges
-- ---------------------------------------------------------------------------
revoke all on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

grant execute on function
  public.server_now(),
  public.my_state(),
  public.upsert_profile(jsonb),
  public.accept_terms(text, text, boolean),
  public.start_pulse(uuid, int, boolean, public.availability),
  public.pause_pulse(),
  public.resume_pulse(),
  public.end_pulse(),
  public.enter_space_code(text),
  public.around_profiles(),
  public.recent_encounters(),
  public.send_heart_signal(uuid),
  public.my_signal_receipts(),
  public.my_sent_signals(),
  public.my_matches(),
  public.set_connection_status(uuid, public.connection_status),
  public.send_connection_action(uuid, public.connection_action_kind, jsonb),
  public.respond_connection_action(uuid, boolean),
  public.connection_instagram(uuid),
  public.request_find(uuid, text),
  public.respond_find(uuid, boolean),
  public.cancel_find(uuid),
  public.complete_find(uuid),
  public.enter_shield(int),
  public.exit_shield(),
  public.block_user(uuid),
  public.unblock_user(uuid),
  public.my_blocks(),
  public.report_user(uuid, public.report_category, text, jsonb),
  public.update_notification_prefs(jsonb),
  public.register_device(text, text, text),
  public.unregister_device(text),
  public.track_event(text, jsonb),
  public.can_view_profile_photo(text)  -- used by storage.objects read policy
to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Storage: private profile-photos bucket, path <user_id>/<file>
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('profile-photos', 'profile-photos', false)
on conflict (id) do nothing;

create policy profile_photos_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'profile-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy profile_photos_owner_update on storage.objects for update to authenticated
  using (bucket_id = 'profile-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'profile-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy profile_photos_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'profile-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy profile_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'profile-photos'
         and ((storage.foldername(name))[1] = auth.uid()::text or public.can_view_profile_photo(name)));

-- ---------------------------------------------------------------------------
-- 10. pg_cron (only where available, e.g. Supabase; skipped on plain Postgres)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      execute 'create extension if not exists pg_cron';
      execute $cron$select cron.schedule('crushly-tick', '* * * * *', 'select public.crushly_tick()')$cron$;
    exception when others then
      raise notice 'pg_cron unavailable (%); schedule public.crushly_tick() manually', sqlerrm;
    end;
  else
    raise notice 'pg_cron not installed; schedule public.crushly_tick() externally';
  end if;
end $$;
