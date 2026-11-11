begin;
do $$
declare a uuid; b uuid; c uuid; nt uuid; s public.pulse_sessions; sh public.shield_states; sp public.campus_spaces; v_old uuid; st jsonb;
begin
  a := tests.make_user('a'); b := tests.make_user('b');
  perform tests.pulse(a, 'Leavey Library'); perform tests.pulse(b, 'Leavey Library');

  -- Pause hides immediately.
  perform tests.login(a);
  perform tests.assert((select count(*) from public.around_profiles()) = 1, 'A sees B');
  perform tests.login(b);
  s := public.pause_pulse();
  perform tests.assert(s.paused_at is not null and s.expires_at = now() + interval '60 minutes', 'pause keeps expiry');
  perform tests.expect_error('select * from public.around_profiles()', 'no_live_session', 'paused user cannot view Around');
  perform tests.login(a);
  perform tests.assert((select count(*) from public.around_profiles()) = 0, 'paused B hidden immediately');
  perform tests.login(b);
  s := public.resume_pulse();
  perform tests.login(a);
  perform tests.assert((select count(*) from public.around_profiles()) = 1, 'resumed B visible again');

  -- Expiry without tick.
  perform tests.logout();
  update public.pulse_sessions set started_at = now() - interval '2 hours', expires_at = now() - interval '1 minute',
                                   paused_at = now() - interval '90 minutes'
   where user_id = b and ended_at is null;
  perform tests.login(b);
  perform tests.expect_error('select public.resume_pulse()', 'session_expired', 'resume after expiry');
  perform tests.expect_error('select public.pause_pulse()', 'session_expired', 'pause after expiry');
  perform tests.assert((public.my_state()->'pulse'->>'is_expired')::boolean, 'my_state flags stale session as expired');
  perform tests.logout();
  update public.pulse_sessions set paused_at = null where user_id = b and ended_at is null;
  perform tests.login(a);
  perform tests.assert((select count(*) from public.around_profiles()) = 0, 'expired (unticked) session hidden');
  -- Starting again ends the stale session.
  perform tests.login(b);
  select id into v_old from public.pulse_sessions where ended_at is null;
  s := public.start_pulse(tests.space('Leavey Library'), 30, false, 'meet_now');
  perform tests.assert(s.expires_at = now() + interval '30 minutes', 'new 30-minute session');
  perform tests.assert((select end_reason from public.pulse_sessions where id = v_old) = 'expired', 'stale session ended as expired');
  perform tests.expect_error(format($q$select public.start_pulse(%L, 30, false, 'either')$q$, tests.space('Leavey Library')),
                             'not_permitted', 'cannot start a second live session');

  -- Durations and spaces.
  perform public.end_pulse();
  perform tests.expect_error(format($q$select public.start_pulse(%L, 45, false, 'either')$q$, tests.space('Leavey Library')), 'invalid_duration', '45 min not allowed');
  perform tests.expect_error(format($q$select public.start_pulse(%L, null, true, 'either')$q$, tests.space('Leavey Library')), 'invalid_duration', 'until event end needs an event');
  perform tests.expect_error(format($q$select public.start_pulse(%L, 30, false, 'either')$q$, gen_random_uuid()), 'not_found', 'unknown space');
  sp := public.enter_space_code('  hack26 ');
  perform tests.assert(sp.name = 'Trojan Hacks', 'space code is case-insensitive');
  perform tests.expect_error($q$select public.enter_space_code('NOPE')$q$, 'invalid_code', 'unknown code');
  s := public.start_pulse(sp.id, null, true, 'either');
  perform tests.assert(s.expires_at = sp.ends_at, 'until_event_end uses event end');
  perform public.end_pulse();
  perform tests.logout();
  update public.campus_spaces set is_active = false where name = 'Spring Social Mixer';
  perform tests.login(b);
  perform tests.expect_error($q$select public.enter_space_code('mixer')$q$, 'invalid_code', 'inactive space code');

  -- Gates.
  nt := tests.make_user('noterms', true, false);
  perform tests.login(nt);
  perform tests.expect_error(format($q$select public.start_pulse(%L, 30, false, 'either')$q$, tests.space('Leavey Library')), 'terms_required', 'terms required');
  perform tests.expect_error($q$select public.accept_terms('v1', 'v1', false)$q$, 'invalid_input', 'age must be confirmed');
  perform public.accept_terms('v1', 'v1', true);
  s := public.start_pulse(tests.space('Leavey Library'), 30, false, 'either');
  perform tests.assert(s.id is not null, 'pulse after accepting terms');
  c := tests.make_user('incomplete', false, true);
  perform tests.login(c);
  perform tests.expect_error(format($q$select public.start_pulse(%L, 30, false, 'either')$q$, tests.space('Leavey Library')), 'profile_incomplete', 'profile required');
end $$;

do $$
declare a uuid; b uuid; sh public.shield_states; s public.pulse_sessions; st jsonb;
begin
  a := tests.make_user('sa'); b := tests.make_user('sb');
  perform tests.pulse(a, 'Tutor Campus Center'); perform tests.pulse(b, 'Tutor Campus Center');
  perform tests.login(a);
  perform tests.expect_error('select public.enter_shield(45)', 'invalid_duration', 'shield duration must be allowed');
  sh := public.enter_shield(60);
  perform tests.assert(sh.active_until = now() + interval '60 minutes' and sh.ended_at is null, 'shield for 60 min');
  perform tests.assert((select end_reason from public.pulse_sessions where user_id = a) = 'shield', 'enter_shield ends session with reason shield');
  perform tests.login(b);
  perform tests.assert((select count(*) from public.around_profiles()) = 0, 'shielded user hidden');
  perform tests.logout();
  perform tests.assert((select count(*) from public.notification_outbox) = 0, 'no notification to others on shield');
  perform tests.login(a);
  perform tests.expect_error(format($q$select public.start_pulse(%L, 30, false, 'either')$q$, tests.space('Tutor Campus Center')), 'shielded', 'cannot pulse while shielded');
  perform public.exit_shield();
  st := public.my_state();
  perform tests.assert(st->'shield' = 'null'::jsonb and st->'pulse' = 'null'::jsonb, 'exit_shield does not restart Pulse');
  perform tests.assert((select count(*) from public.pulse_sessions where user_id = a and ended_at is null) = 0, 'no live session after exit');
  sh := public.enter_shield(null);
  perform tests.assert(sh.active_until is null, 'indefinite shield');
  perform tests.logout();
  update public.shield_states set started_at = now() - interval '2 hours', active_until = now() - interval '1 minute' where user_id = a;
  perform tests.login(a);
  s := public.start_pulse(tests.space('Tutor Campus Center'), 30, false, 'either');
  perform tests.assert(s.id is not null, 'expired shield (unticked) no longer blocks');
end $$;
rollback;
