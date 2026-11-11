begin;
do $$
declare a uuid; b uuid; v_match uuid; act public.connection_actions; fr public.find_requests; res jsonb;
begin
  a := tests.make_user('a'); b := tests.make_user('b');
  perform tests.pulse(a, 'Leavey Library'); perform tests.pulse(b, 'Leavey Library');
  perform tests.login(a); perform public.send_heart_signal(b);
  perform tests.login(b); res := public.send_heart_signal(a); v_match := (res->>'match_id')::uuid;

  -- Connection actions.
  perform tests.login(a);
  act := public.send_connection_action(v_match, 'coffee', '{}');
  perform tests.assert(act.status = 'pending' and act.actor_id = a, 'action created pending');
  perform tests.expect_error(format($q$select public.send_connection_action(%L, 'coffee', '{}')$q$, v_match), 'not_permitted', 'one pending action per kind');
  perform tests.expect_error(format('select public.respond_connection_action(%L, true)', act.id), 'not_permitted', 'actor cannot answer own action');
  perform tests.login(b);
  act := public.respond_connection_action(act.id, true);
  perform tests.assert(act.status = 'accepted', 'action accepted');
  perform tests.assert((select (connection).status from public.my_matches()) = 'find_later', 'accepted action confirms connection');

  -- Instagram exchange.
  perform tests.logout();
  update public.profile_private set instagram_handle = 'bob.ig' where user_id = b;
  perform tests.login(a);
  perform tests.assert(public.connection_instagram(v_match) is null, 'no handle before exchange accepted');
  act := public.send_connection_action(v_match, 'instagram_exchange', '{}');
  perform tests.login(b); perform public.respond_connection_action(act.id, true);
  perform tests.login(a);
  perform tests.assert(public.connection_instagram(v_match) = 'bob.ig', 'handle after exchange accepted');

  -- Find Each Other.
  fr := public.request_find(v_match, 'Front desk');
  perform tests.assert(fr.status = 'pending' and fr.respond_by = now() + interval '10 minutes', 'find request pending, 10 min');
  perform tests.expect_error(format($q$select public.request_find(%L, 'x')$q$, v_match), 'not_permitted', 'one open find per match');
  perform tests.login(b);
  fr := public.respond_find(fr.id, true);
  perform tests.assert(fr.status = 'accepted' and fr.active_until = now() + interval '30 minutes', 'accepted, active 30 min');
  perform tests.assert((select (open_find).id from public.my_matches()) = fr.id, 'open_find exposed in my_matches');
  perform public.end_pulse();
  perform tests.assert((select status from public.find_requests where id = fr.id) = 'cancelled', 'ending Pulse ends find');
  perform tests.login(a);
  perform tests.expect_error(format($q$select public.request_find(%L, 'x')$q$, v_match), 'not_available', 'other has no live session');

  -- Removal.
  perform public.set_connection_status(v_match, 'removed');
  perform tests.expect_error(format($q$select public.send_connection_action(%L, 'coffee', '{}')$q$, v_match), 'not_permitted', 'removed connection is closed');
  perform tests.expect_error(format('select public.send_heart_signal(%L)', b), 'not_available', 'matched pair, recipient not discoverable -> not_available');
end $$;
rollback;
