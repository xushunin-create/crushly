-- Spaces and participation: consent per visit, 60 s leases, evidence checks, out-of-order protection.
begin;
do $$
declare a uuid; b uuid; st jsonb; r jsonb; r2 jsonb; v_epoch bigint; v_sid uuid; v_req uuid := gen_random_uuid();
begin
  perform tests.make_space('quad');
  perform tests.make_space('lawn');
  perform tests.make_space('draft-zone', 'draft');
  perform tests.make_space('disabled-zone', 'field_validated', false);
  a := tests.make_user('pa');
  b := tests.make_user('pb');

  -- Space list ---------------------------------------------------------------------------------
  perform tests.login(a);
  perform tests.assert((select count(*) from public.campus_spaces where slug in ('quad', 'lawn')) = 2, 'validated, enabled spaces are listed');
  perform tests.assert((select count(*) from public.campus_spaces where slug = 'draft-zone') = 0, 'draft spaces are hidden in production');
  perform tests.assert((select count(*) from public.campus_spaces where slug = 'disabled-zone') = 0, 'disabled spaces are hidden');

  -- Invisible by default ----------------------------------------------------------------------
  st := public.my_participation();
  perform tests.assert(st->'session' = 'null'::jsonb, 'new user has no participation session (invisible by default)');
  v_epoch := (st->>'consent_epoch')::bigint;

  -- Opening requires a usable space, current boundary, current epoch and plausible fresh evidence.
  perform tests.expect_error(format($q$select public.open_participation('draft-zone', 1, %s, gen_random_uuid(), tests.evidence())$q$, v_epoch),
                             'space_unavailable', 'cannot open in a draft space in production');
  perform tests.expect_error(format($q$select public.open_participation('disabled-zone', 1, %s, gen_random_uuid(), tests.evidence())$q$, v_epoch),
                             'space_unavailable', 'cannot open in a disabled space');
  perform tests.expect_error(format($q$select public.open_participation('nowhere', 1, %s, gen_random_uuid(), tests.evidence())$q$, v_epoch),
                             'space_unavailable', 'cannot open in an unknown space');
  perform tests.expect_error(format($q$select public.open_participation('quad', 2, %s, gen_random_uuid(), tests.evidence())$q$, v_epoch),
                             'boundary_outdated', 'stale/unknown boundary version rejected');
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, gen_random_uuid(), tests.evidence())$q$, v_epoch + 1),
                             'consent_stale', 'consent from a different epoch rejected');
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, gen_random_uuid(), tests.evidence(16000))$q$, v_epoch),
                             'stale_evidence', 'fix older than 15 s rejected');
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, gen_random_uuid(), tests.evidence(1000, 31))$q$, v_epoch),
                             'insufficient_accuracy', 'accuracy worse than 30 m rejected');
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, gen_random_uuid(), tests.evidence(1000, 10, true))$q$, v_epoch),
                             'stale_evidence', 'entry cannot rely on a re-cited stationary fix');
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, gen_random_uuid(), '{"fix_age_ms":1}')$q$, v_epoch),
                             'invalid_input', 'malformed evidence rejected');
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, gen_random_uuid(), 'null')$q$, v_epoch),
                             'invalid_input', 'heartbeat without evidence rejected');

  -- Successful open: lease is at most 60 s.
  r := public.open_participation('quad', 1, v_epoch, v_req, tests.evidence());
  v_sid := (r->>'session_id')::uuid;
  perform tests.assert((r->>'lease_expires_at')::timestamptz <= now() + interval '60 seconds', 'lease is capped at 60 s');
  st := public.my_participation();
  perform tests.assert(st->'session'->>'space_slug' = 'quad', 'my_participation shows MY space to me');

  -- Idempotent retry returns the same session.
  r2 := public.open_participation('quad', 1, v_epoch, v_req, tests.evidence());
  perform tests.assert((r2->>'session_id')::uuid = v_sid, 'retrying the same open request is idempotent');

  -- Renewal ---------------------------------------------------------------------------------------
  r := public.renew_participation(v_sid, 1, tests.evidence());
  perform tests.assert((r->>'lease_expires_at')::timestamptz <= now() + interval '60 seconds', 'renewal never extends beyond 60 s');
  perform tests.expect_error(format($q$select public.renew_participation(%L, 1, tests.evidence())$q$, v_sid),
                             'stale_request', 'replayed sequence number rejected');
  perform tests.expect_error(format($q$select public.renew_participation(%L, 2, tests.evidence(1000, 10, false, 1))$q$, v_sid),
                             'stale_evidence', 'renewal citing an older fix rejected (heartbeat is not evidence)');
  perform tests.expect_error(format($q$select public.renew_participation(%L, 3, tests.evidence(20000))$q$, v_sid),
                             'stale_evidence', 'renewal with a stale moving fix rejected');
  r := public.renew_participation(v_sid, 4, tests.evidence(120000, 10, true,
                                    tests.val(format('select last_fix_ts_ms from public.participation_sessions where id = %L', v_sid))::bigint));
  perform tests.assert(r ? 'lease_expires_at', 'stationary renewal may re-cite the last fix (≤ 5 min old)');
  perform tests.expect_error(format($q$select public.renew_participation(%L, 5, tests.evidence(301000, 10, true))$q$, v_sid),
                             'stale_evidence', 'stationary evidence older than 5 min rejected');

  -- Another user cannot renew or see my session.
  perform tests.login(b);
  perform tests.expect_error(format($q$select public.renew_participation(%L, 99, tests.evidence())$q$, v_sid),
                             'session_expired', 'cannot renew someone else''s session');
  perform tests.assert(public.my_participation()->'session' = 'null'::jsonb, 'another user does not see my session');

  -- Expiry is final -------------------------------------------------------------------------------
  perform tests.expire(a);
  perform tests.login(a);
  perform tests.assert(public.my_participation()->'session' = 'null'::jsonb, 'expired lease is invisible without the tick');
  perform tests.expect_error(format($q$select public.renew_participation(%L, 10, tests.evidence())$q$, v_sid),
                             'session_expired', 'an expired session cannot be renewed back to life');
  perform tests.logout();
  perform public.crushly_tick();
  perform tests.assert(tests.n(format('select 1 from public.participation_sessions where id = %L', v_sid)) = 0, 'expired session row is deleted by the tick');
  perform tests.login(a);

  -- Revocation and out-of-order requests -------------------------------------------------------
  st := public.my_participation(); v_epoch := (st->>'consent_epoch')::bigint;
  v_req := gen_random_uuid();
  r := public.open_participation('quad', 1, v_epoch, v_req, tests.evidence());
  v_sid := (r->>'session_id')::uuid;
  perform tests.assert(public.revoke_participation() = v_epoch + 1, 'going invisible bumps the consent epoch');
  perform tests.assert(public.my_participation()->'session' = 'null'::jsonb, 'going invisible removes participation immediately');
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, %L, tests.evidence())$q$, v_epoch, v_req),
                             'consent_stale', 'a delayed copy of the old "open" cannot restore revoked consent');
  perform tests.expect_error(format($q$select public.renew_participation(%L, 50, tests.evidence())$q$, v_sid),
                             'session_expired', 'a delayed renewal cannot reactivate a revoked session');
  perform tests.assert(public.revoke_participation() = v_epoch + 2, 'revoking again is harmless (idempotent)');

  -- Moving A -> B never carries consent forward ------------------------------------------------
  st := public.my_participation(); v_epoch := (st->>'consent_epoch')::bigint;
  r := public.open_participation('quad', 1, v_epoch, gen_random_uuid(), tests.evidence());
  v_sid := (r->>'session_id')::uuid;
  r2 := public.open_participation('lawn', 1, v_epoch, gen_random_uuid(), tests.evidence());
  perform tests.assert((r2->>'session_id')::uuid <> v_sid, 'a new space gets a new session');
  perform tests.assert(tests.n(format('select 1 from public.participation_sessions where user_id = %L', a)) = 1, 'at most one session per user');
  perform tests.assert(public.my_participation()->'session'->>'space_slug' = 'lawn', 'only the new space is active');
  perform tests.expect_error(format($q$select public.renew_participation(%L, 99, tests.evidence())$q$, v_sid),
                             'session_expired', 'the old space''s session is gone');

  -- Global pause ---------------------------------------------------------------------------------
  perform tests.expect_error('select public.set_matching_paused(true, 7)', 'invalid_duration', 'only offered pause durations');
  st := public.set_matching_paused(true, null);
  perform tests.assert((st->>'matching_paused')::boolean and st->'session' = 'null'::jsonb, 'pausing revokes participation');
  v_epoch := (st->>'consent_epoch')::bigint;
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, gen_random_uuid(), tests.evidence())$q$, v_epoch),
                             'matching_paused', 'cannot participate while paused');
  st := public.set_matching_paused(false);
  perform tests.assert(not (st->>'matching_paused')::boolean and st->'session' = 'null'::jsonb, 'resuming never opens a session');
  st := public.set_matching_paused(true, 60);
  perform tests.assert((st->>'paused_until')::timestamptz = now() + interval '60 minutes', 'timed pause records its end');
  perform public.set_matching_paused(false);

  -- Profile/prefs gate --------------------------------------------------------------------------
  perform tests.login(tests.make_user('noprefs', true, false));
  perform tests.expect_error($q$select public.open_participation('quad', 1, 0, gen_random_uuid(), tests.evidence())$q$,
                             'profile_incomplete', 'cannot participate without terms and preferences');

  -- Rate limit on opens ------------------------------------------------------------------------
  perform tests.login(b);
  perform tests.reset_rate_limits();
  st := public.my_participation(); v_epoch := (st->>'consent_epoch')::bigint;
  for i in 1..30 loop
    perform public.open_participation('quad', 1, v_epoch, gen_random_uuid(), tests.evidence());
  end loop;
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, gen_random_uuid(), tests.evidence())$q$, v_epoch),
                             'rate_limited', 'participation opens are rate-limited');
  perform tests.reset_rate_limits();

  -- Account deletion removes participation ------------------------------------------------------
  perform tests.logout();
  delete from auth.users where id = b;
  perform tests.assert((select count(*) from public.participation_sessions where user_id = b) = 0, 'account deletion removes participation');
