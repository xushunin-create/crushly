-- Phase 7: push delivery support.
--  * "Your meet request was accepted" notification.
--  * Preference mapping for every queued kind.
--  * Dispatcher API (service role only): claim due notifications with a send-time relevance re-check,
--    mark them sent, forget dead device tokens.
-- Lock-screen copy lives in supabase/functions/push-dispatch and is deliberately discreet.

-- 1. Preferences for every kind ------------------------------------------------------------------

create or replace function public.pref_enabled(u uuid, kind text) returns boolean
language sql stable set search_path = public as $$
  select coalesce((
    select case kind
      when 'anonymous_signal'     then np.anonymous_signals and (np.signals_muted_until is null or np.signals_muted_until <= now())
      when 'heart_sync'           then np.heart_sync
      when 'crossed_hearts'       then np.crossed_hearts
      when 'find_request'         then np.find_requests
      when 'find_accepted'        then np.find_requests
      when 'connection_action'    then np.connection_reminders
      when 'connection_reminder'  then np.connection_reminders
      when 'connection_expired'   then np.connection_expiry
      when 'pulse_expiring'       then np.pulse_expiry
      when 'campus_event'         then np.campus_events
      else false end                       -- unknown kinds are never sent
    from public.notification_prefs np where np.user_id = u), kind in (
      'anonymous_signal', 'heart_sync', 'crossed_hearts', 'find_request', 'find_accepted', 'connection_action',
      'connection_reminder', 'connection_expired', 'pulse_expiring', 'campus_event'))
$$;

-- 2. Find request accepted -------------------------------------------------------------------------

create function public.notify_find_accepted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'pending' and new.status = 'accepted' and new.requester_id is not null then
    perform public.enqueue_notification(new.requester_id, 'find_accepted', 'find_accepted:' || new.id::text,
                                        jsonb_build_object('match_id', new.match_id, 'request_id', new.id), now());
  end if;
  return new;
end $$;

create trigger crushly_notify_find_accepted
  after update of status on public.find_requests
  for each row execute function public.notify_find_accepted();

-- 3. Dispatcher API ------------------------------------------------------------------------------------

-- Is a queued notification still worth sending? Re-checked at send time so that blocks, Shield,
-- preference changes, matches and expiry since queueing are respected.
create function public.notification_still_relevant(o public.notification_outbox) returns boolean
language plpgsql stable set search_path = public as $$
declare v_match public.matches; v_other uuid;
begin
  if o.deliver_after < now() - interval '6 hours' then return false; end if;      -- outdated
  if o.attempts >= 5 then return false; end if;
  if not public.pref_enabled(o.user_id, o.kind) then return false; end if;

  if o.kind = 'anonymous_signal' then
    return exists (
      select 1 from public.heart_signals hs
       where hs.id = (o.payload->>'signal_id')::uuid
         and hs.status = 'pending' and hs.expires_at > now()
         and not public.is_blocked_between(hs.sender_id, hs.recipient_id))
      and not public.is_shielded(o.user_id);
  end if;

  if o.kind = 'pulse_expiring' then
    return exists (select 1 from public.pulse_sessions ps
                    where ps.id = (o.payload->>'session_id')::uuid and ps.ended_at is null and ps.expires_at > now());
  end if;

  if o.payload ? 'match_id' then
    select * into v_match from public.matches m where m.id = (o.payload->>'match_id')::uuid;
    if not found then return false; end if;
    v_other := case when v_match.user_a = o.user_id then v_match.user_b else v_match.user_a end;
    if public.is_blocked_between(o.user_id, v_other) then return false; end if;
    if exists (select 1 from public.connections c where c.match_id = v_match.id and c.status = 'removed') then
      return false;
    end if;
    if o.kind = 'find_request' then
      return exists (select 1 from public.find_requests fr
                      where fr.id = (o.payload->>'request_id')::uuid and fr.status = 'pending' and fr.respond_by > now());
    end if;
    if o.kind = 'connection_action' then
      return exists (select 1 from public.connection_actions ca
                      where ca.id = (o.payload->>'action_id')::uuid and ca.status = 'pending');
    end if;
  end if;

  return true;
end $$;

-- Claims up to p_limit due notifications (skipping rows another dispatcher holds), cancels stale ones,
-- and returns each with the recipient's device tokens. Increments attempts so a crashed run retries
-- at most 5 times.
create function public.claim_due_notifications(p_limit int default 100)
returns table (id uuid, user_id uuid, kind text, payload jsonb, tokens jsonb)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with due as (
    select o.* from public.notification_outbox o
     where o.sent_at is null and o.cancelled_at is null and o.deliver_after <= now()
     order by o.deliver_after
     limit greatest(1, least(p_limit, 500))
     for update skip locked
  ), judged as (
    select d.*, public.notification_still_relevant(d::public.notification_outbox) as ok,
           (select coalesce(jsonb_agg(jsonb_build_object('token', t.token, 'apns_env', t.apns_env)), '[]'::jsonb)
              from public.device_tokens t where t.user_id = d.user_id) as toks
      from due d
  ), cancelled as (
    update public.notification_outbox o set cancelled_at = now()
      from judged j where o.id = j.id and (not j.ok or j.toks = '[]'::jsonb)
    returning o.id
  ), claimed as (
    update public.notification_outbox o set attempts = o.attempts + 1
      from judged j where o.id = j.id and j.ok and j.toks <> '[]'::jsonb
    returning o.id
  )
  select j.id, j.user_id, j.kind, j.payload, j.toks
    from judged j join claimed c on c.id = j.id;
end $$;

create function public.mark_notifications_sent(ids uuid[]) returns void
language sql security definer set search_path = public as $$
  update public.notification_outbox set sent_at = now() where id = any(ids) and sent_at is null;
$$;

-- APNs said the token is dead (410 Unregistered / BadDeviceToken).
create function public.forget_device_token(p_token text) returns void
language sql security definer set search_path = public as $$
  delete from public.device_tokens where token = p_token;
$$;

revoke all on function public.notification_still_relevant(public.notification_outbox) from public, anon, authenticated;
revoke all on function public.claim_due_notifications(int) from public, anon, authenticated;
revoke all on function public.mark_notifications_sent(uuid[]) from public, anon, authenticated;
revoke all on function public.forget_device_token(text) from public, anon, authenticated;
revoke all on function public.notify_find_accepted() from public, anon, authenticated;
grant execute on function public.claim_due_notifications(int) to service_role;
grant execute on function public.mark_notifications_sent(uuid[]) to service_role;
grant execute on function public.forget_device_token(text) to service_role;
