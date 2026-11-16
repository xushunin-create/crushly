-- Conversations: participant-only access, idempotent sends, leave & delete, block, report evidence.
begin;
do $$
declare
  a uuid; b uuid; x uuid; m uuid; m2 uuid; r jsonb; v_id uuid; v_id2 uuid; v_rep uuid; v_n int; v_row record;
begin
  perform tests.make_space('quad');
  a := tests.make_user('ca'); b := tests.make_user('cb'); x := tests.make_user('cx');

  -- Make a match the normal way.
  perform tests.participate(a, 'quad'); perform tests.participate(b, 'quad');
  perform tests.login(a); perform public.express_interest(b);
  perform tests.login(b); r := public.express_interest(a);
  m := (r->>'match_id')::uuid;

  -- Conversations stay available after both leave the space and need no participation.
  perform tests.login(a); perform public.revoke_participation();
  perform tests.login(b); perform public.revoke_participation();

  -- Sending and reading -------------------------------------------------------------------------
  perform tests.login(a);
  v_id := gen_random_uuid();
  select * into v_row from public.send_message(m, v_id, '  hey!  ');
  perform tests.assert(v_row.id = v_id, 'send returns the client id');
  perform tests.assert(tests.val(format('select body from public.messages where id = %L', v_id)) = 'hey!', 'body is trimmed');
  perform tests.assert(tests.val(format('select sender_id from public.messages where id = %L', v_id))::uuid = a, 'sender is always the caller');

  -- Retry with the same id is idempotent.
  select * into v_row from public.send_message(m, v_id, 'hey!');
  perform tests.assert(tests.n(format('select 1 from public.messages where match_id = %L', m)) = 1, 'retry does not duplicate');

  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), '   ')$q$, m), 'invalid_input', 'empty message rejected');
  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), %L)$q$, m, repeat('x', 2001)),
                             'invalid_input', 'message over 2000 chars rejected');
  perform tests.expect_error(format($q$select * from public.send_message(%L, null, 'x')$q$, m), 'invalid_input', 'message id required');

  perform tests.login(b);
  perform tests.assert((select count(*) from public.my_conversations() where match_id = m and unread) = 1, 'unread flag for the recipient');
  perform tests.assert((select (other).id from public.my_conversations() where match_id = m) = a, 'conversation shows the other person');
  perform tests.assert((select count(*) from public.fetch_messages(m) where not sender_is_me) = 1, 'recipient can fetch');
  perform public.mark_conversation_read(m);
  perform tests.assert((select count(*) from public.my_conversations() where match_id = m and unread) = 0, 'mark read clears unread');
  perform tests.assert(tests.n(format($q$select 1 from public.notification_outbox where kind = 'new_message' and user_id = %L$q$, b)) = 1,
                       'recipient gets one generic new-message push');
  perform tests.assert(tests.n($q$select 1 from public.notification_outbox where payload::text like '%hey%'$q$) = 0,
                       'no message text in notification payloads');

  -- A forged id collision cannot hijack someone else's message.
  perform tests.expect_error(format($q$select * from public.send_message(%L, %L, 'mine now')$q$, m, v_id), 'invalid_input',
                             'reusing another sender''s message id is rejected');

  -- Pagination ----------------------------------------------------------------------------------
  for i in 1..60 loop
    perform tests.reset_rate_limits();
    perform public.send_message(m, gen_random_uuid(), 'msg ' || i);
  end loop;
  perform tests.assert((select count(*) from public.fetch_messages(m)) = 50, 'first page is capped at 50');
  select f.created_at, f.id into v_row from public.fetch_messages(m) f order by f.created_at asc, f.id asc limit 1;
  perform tests.assert((select count(*) from public.fetch_messages(m, v_row.created_at, v_row.id)) = 11, 'second page continues with older messages');
  perform tests.expect_error(format($q$select * from public.fetch_messages(%L, now(), null)$q$, m), 'invalid_input', 'half a cursor is rejected');
  perform tests.reset_rate_limits();

  -- Outsiders: guessed ids get nothing ----------------------------------------------------------
  perform tests.login(x);
  perform tests.expect_error(format('select * from public.fetch_messages(%L)', m), 'not_found', 'outsider cannot read a conversation');
  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), 'hi')$q$, m), 'not_found', 'outsider cannot post');
  perform tests.expect_error(format('select public.leave_conversation(%L)', m), 'not_found', 'outsider cannot delete');
  perform tests.expect_error(format('select public.mark_conversation_read(%L)', m), 'not_found', 'outsider cannot mark read');
  perform tests.assert((select count(*) from public.my_conversations()) = 0, 'outsider has no conversations');

  -- Message rate limit ----------------------------------------------------------------------------
  perform tests.login(a);
  perform tests.reset_rate_limits();
  for i in 1..20 loop perform public.send_message(m, gen_random_uuid(), 'burst'); end loop;
  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), 'one too many')$q$, m),
                             'rate_limited', 'messages are rate-limited');
  perform tests.reset_rate_limits();

  -- Report with selected evidence -----------------------------------------------------------------
  perform tests.login(b);
  v_id2 := tests.val(format($q$select id from public.messages where match_id = %L and body = 'burst' limit 1$q$, m))::uuid;
  perform tests.expect_error(format($q$select public.report_user(%L, 'harassment', 'x', array[%L]::uuid[])$q$, a, gen_random_uuid()),
                             'invalid_input', 'evidence must come from this conversation');
  v_rep := public.report_user(a, 'harassment', 'see these', array[v_id, v_id2]);
  perform tests.logout();
  perform tests.assert((select count(*) from public.report_evidence where report_id = v_rep) = 2, 'only the selected messages are submitted');
  perform tests.assert((select bool_and(sent_by_reported) from public.report_evidence where report_id = v_rep), 'evidence records who sent it');
  perform tests.assert((select purge_after::date from public.report_evidence where report_id = v_rep limit 1) = (now() + interval '90 days')::date,
                       'evidence has a 90-day purge date');
  -- Reporting also blocks, which deletes the conversation for both.
  perform tests.assert((select count(*) from public.matches where id = m) = 0, 'report + block ends the match');
  perform tests.assert((select count(*) from public.messages where match_id = m) = 0, 'conversation history deleted from active storage');
  perform tests.assert((select count(*) from public.deletion_tombstones where match_id = m) = 1, 'id-only tombstone kept for restores');
  perform tests.assert((select count(*) from public.notification_outbox where payload->>'match_id' = m::text and sent_at is null and cancelled_at is null) = 0,
                       'queued pushes for the deleted conversation are cancelled');
  perform tests.login(a);
  perform tests.expect_error(format('select * from public.fetch_messages(%L)', m), 'not_found', 'deleted conversation unreadable');
  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), 'still there?')$q$, m),
                             'not_found', 'a queued send cannot recreate a deleted conversation');
  perform tests.expect_error(format($q$select * from public.send_message(%L, %L, 'hey!')$q$, m, v_id),
                             'not_found', 'a retry of an old message cannot recreate it');
  perform tests.login(b);
  perform public.unblock_user(a);

  -- Leave & delete, then a fresh match is a NEW conversation ------------------------------------
  perform tests.participate(a, 'quad'); perform tests.participate(b, 'quad');
  perform tests.login(a); perform public.express_interest(b);
  perform tests.login(b); m2 := (public.express_interest(a)->>'match_id')::uuid;
  perform tests.assert(m2 <> m, 'rematch gets a new id; the old conversation is not reopened');
  perform tests.assert((select count(*) from public.fetch_messages(m2)) = 0, 'new conversation starts empty');
  perform public.send_message(m2, gen_random_uuid(), 'round two');
  perform public.leave_conversation(m2);
  perform tests.assert((select count(*) from public.my_conversations()) = 0, 'leaving removes it for me');
  perform tests.login(a);
  perform tests.assert((select count(*) from public.my_conversations()) = 0, 'leaving removes it for them too');
  perform tests.expect_error(format('select public.leave_conversation(%L)', m2), 'not_found', 'leaving twice reports not_found');
  perform tests.logout();
  perform tests.assert((select count(*) from public.messages where match_id = m2) = 0, 'messages deleted on leave');

  -- Block ends an active conversation too.
  perform tests.participate(a, 'quad'); perform tests.participate(b, 'quad');
  perform tests.login(a); perform public.express_interest(b);
  perform tests.login(b); m2 := (public.express_interest(a)->>'match_id')::uuid;
  perform tests.login(a); perform public.block_user(b);
  perform tests.login(b);
  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), 'hello?')$q$, m2), 'not_found', 'blocked: cannot message');
  perform tests.assert((select count(*) from public.my_conversations()) = 0, 'blocked: conversation gone');

  -- Account deletion -----------------------------------------------------------------------------
  perform tests.login(a); perform public.unblock_user(b);
  perform tests.participate(a, 'quad'); perform tests.participate(b, 'quad');
  perform tests.login(a); perform public.express_interest(b);
  perform tests.login(b); m2 := (public.express_interest(a)->>'match_id')::uuid;
  perform public.send_message(m2, gen_random_uuid(), 'bye');
  perform tests.logout();
  delete from auth.users where id = b;
  perform tests.assert((select count(*) from public.matches where id = m2) = 0 and (select count(*) from public.messages where match_id = m2) = 0,
                       'account deletion removes matches and messages');
  perform tests.assert((select count(*) from public.reports where reporter_id is null and id = v_rep) = 1, 'reports survive with the reporter id nulled');
end $$;
rollback;
