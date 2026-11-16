-- Realtime pokes (docs/CAMPUS_SPACES_DESIGN.md §6.3).
--
-- Each user may join exactly one PRIVATE Broadcast channel, `user:<their auth uid>`, and may only receive on it.
-- The server sends CONTENT-FREE pokes: {"type": "message" | "match" | "conversation_removed", "match_id": <uuid>}.
-- The app then refetches through the participant-checked RPCs (my_conversations, fetch_messages).
--
-- Why content-free: Supabase Realtime evaluates channel authorization when a client subscribes and caches it for the
-- whole connection ("Client access policies are cached for the duration of the connection"; a revoked user "will keep
-- receiving messages until their JWT expires or a new one is sent" — supabase.com/docs/guides/realtime/authorization,
-- read 2026-11-16). So after an unmatch, block or account deletion a still-connected socket could keep receiving on
-- its channel for up to the JWT lifetime. It can only ever learn "something changed", never message text: revocation
-- is enforced at the RPCs, not by trusting channel teardown.
--
-- Deploy notes: in the dashboard, Realtime Settings → turn OFF "Allow public access" so only private channels work.
-- Keep the JWT expiry short (Auth settings). See docs/PRE_LAUNCH_CHECKLIST.md.

-- Receive-only, own channel only. There is deliberately no INSERT policy: clients can't broadcast.
create policy crushly_own_user_channel_receive on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select realtime.topic()) = 'user:' || (select auth.uid())::text
  );

-- Best effort: a realtime failure must never fail the transaction that sends a message or creates/deletes a match.
-- Clients also refetch on launch, foreground and a light poll.
create function public.poke(u uuid, p_type text, p_match_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if u is null or p_type not in ('message', 'match', 'conversation_removed') then return; end if;
  begin
    perform realtime.send(
      payload => jsonb_build_object('type', p_type, 'match_id', p_match_id),
      event   => 'poke',
      topic   => 'user:' || u::text,
      private => true);
  exception when others then
    null;
  end;
end $$;

create function public.poke_on_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_a uuid; v_b uuid;
begin
  select m.user_a, m.user_b into v_a, v_b from public.matches m where m.id = new.match_id;
  perform public.poke(v_a, 'message', new.match_id);
  perform public.poke(v_b, 'message', new.match_id);
  return null;
end $$;

-- Fires for every way a match ends: leave_conversation, block_user / report_user, and account deletion
-- (the auth.users cascade deletes the match row, which fires this row trigger).
create function public.poke_on_match() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform public.poke(new.user_a, 'match', new.id);
    perform public.poke(new.user_b, 'match', new.id);
  else
    perform public.poke(old.user_a, 'conversation_removed', old.id);
    perform public.poke(old.user_b, 'conversation_removed', old.id);
  end if;
  return null;
end $$;

create trigger messages_poke after insert on public.messages
  for each row execute function public.poke_on_message();
create trigger matches_poke after insert or delete on public.matches
  for each row execute function public.poke_on_match();

-- New functions default to EXECUTE for PUBLIC (and Supabase's default privileges); none of these are client RPCs.
revoke all on function public.poke(uuid, text, uuid), public.poke_on_message(), public.poke_on_match()
  from public, anon, authenticated;
grant execute on function public.poke(uuid, text, uuid), public.poke_on_message(), public.poke_on_match() to service_role;
