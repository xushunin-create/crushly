-- Discovery, anonymous interest and mutual matching. Eligibility is checked at every step.
begin;
do $$
declare
  a uuid; b uuid; c uuid; d uuid; e uuid; w uuid; m uuid; old uuid;
  r jsonb; v_ids uuid[]; v_profile jsonb; i int;
begin
  perform tests.make_space('quad');
  perform tests.make_space('lawn');
  a := tests.make_user('ma'); b := tests.make_user('mb'); c := tests.make_user('mc'); d := tests.make_user('md');
  e := tests.make_user('me_other_space');

  -- Invisible users can't browse --------------------------------------------------------------
  perform tests.login(a);
  perform tests.expect_error('select public.discover_candidates()', 'not_participating', 'invisible user cannot browse candidates');
  perform tests.expect_error(format('select public.express_interest(%L)', b), 'not_participating', 'invisible user cannot express interest');

  -- Low-population safeguard ------------------------------------------------------------------
  perform tests.participate(a, 'quad');
  perform tests.login(a);
  r := public.discover_candidates();
  perform tests.assert(r->>'status' = 'quiet' and r->'profiles' = '[]'::jsonb, 'fewer than 2 participants: nothing shown');
  perform tests.assert(not r ? 'count', 'no participant count is ever returned');
  perform tests.reset_rate_limits();

  perform tests.participate(b, 'quad'); perform tests.participate(c, 'quad'); perform tests.participate(d, 'quad');
  perform tests.participate(e, 'lawn');
  perform tests.login(a);
  r := public.discover_candidates();
  perform tests.assert(r->>'status' = 'ok', 'enough participants: discovery opens');
  v_ids := array(select (x->>'id')::uuid from jsonb_array_elements(r->'profiles') x);
  perform tests.assert(v_ids @> array[b, c, d] and cardinality(v_ids) = 3, 'sees exactly the other eligible participants in the same space');
  perform tests.assert(not (e = any (v_ids)), 'never sees participants in another space');
  v_profile := r->'profiles'->0;
  perform tests.assert(not (v_profile ? 'space_id' or v_profile ? 'space_name' or v_profile ? 'session_paused'
                            or v_profile ? 'lease_expires_at' or v_profile ? 'email'),
                       'candidate profiles carry no space, session, status or email');

  -- Rate limit: one discovery per 15 s.
  perform tests.expect_error('select public.discover_candidates()', 'rate_limited', 'discovery is rate-limited');
  perform tests.reset_rate_limits();

  -- Result cap.
  perform tests.logout();
  update public.app_settings set value = '2' where key = 'discovery_max_results';
  perform tests.login(a);
  perform tests.assert(jsonb_array_length(public.discover_candidates()->'profiles') = 2, 'discovery returns at most the configured cap');
  perform tests.logout();
  update public.app_settings set value = '8' where key = 'discovery_max_results';
  perform tests.login(a);
  perform tests.reset_rate_limits();

  -- Preferences apply in both directions ------------------------------------------------------
  perform tests.logout();
  update public.profile_private set show_me = array['woman'] where user_id = b;   -- b only wants women; a is nonbinary
  perform tests.login(a);
  v_ids := array(select (x->>'id')::uuid from jsonb_array_elements(public.discover_candidates()->'profiles') x);
  perform tests.assert(not (b = any (v_ids)), 'a does not see b when b''s preferences exclude a');
  perform tests.expect_error(format('select public.express_interest(%L)', b), 'not_available', 'cannot express interest against preferences');
  perform tests.reset_rate_limits();
  perform tests.logout();
  update public.profile_private set show_me = array['man','nonbinary','woman'], age_min = 25 where user_id = b;  -- a is 20
  perform tests.login(a);
  v_ids := array(select (x->>'id')::uuid from jsonb_array_elements(public.discover_candidates()->'profiles') x);
  perform tests.assert(not (b = any (v_ids)), 'age range is enforced');
  perform tests.reset_rate_limits();
  perform tests.logout();
  update public.profile_private set age_min = 18 where user_id = b;

  -- One-sided interest stays anonymous and tied to the visit -------------------------------------
  perform tests.login(a);
  r := public.express_interest(b);
  perform tests.assert(r->>'result' = 'sent' and (r->>'remaining')::int = 4, 'interest sent, 4 left');
  perform tests.expect_error(format('select public.express_interest(%L)', b), 'already_sent', 'no duplicate interest in a visit');
  perform tests.assert(public.my_sent_interests() = array[b], 'sender sees whom they''ve expressed interest in');
  perform tests.login(b);
  perform tests.assert(public.my_interest_receipts() = 0, 'receipt hidden during the random delay');
  perform tests.reveal_interests();
  perform tests.assert(public.my_interest_receipts() = 1, 'recipient gets an anonymous count, nothing else');

  -- Interest disappears when the sender's visit ends.
  perform tests.expire(a);
  perform tests.login(b);
  perform tests.assert(public.my_interest_receipts() = 0, 'receipt disappears when the sender''s lease lapses');
  perform tests.participate(a, 'quad');
  perform tests.assert(public.my_sent_interests() = '{}', 'new visit starts with no interests');
  perform tests.login(b);
  r := public.express_interest(a);
  perform tests.assert(r->>'result' = 'sent', 'b''s interest after a re-entered does NOT match the expired one');
  perform tests.assert(tests.n('select 1 from public.matches') = 0, 'expired interest never becomes a match');

  -- Mutual interest creates exactly one match --------------------------------------------------
  perform tests.login(a);
  r := public.express_interest(b);
  perform tests.assert(r->>'result' = 'matched', 'reciprocal interest matches');
  m := (r->>'match_id')::uuid;
  perform tests.assert(tests.n('select 1 from public.matches') = 1, 'exactly one match row');
  perform tests.assert(tests.n(format('select 1 from public.interests i join public.participation_sessions s on s.id = i.sender_session_id where s.user_id in (%L, %L)', a, b)) = 0, 'matched interests are deleted');
  perform tests.assert(tests.n(format($q$select 1 from public.notification_outbox where kind = 'new_match' and payload->>'match_id' = %L$q$, m)) = 2,
                       'both get a generic new-match notification');
  perform tests.assert((select count(*) from information_schema.columns
                         where table_schema = 'public' and table_name = 'matches'
                           and column_name in ('space_id', 'kind', 'space_name')) = 0, 'matches store no place');
  perform tests.expect_error(format('select public.express_interest(%L)', b), 'already_matched', 'no second match for the pair');
  perform tests.reset_rate_limits();
  v_ids := array(select (x->>'id')::uuid from jsonb_array_elements(public.discover_candidates()->'profiles') x);
  perform tests.assert(not (b = any (v_ids)), 'existing matches are not shown as candidates');
  perform tests.reset_rate_limits();

  -- Match creation fails when either session is no longer valid --------------------------------
  perform tests.login(c);
  perform public.express_interest(d);
  perform tests.expire(c);
  perform tests.login(d);
  perform tests.expect_error(format('select public.express_interest(%L)', c), 'not_available', 'no match when the other session expired');
  perform tests.assert(tests.n(format('select 1 from public.matches where user_a = least(%L::uuid, %L::uuid) and user_b = greatest(%L::uuid, %L::uuid)', c, d, c, d)) = 0, 'no c-d match');
  perform tests.participate(c, 'quad');

  perform tests.login(c);
  perform public.express_interest(d);
  perform tests.login(d);
  perform public.revoke_participation();
  perform tests.expect_error(format('select public.express_interest(%L)', c), 'not_participating', 'no match after going invisible');
  perform tests.participate(d, 'quad');

  -- Paused / different space / blocked ----------------------------------------------------------
  perform tests.login(c);
  perform public.set_matching_paused(true);
  perform tests.login(d);
  perform tests.expect_error(format('select public.express_interest(%L)', c), 'not_available', 'paused user is not available');
  perform tests.login(c);
  perform public.set_matching_paused(false);
  perform tests.participate(c, 'lawn');
  perform tests.login(d);
  perform tests.expect_error(format('select public.express_interest(%L)', c), 'not_available', 'different space is not available');
  perform tests.participate(c, 'quad');
  perform tests.login(d);
  perform public.express_interest(c);
  perform tests.login(c);
  perform public.block_user(d);
  perform tests.assert(tests.n(format('select 1 from public.interests i join public.participation_sessions s on s.id = i.sender_session_id where s.user_id = %L', d)) = 0, 'blocking withdraws pending interests');
  perform tests.reset_rate_limits();
  v_ids := array(select (x->>'id')::uuid from jsonb_array_elements(public.discover_candidates()->'profiles') x);
  perform tests.assert(not (d = any (v_ids)), 'blocker does not see blocked user');
  perform tests.login(d);
  perform tests.reset_rate_limits();
  v_ids := array(select (x->>'id')::uuid from jsonb_array_elements(public.discover_candidates()->'profiles') x);
  perform tests.assert(not (c = any (v_ids)), 'blocked user does not see blocker');
  perform tests.expect_error(format('select public.express_interest(%L)', c), 'not_available', 'blocked pair cannot match');
  perform tests.login(c);
  perform public.unblock_user(d);
  perform tests.reset_rate_limits();

  -- Per-visit interest limit ------------------------------------------------------------------
  perform tests.logout();
  update public.app_settings set value = '1' where key = 'interests_per_session';
  perform tests.participate(d, 'quad');   -- fresh visit
  perform public.express_interest(c);
  perform tests.expect_error(format('select public.express_interest(%L)', a), 'limit_reached', 'per-visit interest limit');
  perform tests.logout();
  update public.app_settings set value = '5' where key = 'interests_per_session';
  perform tests.login(d);

  -- Probing a known user id without discovery reveals nothing ---------------------------------
  w := tests.make_user('prober');
  perform tests.participate(w, 'quad', false);
  perform tests.expect_error(format('select public.express_interest(%L)', a), 'not_available',
                             'cannot express interest in someone discovery has not shown you (no presence probing)');
  perform tests.reset_rate_limits();
  perform tests.login(w);
  r := public.discover_candidates();
  perform tests.assert(a = any (array(select (x->>'id')::uuid from jsonb_array_elements(r->'profiles') x)), 'prober is shown a once discovery runs');
  perform tests.assert(public.express_interest(a)->>'result' = 'sent', 'after being shown, interest works');
  perform tests.login(d);

  -- Self / unknown -------------------------------------------------------------------------------
  perform tests.expect_error(format('select public.express_interest(%L)', d), 'invalid_input', 'cannot express interest in yourself');
  perform tests.expect_error(format('select public.express_interest(%L)', gen_random_uuid()), 'not_available', 'unknown user is just not available');

  -- Interest rate limit ------------------------------------------------------------------------
  perform tests.reset_rate_limits();
  w := tests.make_user('spammer');
  perform tests.participate(w, 'quad');
  -- Failed calls roll back their own counter increment, so preload the window:
  perform tests.logout();
  insert into public.rate_limits (user_id, bucket, window_start, hits)
  values (w, 'interest:3600', to_timestamp(floor(extract(epoch from now()) / 3600) * 3600), 30);
  perform tests.login(w);
  perform tests.expect_error(format('select public.express_interest(%L)', a), 'rate_limited', 'interests are rate-limited per hour');
end $$;
rollback;
