begin;
do $$
declare
  a uuid; b uuid; blk uuid; shd uuid; other uuid; paused uuid; rej uuid; ver uuid; ids uuid[]; v_report uuid; cols text[];
  s1 uuid; s2 uuid; o1 uuid[]; o2 uuid[];
begin
  a := tests.make_user('a'); b := tests.make_user('b'); blk := tests.make_user('blk'); shd := tests.make_user('shd');
  other := tests.make_user('other'); paused := tests.make_user('paused'); rej := tests.make_user('rej'); ver := tests.make_user('ver');
  perform tests.pulse(a, 'Leavey Library'); perform tests.pulse(b, 'Leavey Library');
  perform tests.pulse(blk, 'Leavey Library'); perform tests.pulse(shd, 'Leavey Library');
  perform tests.pulse(other, 'USC Village'); perform tests.pulse(paused, 'Leavey Library'); perform public.pause_pulse();
  perform tests.pulse(rej, 'Leavey Library'); perform tests.pulse(ver, 'Leavey Library');
  perform tests.login(blk); perform public.block_user(a);
  perform tests.logout();
  -- Shield row while a session still exists exercises the predicate itself.
  insert into public.shield_states (user_id, active_until) values (shd, null);
  update public.profiles set photo_review_status = 'rejected' where id = rej;
  update public.profile_private set verified_only_discovery = true where user_id = ver;

  perform tests.login(a);
  select array_agg(id) into ids from public.around_profiles();
  perform tests.assert(ids = array[b], format('Around shows only B (got %s): excludes blocked, shielded, other space, paused, rejected photo, verified-only', ids));
  perform tests.login(ver);
  perform tests.assert(not (a = any (coalesce((select array_agg(id) from public.around_profiles()), '{}'))), 'verified-only user does not see unapproved users');
  perform tests.login(blk);
  perform tests.assert(not (a = any (coalesce((select array_agg(id) from public.around_profiles()), '{}'))), 'blocker does not see blocked');

  -- public_profile shape.
  select array_agg(attname::text order by attnum) into cols from pg_attribute
   where attrelid = 'public.public_profile'::regclass and attnum > 0 and not attisdropped;
  perform tests.assert(cols = array['id','first_name','age','pronouns','gender','interests','vibe_tags','prompt_question','prompt_answer',
                                    'intention','availability','photo_paths','photo_review_status','space_id','space_name','session_paused'],
                       'public_profile columns match contract');
  perform tests.login(a);
  perform tests.assert((select space_name from public.around_profiles()) = 'Leavey Library' and
                       (select session_paused from public.around_profiles()) = false, 'around rows carry space name');

  -- Stable order by (session, target): two calls agree.
  select array_agg(id) into o1 from public.around_profiles();
  select array_agg(id) into o2 from public.around_profiles();
  perform tests.assert(o1 = o2, 'around order stable');

  -- Encounters: B leaves, appears in recent_encounters, not in Around; signal still allowed.
  perform tests.login(b); perform public.end_pulse();
  perform tests.login(a);
  perform tests.assert((select count(*) from public.around_profiles()) = 0, 'B gone from Around');
  perform tests.assert((select array_agg(id) from public.recent_encounters()) = array[b], 'B in recent_encounters');
  perform tests.assert((select count(*) from public.encounters) = 1, 'viewer can select own encounters');
  perform tests.assert((public.send_heart_signal(b))->>'result' = 'sent', 'signal via encounter allowed');

  -- Block hides encounter and sent signal.
  perform public.block_user(b);
  perform tests.assert((select count(*) from public.recent_encounters()) = 0, 'blocked user removed from recent_encounters');
  perform tests.assert((select count(*) from public.my_sent_signals()) = 0, 'blocked recipient removed from my_sent_signals');
  perform tests.logout();
  perform tests.assert((select status from public.heart_signals where sender_id = a and recipient_id = b) = 'withdrawn',
                       'block withdraws own pending signal to blocked user');
  perform tests.assert((select count(*) from public.notification_outbox where kind = 'anonymous_signal' and user_id = b and cancelled_at is null) = 0,
                       'pending receipt notification cancelled on block');
end $$;

