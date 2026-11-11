-- Phase 7: notification queueing, send-time relevance and dispatcher permissions.
begin;
do $$
declare a uuid; b uuid; c uuid; v_match uuid; res jsonb; fr public.find_requests; n int; claimed int;
begin
  a := tests.make_user('na'); b := tests.make_user('nb'); c := tests.make_user('nc');
  -- Device tokens for everyone so claims aren't cancelled for "no device".
  insert into public.device_tokens (token, user_id, apns_env) values ('tok-a', a, 'sandbox'), ('tok-b', b, 'sandbox'), ('tok-c', c, 'sandbox');
  perform tests.pulse(a, 'Leavey Library'); perform tests.pulse(b, 'Leavey Library'); perform tests.pulse(c, 'Leavey Library');

  -- Clients can never touch the dispatcher API.
  perform tests.login(a);
  perform tests.expect_sqlstate('select * from public.claim_due_notifications(10)', '42501', 'clients cannot claim notifications');
  perform tests.expect_sqlstate($q$select public.forget_device_token('tok-b')$q$, '42501', 'clients cannot delete tokens');
  perform tests.expect_sqlstate('select count(*) from public.notification_outbox', '42501', 'clients cannot read the outbox');

  -- A one-sided signal queues an anonymous notification for later; the payload never names the sender.
  perform public.send_heart_signal(c);
  perform tests.logout();
  select count(*) into n from public.notification_outbox o where o.user_id = c and o.kind = 'anonymous_signal';
  perform tests.assert(n = 1, 'anonymous signal queued for recipient');
  perform tests.assert(not exists (select 1 from public.notification_outbox o where o.user_id = c and o.payload::text like '%' || a::text || '%'),
                       'anonymous notification payload has no sender id');
  perform tests.assert((select deliver_after from public.notification_outbox o where o.user_id = c and o.kind = 'anonymous_signal') > now(),
                       'anonymous notification waits for the receipt delay');

  -- Not due yet → not claimed.
  select count(*) into claimed from public.claim_due_notifications(100) x where x.user_id = c;
  perform tests.assert(claimed = 0, 'undue notifications are not claimed');

  -- Make it due, then block: the send-time check cancels it.
  update public.notification_outbox set deliver_after = now() - interval '1 minute' where user_id = c and kind = 'anonymous_signal';
  perform tests.login(c); perform public.block_user(a); perform tests.logout();
  select count(*) into claimed from public.claim_due_notifications(100) x where x.user_id = c;
  perform tests.assert(claimed = 0, 'blocked sender: anonymous notification suppressed');
  perform tests.assert((select cancelled_at is not null from public.notification_outbox where user_id = c and kind = 'anonymous_signal'),
                       'suppressed notification is cancelled, not retried');

  -- Mutual match: both get exactly one discreet notification; it is claimable and can be marked sent.
  perform tests.login(a); perform public.send_heart_signal(b);
  perform tests.login(b); res := public.send_heart_signal(a); v_match := (res->>'match_id')::uuid;
  perform tests.logout();
  select count(*) into n from public.notification_outbox o where o.kind = 'heart_sync' and (o.payload->>'match_id')::uuid = v_match;
  perform tests.assert(n = 2, 'one heart_sync notification per participant');
  perform tests.assert(not exists (select 1 from public.notification_outbox o where o.user_id = b and o.kind = 'anonymous_signal'
                                     and o.cancelled_at is null), 'anonymous receipt superseded by the match');
  select count(*) into claimed from public.claim_due_notifications(100) x where x.kind = 'heart_sync';
  perform tests.assert(claimed = 2, 'both heart_sync notifications claimed');
  perform tests.assert((select bool_and(jsonb_array_length(x.tokens) = 1) from (
    select o.user_id, (select jsonb_agg(t.token) from public.device_tokens t where t.user_id = o.user_id) as tokens
      from public.notification_outbox o where o.kind = 'heart_sync') x), 'tokens returned per recipient');
  perform public.mark_notifications_sent(array(select o.id from public.notification_outbox o where o.kind = 'heart_sync'));
  select count(*) into claimed from public.claim_due_notifications(100) x where x.kind = 'heart_sync';
  perform tests.assert(claimed = 0, 'sent notifications are never claimed again');

  -- Find accepted notifies the requester.
  perform tests.login(a); fr := public.request_find(v_match, 'Tommy Trojan');
  perform tests.login(b); perform public.respond_find(fr.id, true);
  perform tests.logout();
  perform tests.assert(exists (select 1 from public.notification_outbox o where o.user_id = a and o.kind = 'find_accepted'),
                       'requester notified when meet request is accepted');
  perform tests.assert(not exists (select 1 from public.notification_outbox o where o.user_id = b and o.kind = 'find_accepted'),
                       'accepter is not notified of their own acceptance');

  -- A stale find_request notification (already answered) is suppressed at send time.
  update public.notification_outbox set sent_at = null, cancelled_at = null where kind = 'find_request' and user_id = b;
  select count(*) into claimed from public.claim_due_notifications(100) x where x.kind = 'find_request';
  perform tests.assert(claimed = 0, 'answered meet request: notification suppressed');

  -- Preferences turned off after queueing are respected at send time.
  update public.notification_prefs set find_requests = false where user_id = a;
  insert into public.notification_prefs (user_id, find_requests) values (a, false)
    on conflict (user_id) do update set find_requests = false;
  update public.notification_outbox set sent_at = null, cancelled_at = null, attempts = 0 where kind = 'find_accepted' and user_id = a;
  select count(*) into claimed from public.claim_due_notifications(100) x where x.kind = 'find_accepted';
  perform tests.assert(claimed = 0, 'disabled preference: notification suppressed');

  -- No device token → cancelled instead of retried forever.
  delete from public.device_tokens where user_id = b;
  perform public.enqueue_notification(b, 'connection_reminder', 'test-no-device', jsonb_build_object('match_id', v_match), now());
  perform public.claim_due_notifications(100);
  perform tests.assert((select cancelled_at is not null from public.notification_outbox where dedupe_key = 'test-no-device'),
                       'no device: cancelled');

  -- Unknown kinds are never sent; dead tokens can be forgotten.
  perform tests.assert(not public.pref_enabled(a, 'mystery_kind'), 'unknown kind disabled');
  perform public.forget_device_token('tok-a');
  perform tests.assert(not exists (select 1 from public.device_tokens where token = 'tok-a'), 'dead token removed');
end $$;
rollback;
