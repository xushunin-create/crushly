-- Chat upgrades and instant, screened profile photos.
--
-- Chat (text only, still no photos or attachments):
--   * Replies: a message can quote an earlier message in the same conversation (`reply_to_id`).
--   * Reactions: one emoji per person per message (`message_reactions`), like a tapback.
--   * Unsend: the sender can delete one of their own messages. The text is erased for both people; a placeholder
--     row stays so the conversation still reads in order ("You unsent a message").
--   * Screenshot notices: the app records a content-free `screenshot` event when someone screenshots an open chat,
--     so the other person sees "<name> took a screenshot".
--   All of it stays behind participant-checked RPCs; clients still have no direct table access. Changes send the
--   same content-free realtime poke as a new message.
--
-- Photos:
--   * New photos go live as soon as the profile is saved: no review queue. The app checks each photo on the phone
--     for nudity/explicit content before uploading (Crushly/Services/Safety/PhotoSafetyCheck.swift). That check
--     runs on the device, so it can't be enforced here; reports and moderators remain the backstop.
--   * Status is derived when photos change: any photo a moderator flagged in `photo_flags` → `rejected`; otherwise
--     at least one photo → `approved`; none → `pending`. A flagged photo can't be put back (`photo_removed`).
--   * Moderators remove photos after a report (docs/MODERATION.md); clients can't read or write `photo_flags`.

-- ---------------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------------
update public.app_settings
   set value = value || '{"reaction": [[60, 60], [1000, 86400]],
                          "unsend": [[30, 60], [300, 86400]],
                          "screenshot": [[6, 60], [100, 86400]]}'::jsonb
 where key = 'rate_limits';

-- ---------------------------------------------------------------------------
-- 2. Messages: kind, reply, unsend
-- ---------------------------------------------------------------------------
alter table public.messages drop constraint if exists messages_body_check;
alter table public.messages
  add column kind        text not null default 'text' check (kind in ('text', 'screenshot')),
  add column reply_to_id uuid references public.messages (id) on delete set null,
  add column deleted_at  timestamptz;
-- Live text messages carry 1–2000 characters; unsent messages and screenshot notices carry none.
alter table public.messages add constraint messages_body_shape check (
  case when kind = 'text' and deleted_at is null then char_length(body) between 1 and 2000 else body = '' end);
alter table public.messages add constraint messages_only_text_unsent check (deleted_at is null or kind = 'text');