end $$;

-- Seeded USC zones are drafts: present, but unusable in production until field-validated.
do $$
declare a uuid;
begin
  perform tests.assert((select count(*) from public.campus_spaces
                         where slug in ('upc-alumni-park-tommy-trojan', 'upc-mccarthy-quad', 'usc-village-great-lawn',
                                        'upc-iovine-young-hall')) = 4,
                       'four draft USC zones are seeded');
  perform tests.assert((select count(*) from public.campus_spaces where membership_rule = 'circle' and max_accuracy_m is null
                         and slug in ('upc-alumni-park-tommy-trojan', 'upc-mccarthy-quad', 'usc-village-great-lawn')) = 3,
                       'open-air zones keep the strict defaults');
  perform tests.assert((select membership_rule = 'point' and max_accuracy_m = 40 from public.campus_spaces
                         where slug = 'upc-iovine-young-hall'), 'IYH is an indoor point-rule zone with a 40 m limit');
  perform tests.assert((select bool_and(validation_status = 'draft') from public.campus_spaces where slug like 'u%c-%'),
                       'every seeded USC zone is still a draft');
  perform tests.assert((select boundary->>'type' from public.campus_spaces where slug = 'upc-alumni-park-tommy-trojan') = 'MultiPolygon',
                       'abutting venues are one MultiPolygon zone');
  perform tests.assert((select bool_and(jsonb_array_length(source_refs) > 0) from public.campus_spaces where slug like 'u%c-%'),
                       'every seeded zone records its sources');
  a := tests.make_user('uscviewer');
  perform tests.login(a);
  perform tests.assert((select count(*) from public.campus_spaces where slug like 'u%c-%') = 0, 'draft USC zones are hidden in production');
  perform tests.expect_error($q$select public.open_participation('upc-mccarthy-quad', 1, 0, gen_random_uuid(), tests.evidence())$q$,
                             'space_unavailable', 'cannot participate in a draft USC zone in production');
  perform tests.logout();
