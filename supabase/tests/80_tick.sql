begin;
do $$
declare a uuid; b uuid; c uuid; v_match uuid; res jsonb; t jsonb; fr public.find_requests;
begin
  a := tests.make_user('ta'); b := tests.make_user('tb'); c := tests.make_user('tc');
  perform tests.pulse(a, 'Leavey Library'); perform tests.pulse(b, 'Leavey Library'); perform tests.pulse(c, 'Leavey Library');
  perform tests.login(a); perform public.send_heart_signal(c);
  perform public.send_heart_signal(b);
  perform tests.login(b); res := public.send_heart_signal(a); v_match := (res->>'match_id')::uuid;
  fr := public.request_find(v_match, 'lobby');
  perform tests.login(c); perform public.enter_shield(60);
  perform tests.logout();

  -- Make everything overdue.
  update public.pulse_sessions set started_at = now() - interval '2 hours', expires_at = now() - interval '1 minute' where user_id = a;
  update public.heart_signals set created_at = now() - interval '73 hours', expires_at = now() - interval '1 hour' where recipient_id = c;
  update public.find_requests set created_at = now() - interval '11 minutes', respond_by = now() - interval '1 minute' where id = fr.id;
  update public.connections set confirm_by = now() + interval '3 hours' where match_id = v_match;
  update public.shield_states set started_at = now() - interval '2 hours', active_until = now() - interval '1 minute' where user_id = c;

  t := public.crushly_tick();
  perform tests.assert((select end_reason from public.pulse_sessions where user_id = a) = 'expired', 'tick ends expired session');
  perform tests.assert((select status from public.heart_signals where recipient_id = c) = 'expired', 'tick expires signal');
  perform tests.assert((select status from public.find_requests where id = fr.id) = 'timed_out', 'tick times out find request');
  perform tests.assert((select ended_at from public.shield_states where user_id = c) is not null, 'tick ends expired shield');
  perform tests.assert((select count(*) from public.notification_outbox where kind = 'connection_reminder') = 2, '4h reminder for both');
  perform public.crushly_tick();
  perform tests.assert((select count(*) from public.notification_outbox where kind = 'connection_reminder') = 2, 'reminders deduped');

  update public.connections set confirm_by = now() - interval '1 second' where match_id = v_match;
  perform tests.login(a);
  perform tests.assert((select (connection).status from public.my_matches()) = 'expired', 'connection reads as expired before tick');
  perform tests.expect_error(format($q$select public.set_connection_status(%L, 'met_tonight')$q$, v_match), 'request_expired', 'cannot confirm after deadline');
  perform tests.logout();
  t := public.crushly_tick();
  perform tests.assert((select status from public.connections where match_id = v_match) = 'expired' and (t->>'connections_expired')::int = 1, 'tick expires connection');
  perform tests.assert((select count(*) from public.notification_outbox where kind = 'connection_expired') = 2, 'expiry notification for both');

  -- Notification prefs are respected.
  perform tests.login(c);
  perform public.update_notification_prefs('{"anonymous_signals": false}');
  perform tests.expect_error($q$select public.update_notification_prefs('{"heart_sync": "maybe"}')$q$, 'invalid_input', 'bad pref value');
  perform public.exit_shield();
  perform tests.pulse(c, 'Leavey Library');
  perform tests.login(b);
  perform tests.assert((public.send_heart_signal(c))->>'result' = 'sent', 'B -> C sent');
  perform tests.logout();
  perform tests.assert((select count(*) from public.notification_outbox where user_id = c and kind = 'anonymous_signal'
                           and payload->>'signal_id' in (select id::text from public.heart_signals where sender_id = b and recipient_id = c)) = 0,
                       'no anonymous_signal notification when pref disabled');
  perform tests.assert((select count(*) from public.notification_outbox where user_id = b and kind = 'heart_sync') = 1,
                       'heart_sync notification queued when pref enabled');
end $$;
rollback;