do $$
declare a uuid; c uuid; d uuid; x uuid; v_report uuid; r record;
begin
  a := tests.make_user('wa'); c := tests.make_user('wc'); d := tests.make_user('wd'); x := tests.make_user('wx');
  perform tests.pulse(a, 'Tutor Campus Center'); perform tests.pulse(c, 'Tutor Campus Center'); perform tests.pulse(d, 'Tutor Campus Center');
  perform tests.pulse(x, 'Tutor Campus Center');
  perform tests.login(c); perform public.send_heart_signal(a);    -- incoming to A
  perform tests.login(a); perform public.send_heart_signal(d);    -- outgoing from A
  perform tests.logout();
  update public.heart_signals set visible_at = now() - interval '1 second';

  perform tests.login(a);
  perform tests.assert((select count(*) from public.my_signal_receipts()) = 1, 'A has one receipt (from C)');
  perform public.block_user(c);
  perform tests.assert((select count(*) from public.my_signal_receipts()) = 0, 'receipt gone after A blocks sender C');
  perform tests.assert((select array_agg(user_id) from public.my_blocks()) = array[c]
                       and (select first_name from public.my_blocks()) = 'Wc', 'my_blocks lists C with first name');
  perform tests.expect_error(format('select public.block_user(%L)', a), 'invalid_input', 'cannot block self');
  perform tests.login(d);
  perform public.block_user(a);   -- recipient blocks sender
  perform tests.login(c);
  perform tests.assert((select count(*) from public.blocks) = 0, 'blocked user cannot see the block row');
  perform tests.logout();
  perform tests.assert((select status from public.heart_signals where sender_id = c and recipient_id = a) = 'withdrawn', 'incoming signal withdrawn on block');
  perform tests.assert((select status from public.heart_signals where sender_id = a and recipient_id = d) = 'withdrawn', 'outgoing signal withdrawn when recipient blocks');

  -- Unblock does not resurrect signals.
  perform tests.login(a); perform public.unblock_user(c);
  perform tests.assert((select count(*) from public.blocks) = 0, 'unblocked');
  perform tests.logout();
  perform tests.assert((select status from public.heart_signals where sender_id = c and recipient_id = a) = 'withdrawn', 'withdrawn stays withdrawn');

  -- Reports.
  perform tests.login(a);
  v_report := public.report_user(x, 'harassment', 'said rude things', '{"screen":"around"}');
  perform tests.assert(v_report is not null, 'report_user returns id');
  perform tests.expect_sqlstate('select * from public.reports', '42501', 'reporter cannot select reports');
  perform tests.assert((select count(*) from public.blocks where blocked_id = x) = 1, 'report also blocks target');
  perform tests.expect_error(format($q$select public.report_user(%L, 'spam', null, '{}')$q$, a), 'invalid_input', 'cannot report self');
  perform tests.login(x);
  perform tests.expect_sqlstate('select * from public.reports', '42501', 'reported user cannot select reports');
  perform tests.expect_sqlstate(format($q$select * from public.reports where id = %L$q$, v_report), '42501', 'reported user cannot select report by id');
  perform tests.logout();
  select * into r from public.reports where id = v_report;
  perform tests.assert(r.reported_snapshot->'profile'->>'first_name' = 'Wx' and r.status = 'open', 'report stores profile snapshot');

  -- Account deletion cascade; reports survive with nulled ids.
  delete from auth.users where id = x;
  select * into r from public.reports where id = v_report;
  perform tests.assert(r.reported_id is null and r.reporter_id = a and r.reported_snapshot ? 'account_deleted_at',
                       'report kept with reported_id nulled + snapshot after reported user deleted');
  perform tests.assert((select count(*) from public.profiles where id = x) = 0
                       and (select count(*) from public.pulse_sessions where user_id = x) = 0
                       and (select count(*) from public.blocks where blocked_id = x) = 0, 'user-owned rows cascade');
  delete from auth.users where id = a;
  perform tests.assert((select reporter_id from public.reports where id = v_report) is null, 'report kept with reporter_id nulled');
  perform tests.assert((select count(*) from public.heart_signals where sender_id = a or recipient_id = a) = 0, 'signals cascade');
end $$;
rollback;
