begin;
do $$
declare a uuid; b uuid; c uuid; d uuid; res jsonb; res2 jsonb; v_match uuid; m record; c_row public.connections;
begin
  a := tests.make_user('a'); b := tests.make_user('b'); c := tests.make_user('c'); d := tests.make_user('d');
  perform tests.pulse(a, 'Leavey Library'); perform tests.pulse(b, 'Leavey Library');

  -- Heart Sync: both live in the same space.
  perform tests.login(a); res := public.send_heart_signal(b);
  perform tests.login(b); res2 := public.send_heart_signal(a);
  perform tests.assert(res->>'result' = 'sent' and res2->>'result' = 'matched' and res2->>'match_id' is not null,
                       'reciprocal signal returns matched with match_id');
  v_match := (res2->>'match_id')::uuid;
  perform tests.logout();
  perform tests.assert((select count(*) from public.matches) = 1, 'exactly one match');
  perform tests.assert((select kind from public.matches where id = v_match) = 'heart_sync', 'same space, both live -> heart_sync');
  perform tests.assert((select user_a < user_b from public.matches where id = v_match), 'user_a < user_b');
  perform tests.assert((select count(*) from public.connections where match_id = v_match and status = 'pending_confirmation'
                        and confirm_by = now() + interval '24 hours') = 1, 'exactly one connection, confirm_by +24h');
  perform tests.assert((select count(*) from public.heart_signals where status = 'matched' and match_id = v_match) = 2,
                       'both signals marked matched with match_id');
  perform tests.assert((select count(*) from public.notification_outbox where kind = 'heart_sync') = 2, 'both notified of heart_sync');
  perform tests.assert((select count(*) from public.notification_outbox where kind = 'anonymous_signal' and cancelled_at is null) = 0,
                       'superseded anonymous receipt notification cancelled');

  perform tests.login(a);
  perform tests.expect_error(format('select public.send_heart_signal(%L)', b), 'already_matched', 'no second match per pair');
  select * into m from public.my_matches();
  perform tests.assert(m.match_id = v_match and m.kind = 'heart_sync' and (m.other).id = b and m.space_name = 'Leavey Library'
                       and (m.connection).status = 'pending_confirmation' and m.open_find is null and cardinality(m.actions) = 0,
                       'my_matches row shape');
  perform tests.assert((select status from public.my_sent_signals() where (recipient).id = b) = 'matched', 'sent signal shows matched');
  perform tests.login(b);
  perform tests.assert((select count(*) from public.my_signal_receipts()) = 0, 'matched signal is no longer an anonymous receipt');

  -- Crossed Hearts: D signals C, D leaves; C signals D via encounter.
  perform tests.pulse(c, 'Tutor Campus Center'); perform tests.pulse(d, 'Tutor Campus Center');
  perform tests.login(c); perform tests.assert((select count(*) from public.around_profiles()) = 1, 'C sees D (records encounter)');
  perform tests.login(d); perform tests.assert((select count(*) from public.around_profiles()) = 1, 'D sees C');
  res := public.send_heart_signal(c);
  perform tests.assert(res->>'result' = 'sent', 'D -> C sent');
  perform public.end_pulse();
  perform tests.login(c);
  perform tests.assert((select count(*) from public.around_profiles()) = 0, 'D gone from Around after ending Pulse');
  res := public.send_heart_signal(d);
  perform tests.assert(res->>'result' = 'matched', 'C -> D via encounter matches');
  perform tests.assert((select kind from public.matches where id = (res->>'match_id')::uuid) = 'crossed_hearts',
                       'recipient session ended -> crossed_hearts');
  perform tests.assert((select (other).first_name from public.my_matches() where kind = 'crossed_hearts') = 'D',
                       'C sees D in my_matches');
  perform tests.assert((select space_name from public.my_matches() where kind = 'crossed_hearts') = 'Tutor Campus Center',
                       'crossed hearts labelled with encounter space');

  -- Connection lifecycle.
  perform tests.login(a);
  c_row := public.set_connection_status(v_match, 'met_tonight');
  perform tests.assert(c_row.status = 'met_tonight' and c_row.confirmed_at is not null
                       and c_row.active_until = now() + interval '7 days', 'met_tonight confirms, active 7 days');
  perform tests.expect_error(format($q$select public.set_connection_status(%L, 'expired')$q$, v_match), 'invalid_input', 'clients cannot set expired');
  perform tests.login(c);
  perform tests.expect_error(format($q$select public.set_connection_status(%L, 'find_later')$q$, v_match), 'not_found', 'non-participant');
end $$;
rollback;