end $$;

-- Draft spaces are usable only when explicitly allowed (dev/staging).
do $$
declare a uuid; st jsonb;
begin
  update public.app_settings set value = 'true' where key = 'allow_draft_spaces';
  a := tests.make_user('drafter');
  perform tests.login(a);
  perform tests.assert((select count(*) from public.campus_spaces where slug = 'draft-zone') = 1, 'drafts listed when allowed');
  st := public.my_participation();
  perform public.open_participation('draft-zone', 1, (st->>'consent_epoch')::bigint, gen_random_uuid(), tests.evidence());
  perform tests.assert(public.my_participation()->'session'->>'space_slug' = 'draft-zone', 'drafts usable when allowed');
  perform tests.logout();
  update public.app_settings set value = 'false' where key = 'allow_draft_spaces';
end $$;

-- Per-space accuracy limits (indoor zones). The global limit is 30 m.
do $$
declare a uuid; st jsonb; sess uuid;
begin
  perform tests.make_space('indoor-hall');
  update public.campus_spaces set membership_rule = 'point', max_accuracy_m = 40 where slug = 'indoor-hall';
  perform tests.expect_sqlstate($q$update public.campus_spaces set max_accuracy_m = 500 where slug = 'indoor-hall'$q$,
                                '23514', 'accuracy override is bounded');
  perform tests.expect_sqlstate($q$update public.campus_spaces set membership_rule = 'nearby' where slug = 'indoor-hall'$q$,
                                '23514', 'unknown membership rule rejected');

  a := tests.make_user('indoor');
  perform tests.login(a);
  st := public.my_participation();
  perform tests.expect_error(format($q$select public.open_participation('quad', 1, %s, gen_random_uuid(), tests.evidence(accuracy => 35))$q$,
                                    st->>'consent_epoch'), 'insufficient_accuracy', 'open-air space keeps the 30 m limit');
  perform tests.expect_error(format($q$select public.open_participation('indoor-hall', 1, %s, gen_random_uuid(), tests.evidence(accuracy => 45))$q$,
                                    st->>'consent_epoch'), 'insufficient_accuracy', 'indoor space rejects fixes over its own limit');
  sess := (public.open_participation('indoor-hall', 1, (st->>'consent_epoch')::bigint, gen_random_uuid(),
                                     tests.evidence(accuracy => 35))->>'session_id')::uuid;
  perform tests.assert(sess is not null, 'indoor space accepts a 35 m fix');
  perform public.renew_participation(sess, 1, tests.evidence(accuracy => 38));
  perform tests.assert(true, 'renewal in an indoor space uses its own limit');
  perform tests.expect_error(format($q$select public.renew_participation(%L, 2, tests.evidence(accuracy => 41))$q$, sess),
                             'insufficient_accuracy', 'renewal still bounded by the space limit');
  perform tests.logout();
  perform tests.assert(not has_function_privilege('authenticated', 'public.check_evidence(jsonb, bigint, boolean, int)', 'execute'),
                       'clients cannot call the evidence helper');
end $$;
rollback;
