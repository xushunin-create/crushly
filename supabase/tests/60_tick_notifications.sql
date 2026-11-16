-- Scheduled cleanup and push relevance. Read paths never depend on the tick (tested in 30/40);
-- the tick only removes data that is already invisible.
begin;
do $$
declare a uuid; b uuid; m uuid; o public.notification_outbox; r jsonb;
begin
  perform tests.make_space('quad');
  a := tests.make_user('ta'); b := tests.make_user('tb');
  perform tests.participate(a, 'quad'); perform tests.participate(b, 'quad');
  perform tests.login(a); perform public.express_interest(b);
  perform tests.logout();

  -- Expired leases and their interests are deleted (no history).
  perform tests.expire(a);
  r := public.crushly_tick();
  perform tests.assert((r->>'sessions_expired')::int = 1, 'tick deletes expired sessions');
  perform tests.assert((select count(*) from public.participation_sessions where user_id = a) = 0, 'no row left for the expired session');
  perform tests.assert((select count(*) from public.interests) = 0, 'interests of an expired session are deleted');

  -- Timed pause ends by itself, without opening a session.
  insert into public.participation_state (user_id, matching_paused, paused_until) values (a, true, now() - interval '1 minute')
  on conflict (user_id) do update set matching_paused = true, paused_until = now() - interval '1 minute';
  perform public.crushly_tick();
  perform tests.assert((select not matching_paused from public.participation_state where user_id = a), 'expired timed pause is cleared');
  perform tests.assert((select count(*) from public.participation_sessions where user_id = a) = 0, 'clearing a pause never opens a session');

  -- Match + message notifications, and relevance after deletion.
  perform tests.participate(a, 'quad'); perform tests.participate(b, 'quad');
  perform tests.login(a); perform public.express_interest(b);
  perform tests.login(b); m := (public.express_interest(a)->>'match_id')::uuid;
  perform public.send_message(m, gen_random_uuid(), 'hi');
  perform tests.logout();
  select * into o from public.notification_outbox where kind = 'new_message' and user_id = a;
  perform tests.assert(public.notification_still_relevant(o), 'message push is relevant while the match exists');
  perform tests.assert(o.payload - 'match_id' = '{}'::jsonb, 'push payload carries only the match id');
  update public.notification_prefs set messages = false where user_id = a;
  insert into public.notification_prefs (user_id, messages) values (a, false) on conflict (user_id) do update set messages = false;
  perform tests.assert(not public.notification_still_relevant(o), 'message push respects the preference');
  update public.notification_prefs set messages = true where user_id = a;
  perform tests.login(a); perform public.leave_conversation(m); perform tests.logout();
  perform tests.assert(not public.notification_still_relevant(o), 'push for a deleted conversation is never sent');
  perform tests.assert(not public.pref_enabled(a, 'anonymous_signal'), 'old notification kinds are never sent');

  -- Retention: evidence and tombstones are purged.
  insert into public.reports (id, reporter_id, reported_id, category) values ('00000000-0000-4000-8000-0000000000aa', a, b, 'spam');
  insert into public.report_evidence (report_id, message_id, sent_by_reported, body, sent_at, purge_after)
  values ('00000000-0000-4000-8000-0000000000aa', gen_random_uuid(), true, 'x', now(), now() - interval '1 second');
  update public.deletion_tombstones set deleted_at = now() - interval '15 days' where match_id = m;
  r := public.crushly_tick();
  perform tests.assert((r->>'evidence_purged')::int = 1, 'report evidence purged after retention');
  perform tests.assert((r->>'tombstones_purged')::int = 1, 'tombstones purged after the backup window');
end $$;
rollback;