create table public.message_reactions (
  message_id uuid not null references public.messages (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  emoji      text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

alter table public.message_reactions enable row level security;
revoke all on public.message_reactions from public, anon, authenticated;
grant all on public.message_reactions to service_role;
-- No grants or policies for clients: reactions are read and written only through the RPCs below.

-- ---------------------------------------------------------------------------
-- 3. Conversation RPCs (replacing the versions in 20261116000000_campus_spaces.sql)
-- ---------------------------------------------------------------------------
drop function public.my_conversations();
create function public.my_conversations()
returns table (match_id uuid, created_at timestamptz, other public.public_profile,
               last_message_at timestamptz, last_message_preview text, last_message_from_me boolean, unread boolean,
               last_message_kind text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid();
begin
  return query
  select m.id, m.created_at,
         public.make_public_profile(case when m.user_a = v_uid then m.user_b else m.user_a end),
         lm.created_at, case when lm.kind = 'text' then left(lm.body, 80) end, lm.sender_id = v_uid,
         coalesce(lm.sender_id <> v_uid
                  and lm.created_at > coalesce(case when m.user_a = v_uid then m.last_read_at_a else m.last_read_at_b end,
                                               '-infinity'::timestamptz), false),
         lm.kind
    from public.matches m
    -- Unsent messages drop out of the preview, so the row shows the message before it.
    left join lateral (select msg.body, msg.created_at, msg.sender_id, msg.kind from public.messages msg
                        where msg.match_id = m.id and msg.deleted_at is null
                        order by msg.created_at desc, msg.id desc limit 1) lm on true
   where (m.user_a = v_uid or m.user_b = v_uid)
     and not public.is_blocked_between(m.user_a, m.user_b)
   order by coalesce(lm.created_at, m.created_at) desc;
end $$;

drop function public.fetch_messages(uuid, timestamptz, uuid, int);
create function public.fetch_messages(p_match_id uuid, p_before_created_at timestamptz default null,
                                      p_before_id uuid default null, p_limit int default 50)
returns table (id uuid, sender_is_me boolean, body text, created_at timestamptz, kind text, deleted boolean,
               reply_to_id uuid, reply_body text, reply_sender_is_me boolean, reply_deleted boolean, reactions jsonb)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_other uuid;
begin
  v_other := public.match_other(p_match_id, v_uid);
  if public.is_blocked_between(v_uid, v_other) then perform public.raise_code('not_found'); end if;
  if (p_before_created_at is null) <> (p_before_id is null) then perform public.raise_code('invalid_input'); end if;
  return query
  select msg.id, msg.sender_id = v_uid, msg.body, msg.created_at, msg.kind, msg.deleted_at is not null,
         rm.id, case when rm.deleted_at is null then left(rm.body, 140) else '' end, rm.sender_id = v_uid,
         rm.deleted_at is not null,
         coalesce((select jsonb_agg(jsonb_build_object('emoji', r.emoji, 'mine', r.user_id = v_uid)
                                    order by r.created_at, r.user_id)
                     from public.message_reactions r where r.message_id = msg.id), '[]'::jsonb)
    from public.messages msg
    left join public.messages rm on rm.id = msg.reply_to_id and rm.match_id = msg.match_id
   where msg.match_id = p_match_id
     and (p_before_created_at is null or (msg.created_at, msg.id) < (p_before_created_at, p_before_id))
   order by msg.created_at desc, msg.id desc
   limit greatest(1, least(coalesce(p_limit, 50), 50));
end $$;

drop function public.send_message(uuid, uuid, text);
-- p_reply_to_id defaults to null, so callers that send three named arguments keep working.
create function public.send_message(p_match_id uuid, p_client_message_id uuid, p_body text, p_reply_to_id uuid default null)
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
  -- A reply can only quote a live text message from this same conversation.
  if p_reply_to_id is not null and not exists (
       select 1 from public.messages rm
        where rm.id = p_reply_to_id and rm.match_id = p_match_id and rm.kind = 'text' and rm.deleted_at is null) then
    perform public.raise_code('invalid_input');
  end if;
  perform public.enforce_rate_limit(v_uid, 'message');

  -- Lock the match row: a concurrent leave/delete either waits for us or makes us fail with not_found.
  perform 1 from public.matches m where m.id = p_match_id for share;
  if not found then perform public.raise_code('not_found'); end if;

  insert into public.messages (id, match_id, sender_id, body, reply_to_id)
  values (p_client_message_id, p_match_id, v_uid, v_body, p_reply_to_id);
  -- One generic push per conversation per 2-minute window.
  perform public.enqueue_notification(v_other, 'new_message',
            'new_message:' || p_match_id::text || ':' || v_other::text || ':' || floor(extract(epoch from now()) / 120)::bigint::text,
            jsonb_build_object('match_id', p_match_id), now());
  return query select msg.id, msg.created_at from public.messages msg where msg.id = p_client_message_id;
end $$;

-- Participant + not-blocked check for a message; returns the row. not_found otherwise (never says which).
create function public.require_visible_message(p_message_id uuid, u uuid) returns public.messages
language plpgsql set search_path = public as $$
declare v_msg public.messages; v_other uuid;
begin
  select * into v_msg from public.messages msg where msg.id = p_message_id;
  if v_msg.id is null then perform public.raise_code('not_found'); end if;
  v_other := public.match_other(v_msg.match_id, u);
  if public.is_blocked_between(u, v_other) then perform public.raise_code('not_found'); end if;
  return v_msg;
end $$;

-- Sets (or with a null/empty emoji, removes) the caller's one reaction on a message.
create function public.react_to_message(p_message_id uuid, p_emoji text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); v_msg public.messages; v_emoji text := nullif(btrim(p_emoji), '');
begin
  v_msg := public.require_visible_message(p_message_id, v_uid);
  if v_msg.kind <> 'text' or v_msg.deleted_at is not null then perform public.raise_code('invalid_input'); end if;
  -- Reactions are emoji, not a side channel for text.
  if v_emoji is not null and (char_length(v_emoji) > 16 or v_emoji ~ '[A-Za-z0-9[:space:]<>]') then
    perform public.raise_code('invalid_input');
  end if;
  perform public.enforce_rate_limit(v_uid, 'reaction');
  if v_emoji is null then
    delete from public.message_reactions r where r.message_id = p_message_id and r.user_id = v_uid;
  else
    insert into public.message_reactions as r (message_id, user_id, emoji) values (p_message_id, v_uid, v_emoji)
    on conflict (message_id, user_id) do update set emoji = excluded.emoji, created_at = now()
     where r.emoji is distinct from excluded.emoji;
  end if;
end $$;

-- Unsend: only the sender, only text. Erases the text and its reactions for both people. Idempotent.
create function public.unsend_message(p_message_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public.require_uid(); v_msg public.messages;
begin
  v_msg := public.require_visible_message(p_message_id, v_uid);
  if v_msg.sender_id <> v_uid then perform public.raise_code('not_found'); end if;
  if v_msg.kind <> 'text' then perform public.raise_code('invalid_input'); end if;
  if v_msg.deleted_at is not null then return; end if;
  perform public.enforce_rate_limit(v_uid, 'unsend');
  delete from public.message_reactions r where r.message_id = p_message_id;
  update public.messages msg set body = '', deleted_at = clock_timestamp() where msg.id = p_message_id;
end $$;

-- "<name> took a screenshot". Content-free. A burst of screenshots within 10 s is recorded once.
create function public.record_screenshot(p_match_id uuid)
returns table (id uuid, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_uid uuid := public.require_uid(); v_other uuid; v_recent public.messages;
begin
  v_other := public.match_other(p_match_id, v_uid);
  if public.is_blocked_between(v_uid, v_other) then perform public.raise_code('not_found'); end if;
  select * into v_recent from public.messages msg
   where msg.match_id = p_match_id and msg.sender_id = v_uid and msg.kind = 'screenshot'
     and msg.created_at > clock_timestamp() - interval '10 seconds'
   order by msg.created_at desc limit 1;
  if v_recent.id is not null then
    return query select v_recent.id, v_recent.created_at;
    return;
  end if;
  perform public.enforce_rate_limit(v_uid, 'screenshot');
  perform 1 from public.matches m where m.id = p_match_id for share;
  if not found then perform public.raise_code('not_found'); end if;
  insert into public.messages as msg (id, match_id, sender_id, body, kind)
  values (gen_random_uuid(), p_match_id, v_uid, '', 'screenshot')
  returning msg.* into v_recent;
  return query select v_recent.id, v_recent.created_at;
end $$;

-- Report evidence: only live text messages can be submitted.
create or replace function public.report_user(target uuid, category public.report_category, details text default null,
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
     where msg.match_id = v_match and msg.id = any (report_user.evidence_message_ids)
       and msg.kind = 'text' and msg.deleted_at is null;
    get diagnostics v_n = row_count;
    if v_match is null or v_n <> (select count(distinct x) from unnest(report_user.evidence_message_ids) x) then
      perform public.raise_code('invalid_input');
    end if;
  end if;

  perform public.block_user(report_user.target);   -- reporting also blocks and ends the conversation
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Realtime: unsends and reactions poke like a new message (content-free)
-- ---------------------------------------------------------------------------
create trigger messages_poke_unsend after update of deleted_at on public.messages
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function public.poke_on_message();

create function public.poke_on_reaction() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_match uuid; v_a uuid; v_b uuid;
begin
  select msg.match_id into v_match from public.messages msg
   where msg.id = case when tg_op = 'DELETE' then old.message_id else new.message_id end;
  if v_match is null then return null; end if;      -- the message (and match) is being deleted
  select m.user_a, m.user_b into v_a, v_b from public.matches m where m.id = v_match;
  perform public.poke(v_a, 'message', v_match);
  perform public.poke(v_b, 'message', v_match);
  return null;
end $$;

create trigger message_reactions_poke after insert or update or delete on public.message_reactions
  for each row execute function public.poke_on_reaction();

-- ---------------------------------------------------------------------------
-- 5. Photos: live immediately; moderator removals stick
-- ---------------------------------------------------------------------------
create table public.photo_flags (
  path       text primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  reason     text,
  flagged_at timestamptz not null default now()
);
create index photo_flags_user_idx on public.photo_flags (user_id);

alter table public.photo_flags enable row level security;
revoke all on public.photo_flags from public, anon, authenticated;
grant all on public.photo_flags to service_role;

-- Same as the 20261110000000_init.sql version, except how photo changes are handled (see header).
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  -- `role` reflects SET ROLE (PostgREST / tests) and is not changed by security definer.
  v_client boolean := coalesce(current_setting('role', true), 'none') in ('authenticated', 'anon');
  v_path text;
  v_old_paths text[] := '{}';
  v_changed boolean;
  v_total int; v_flagged int;
begin
  if tg_op = 'INSERT' then
    new.university_domain := (select lower(split_part(u.email, '@', 2)) from auth.users u where u.id = new.id);
    if v_client then
      new.photo_review_status := 'pending';
      new.selfie_status := 'not_started';
    end if;
    new.created_at := now();
    -- upsert_profile's INSERT … ON CONFLICT fires this BEFORE INSERT pass even when the row exists, so compare with
    -- the photos the user already has.
    v_old_paths := coalesce((select pr.photo_paths from public.profiles pr where pr.id = new.id), '{}');
    v_changed := v_client and coalesce(new.photo_paths, '{}') is distinct from v_old_paths;
  else
    new.id := old.id;
    new.university_domain := old.university_domain;
    new.created_at := old.created_at;
    v_old_paths := coalesce(old.photo_paths, '{}');
    if v_client then
      new.photo_review_status := old.photo_review_status;
      new.selfie_status := old.selfie_status;
    end if;
    -- A moderator who sets the status explicitly keeps it.
    v_changed := new.photo_paths is distinct from old.photo_paths
                 and new.photo_review_status is not distinct from old.photo_review_status;
  end if;
  new.updated_at := now();
  foreach v_path in array coalesce(new.photo_paths, '{}') loop
    if v_path is null or v_path !~ ('^' || new.id::text || '/[A-Za-z0-9._-]{1,128}$') then
      raise exception using errcode = 'P0001', message = 'invalid_input';
    end if;
    -- A photo a moderator removed can't be put back.
    if v_client and not (v_path = any (v_old_paths))
       and exists (select 1 from public.photo_flags pf where pf.path = v_path and pf.user_id = new.id) then
      raise exception using errcode = 'P0001', message = 'photo_removed';
    end if;
  end loop;
  if v_changed then
    select count(*), count(pf.path) into v_total, v_flagged
      from unnest(coalesce(new.photo_paths, '{}')) x(path)
      left join public.photo_flags pf on pf.path = x.path and pf.user_id = new.id;
    new.photo_review_status := case when v_flagged > 0 then 'rejected'
                                    when v_total > 0 then 'approved'
                                    else 'pending' end;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Function privileges
-- ---------------------------------------------------------------------------
revoke all on function
  public.my_conversations(),
  public.fetch_messages(uuid, timestamptz, uuid, int),
  public.send_message(uuid, uuid, text, uuid),
  public.require_visible_message(uuid, uuid),
  public.react_to_message(uuid, text),
  public.unsend_message(uuid),
  public.record_screenshot(uuid),
  public.poke_on_reaction()
from public, anon, authenticated;
grant execute on function
  public.my_conversations(),
  public.fetch_messages(uuid, timestamptz, uuid, int),
  public.send_message(uuid, uuid, text, uuid),
  public.require_visible_message(uuid, uuid),
  public.react_to_message(uuid, text),
  public.unsend_message(uuid),
  public.record_screenshot(uuid),
  public.poke_on_reaction()
to service_role;
grant execute on function
  public.my_conversations(),
  public.fetch_messages(uuid, timestamptz, uuid, int),
  public.send_message(uuid, uuid, text, uuid),
  public.react_to_message(uuid, text),
  public.unsend_message(uuid),
  public.record_screenshot(uuid)
to authenticated;
