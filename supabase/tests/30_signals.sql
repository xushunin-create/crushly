begin;
do $$
declare
  a uuid; b uuid; c uuid; d uuid; e uuid; f uuid; g uuid; lonely uuid; elsewhere uuid; idle uuid;
  res jsonb; n int; rec record; cols text[];
begin
  a := tests.make_user('a'); b := tests.make_user('b'); c := tests.make_user('c'); d := tests.make_user('d');
  e := tests.make_user('e'); f := tests.make_user('f'); g := tests.make_user('g');
  elsewhere := tests.make_user('elsewhere'); idle := tests.make_user('idle');
  perform tests.pulse(a, 'Leavey Library'); perform tests.pulse(b, 'Leavey Library');
  perform tests.pulse(c, 'Leavey Library'); perform tests.pulse(d, 'Leavey Library');
  perform tests.pulse(e, 'Leavey Library'); perform tests.pulse(f, 'Leavey Library');
  perform tests.pulse(g, 'Leavey Library'); perform tests.pulse(elsewhere, 'USC Village');

  -- Send A -> B.
  perform tests.login(a);
  res := public.send_heart_signal(b);
  perform tests.assert(res->>'result' = 'sent' and (res->>'remaining')::int = 4 and res->'match_id' = 'null'::jsonb,
                       'first signal: result=sent, remaining=4, match_id null');
  perform tests.assert((select count(*) from public.heart_signals) = 1, 'sender can select own signal row');

  -- Recipient can never read the row.
  perform tests.login(b);
  perform tests.assert((select count(*) from public.heart_signals) = 0, 'recipient direct select returns 0 rows');
  perform tests.assert((select count(*) from public.heart_signals where recipient_id = b) = 0, 'recipient filtered select returns 0 rows');
  perform tests.assert((select count(*) from public.my_signal_receipts()) = 0, 'receipt hidden before visible_at');

  -- Receipt shape: no sender id, no exact time.
  select array_agg(p.parameter_name::text order by p.ordinal_position) into cols
    from information_schema.routines rt join information_schema.parameters p on p.specific_name = rt.specific_name
   where rt.routine_schema = 'public' and rt.routine_name = 'my_signal_receipts' and p.parameter_mode = 'OUT';
  perform tests.assert(cols = array['id','received_bucket','space_name'], 'my_signal_receipts columns are exactly id, received_bucket, space_name');

  perform tests.logout();
  update public.heart_signals set visible_at = now() - interval '1 second' where sender_id = a;
  perform tests.login(b);
  select * into rec from public.my_signal_receipts();
  perform tests.assert(rec.id is not null, 'receipt visible after visible_at');
  perform tests.assert(extract(second from rec.received_bucket) = 0 and extract(minute from rec.received_bucket)::int % 15 = 0,
                       'received_bucket rounded to 15 minutes');
  perform tests.assert(rec.space_name = 'Leavey Library', 'space disclosed when >= 5 live in space (7 at Leavey)');
  perform tests.assert(to_jsonb(rec) - 'id' - 'received_bucket' - 'space_name' = '{}'::jsonb, 'receipt carries no other fields');

  -- k-anonymity: small crowd -> no space name.
  perform tests.pulse(idle, 'USC Village');      -- 2 live at Village (elsewhere, idle)
  res := public.send_heart_signal(elsewhere);
  perform tests.logout();
  update public.heart_signals set visible_at = now() - interval '1 second' where sender_id = idle;
  perform tests.login(elsewhere);
  perform tests.assert((select space_name from public.my_signal_receipts()) is null, 'space hidden when crowd < 5');
  -- Expired-but-unticked signal is not shown.
  perform tests.logout();
  update public.heart_signals set expires_at = now() - interval '1 second', created_at = now() - interval '73 hours'
   where sender_id = idle;
  perform tests.login(elsewhere);
  perform tests.assert((select count(*) from public.my_signal_receipts()) = 0, 'expired signal hidden without tick');

  -- Error paths.
  perform tests.login(a);
  perform tests.expect_error(format('select public.send_heart_signal(%L)', a), 'self_signal', 'self signal');
  perform tests.expect_error(format('select public.send_heart_signal(%L)', b), 'already_signaled', 'duplicate pending signal');
  perform tests.expect_error(format('select public.send_heart_signal(%L)', elsewhere), 'not_available', 'other space, no encounter');
  res := public.send_heart_signal(c); perform tests.assert((res->>'remaining')::int = 3, 'remaining=3');
  res := public.send_heart_signal(d); perform tests.assert((res->>'remaining')::int = 2, 'remaining=2');
  res := public.send_heart_signal(e); perform tests.assert((res->>'remaining')::int = 1, 'remaining=1');
  res := public.send_heart_signal(f); perform tests.assert((res->>'remaining')::int = 0, 'remaining=0 after 5th');
  perform tests.expect_error(format('select public.send_heart_signal(%L)', g), 'limit_reached', '6th signal in a session');

  -- No live session / paused.
  lonely := tests.make_user('lonely');
  perform tests.login(lonely);
  perform tests.expect_error(format('select public.send_heart_signal(%L)', b), 'no_live_session', 'no session');
  perform tests.login(g);
  perform public.pause_pulse();
  perform tests.expect_error(format('select public.send_heart_signal(%L)', b), 'no_live_session', 'paused session cannot send');
  perform public.resume_pulse();

  -- Blocks: not_available in both directions.
  perform tests.login(g);
  perform public.block_user(c);
  perform tests.expect_error(format('select public.send_heart_signal(%L)', c), 'not_available', 'blocker -> blocked');
  perform tests.login(c);
  perform tests.expect_error(format('select public.send_heart_signal(%L)', g), 'not_available', 'blocked -> blocker');

  -- Shield: caller gets `shielded`, sender to a shielded user gets `not_available`.
  perform tests.login(d);
  perform public.enter_shield(60);
  perform tests.expect_error(format('select public.send_heart_signal(%L)', e), 'shielded', 'shielded caller');
  perform tests.login(e);
  perform tests.expect_error(format('select public.send_heart_signal(%L)', d), 'not_available', 'recipient shielded (same message as undiscoverable)');

  -- Sent list.
  perform tests.login(a);
  perform tests.assert((select count(*) from public.my_sent_signals()) = 5, 'my_sent_signals lists 5');
  perform tests.assert((select (s.recipient).first_name from public.my_sent_signals() s where (s.recipient).id = b) = 'B',
                       'my_sent_signals embeds recipient public_profile');
  -- Incomplete profile.
  perform tests.logout();
  update public.profiles set interests = '{}' where id = f;
  perform tests.login(f);
  perform tests.expect_error(format('select public.send_heart_signal(%L)', a), 'profile_incomplete', 'incomplete profile');
end $$;
rollback;
