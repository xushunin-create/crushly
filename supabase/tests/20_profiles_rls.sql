begin;
do $$
declare a uuid; b uuid; r public.profiles; n int; v_state jsonb;
begin
  a := tests.make_user('alice');
  b := tests.make_user('bob');
  update public.profiles set photo_review_status = 'approved' where id = a;

  perform tests.login(a);
  select count(*) into n from public.profiles;
  perform tests.assert(n = 1, 'direct select on profiles returns only own row');
  perform tests.assert((select count(*) from public.profiles where id = b) = 0, 'cannot select another profile');
  perform tests.assert((select count(*) from public.profile_private where user_id = b) = 0, 'cannot select another profile_private');

  -- Server-only columns: column privileges block direct writes...
  perform tests.expect_sqlstate(format($q$update public.profiles set photo_review_status = 'approved' where id = %L$q$, b),
                                '42501', 'cannot update photo_review_status (other user)');
  perform tests.expect_sqlstate(format($q$update public.profiles set photo_review_status = 'approved' where id = %L$q$, a),
                                '42501', 'cannot update own photo_review_status');
  perform tests.expect_sqlstate(format($q$update public.profiles set selfie_status = 'verified' where id = %L$q$, a),
                                '42501', 'cannot update own selfie_status');
  perform tests.expect_sqlstate(format($q$update public.profiles set university_domain = 'x.edu' where id = %L$q$, a),
                                '42501', 'cannot update own university_domain');
  perform tests.expect_sqlstate($q$update public.profile_private set terms_accepted_at = now()$q$,
                                '42501', 'cannot write terms fields directly');
  -- ...and RLS stops edits to others.
  update public.profiles set first_name = 'Hacked' where id = b;
  get diagnostics n = row_count;
  perform tests.assert(n = 0, 'update of another profile affects 0 rows');

  -- Allowed direct update of own discoverable field.
  update public.profiles set first_name = 'Alicia' where id = a;
  get diagnostics n = row_count;
  perform tests.assert(n = 1, 'owner can update own first_name');

  -- upsert_profile ignores server-only keys and revalidates photos.
  r := public.upsert_profile('{"first_name":"Al","photo_review_status":"approved","selfie_status":"verified","university_domain":"x.edu"}');
  perform tests.assert(r.first_name = 'Al' and r.photo_review_status = 'approved' and r.selfie_status = 'not_started'
                       and r.university_domain = 'usc.edu', 'upsert_profile ignores server-only fields');
  r := public.upsert_profile(jsonb_build_object('photo_paths', jsonb_build_array(a::text || '/new.jpg')));
  perform tests.assert(r.photo_review_status = 'pending', 'changing photos resets review to pending');
  perform tests.expect_error(format($q$select public.upsert_profile('{"photo_paths":["%s/x.jpg"]}')$q$, b),
                             'invalid_input', 'cannot reference photos in another user folder');
  perform tests.expect_error($q$select public.upsert_profile('{"interests":["a","b"]}')$q$, 'invalid_input', 'interests must be exactly 3');
  perform tests.expect_error($q$select public.upsert_profile('{"interests":["a","A","b"]}')$q$, 'invalid_input', 'interests must be distinct');
  perform tests.expect_error($q$select public.upsert_profile('{"age":17}')$q$, 'invalid_input', 'age < 18 rejected');
  perform tests.expect_error($q$select public.upsert_profile('{"vibe_tags":["1","2","3","4","5","6"]}')$q$, 'invalid_input', 'more than 5 vibe tags rejected');
  perform tests.expect_error(format($q$select public.upsert_profile('{"prompt_answer":"%s"}')$q$, repeat('x', 161)), 'invalid_input', 'prompt_answer > 160 rejected');
  perform tests.expect_error($q$select public.upsert_profile('{"intention":"marriage"}')$q$, 'invalid_input', 'bad enum rejected');

  -- Trigger layer, independent of column grants: even with an UPDATE grant on the
  -- column, a client update cannot change server-only fields.
  perform tests.logout();
  grant update (photo_review_status, selfie_status) on public.profiles to authenticated;
  perform tests.login(a);
  update public.profiles set photo_review_status = 'approved', selfie_status = 'verified' where id = a;
  perform tests.logout();
  perform tests.assert((select photo_review_status = 'pending' and selfie_status = 'not_started' from public.profiles where id = a),
                       'profiles_guard trigger keeps server-only columns on client update');
  revoke update (photo_review_status, selfie_status) on public.profiles from authenticated;
  perform tests.login(a);

  -- my_state hydrates.
  v_state := public.my_state();
  perform tests.assert(v_state ? 'profile' and v_state ? 'private' and v_state ? 'pulse' and v_state ? 'shield'
                       and v_state ? 'prefs' and v_state ? 'settings', 'my_state has all keys');
  perform tests.assert((v_state->'settings'->>'signals_per_session')::int = 5, 'my_state exposes settings');
  perform tests.assert(v_state->'pulse' = 'null'::jsonb, 'my_state pulse null without session');

  -- Tables clients must not read.
  perform tests.expect_sqlstate('select * from public.space_codes', '42501', 'space_codes not readable');
  perform tests.expect_sqlstate('select * from public.notification_outbox', '42501', 'notification_outbox not readable');
  perform tests.expect_sqlstate('select * from public.analytics_events', '42501', 'analytics_events not readable');
  perform tests.expect_sqlstate('select * from public.reports', '42501', 'reports not readable');
  perform tests.expect_sqlstate($q$insert into public.heart_signals (sender_id, recipient_id, expires_at, visible_at) values (auth.uid(), auth.uid(), now(), now())$q$,
                                '42501', 'heart_signals not directly writable');
  perform tests.expect_sqlstate($q$insert into public.pulse_sessions (user_id, space_id, availability, expires_at) values (auth.uid(), gen_random_uuid(), 'either', now() + interval '1 day')$q$,
                                '42501', 'pulse_sessions not directly writable');
  perform tests.expect_sqlstate('select public.is_discoverable_to(auth.uid(), auth.uid())', '42501', 'helper predicates not executable by clients');
  perform tests.expect_sqlstate('select public.crushly_tick()', '42501', 'crushly_tick not executable by clients');

  -- Anonymous role has nothing.
  perform tests.logout();
  perform set_config('role', 'anon', true);
  perform tests.expect_sqlstate('select public.my_state()', '42501', 'anon cannot execute RPCs');
  perform tests.expect_sqlstate('select * from public.campus_spaces', '42501', 'anon cannot read tables');
  perform tests.logout();

  -- Unauthenticated `authenticated` role (no sub) gets not_authenticated.
  perform set_config('role', 'authenticated', true);
  perform tests.expect_error('select public.my_state()', 'not_authenticated', 'missing jwt sub');
  perform tests.logout();

  -- Analytics allow-list.
  perform tests.login(a);
  perform public.track_event('pulse_started', '{"duration":30}');
  perform tests.expect_error($q$select public.track_event('steal_data', '{}')$q$, 'invalid_input', 'unknown analytics event rejected');
  perform tests.expect_error(format($q$select public.track_event('app_open', '{"x":"%s"}')$q$, repeat('y', 1100)), 'invalid_input', 'analytics props > 1KB rejected');
  perform tests.logout();
  perform tests.assert((select count(*) from public.analytics_events where user_id = a) = 1, 'allowed analytics event stored');
end $$;
rollback;
