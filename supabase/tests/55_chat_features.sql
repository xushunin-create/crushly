-- Chat features: replies, reactions, unsend, screenshot notices. Participant-only, text-only, content-free pokes.
begin;
do $$
declare
  a uuid; b uuid; x uuid; m uuid; r jsonb; v1 uuid; v2 uuid; v3 uuid; v_shot uuid; v_row record; v_pokes bigint;
begin
  perform tests.make_space('chat-quad');
  a := tests.make_user('ra'); b := tests.make_user('rb'); x := tests.make_user('rx');
  perform tests.participate(a, 'chat-quad'); perform tests.participate(b, 'chat-quad');
  perform tests.login(a); perform public.express_interest(b);
  perform tests.login(b); r := public.express_interest(a);
  m := (r->>'match_id')::uuid;

  -- Replies ---------------------------------------------------------------------------------------
  perform tests.login(a);
  v1 := gen_random_uuid();
  perform public.send_message(m, v1, 'want to get coffee?');
  perform tests.login(b);
  v2 := gen_random_uuid();
  perform public.send_message(m, v2, 'yes!', v1);
  select * into v_row from public.fetch_messages(m) f where f.id = v2;
  perform tests.assert(v_row.reply_to_id = v1 and v_row.reply_body = 'want to get coffee?' and not v_row.reply_sender_is_me
                       and not v_row.reply_deleted and v_row.kind = 'text', 'a reply carries a preview of the quoted message');
  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), 'x', %L)$q$, m, gen_random_uuid()),
                             'invalid_input', 'cannot reply to an unknown message');
  -- Old three-argument callers still work.
  perform public.send_message(p_match_id => m, p_client_message_id => gen_random_uuid(), p_body => 'still works');

  -- Reactions -------------------------------------------------------------------------------------
  perform public.react_to_message(v1, '❤️');
  select * into v_row from public.fetch_messages(m) f where f.id = v1;
  perform tests.assert(v_row.reactions = '[{"emoji": "❤️", "mine": true}]'::jsonb, 'reaction is returned, marked as mine');
  perform public.react_to_message(v1, '😂');
  perform tests.assert(tests.n(format('select 1 from public.message_reactions where message_id = %L', v1)) = 1,
                       'one reaction per person per message (replaced, not added)');
  perform tests.login(a);
  perform public.react_to_message(v1, '👍');
  select * into v_row from public.fetch_messages(m) f where f.id = v1;
  perform tests.assert(jsonb_array_length(v_row.reactions) = 2
                       and v_row.reactions @> '[{"emoji": "😂", "mine": false}, {"emoji": "👍", "mine": true}]'::jsonb,
                       'both people''s reactions are visible, each marked correctly');
  perform public.react_to_message(v1, null);
  perform tests.assert(tests.n(format('select 1 from public.message_reactions where message_id = %L and user_id = %L', v1, a)) = 0,
                       'a null emoji removes my reaction');
  perform tests.expect_error(format($q$select public.react_to_message(%L, 'hello')$q$, v1), 'invalid_input', 'reactions cannot carry text');
  perform tests.expect_error(format($q$select public.react_to_message(%L, '%s')$q$, v1, repeat('❤', 17)), 'invalid_input', 'reaction length is capped');

  -- Unsend ----------------------------------------------------------------------------------------
  perform tests.login(b);
  perform tests.expect_error(format('select public.unsend_message(%L)', v1), 'not_found', 'cannot unsend someone else''s message');
  perform tests.login(a);
  v3 := gen_random_uuid();
  perform public.send_message(m, v3, 'oops wrong chat');
  perform public.unsend_message(v1);
  perform public.unsend_message(v1);   -- idempotent
  perform tests.logout();
  perform tests.assert((select body = '' and deleted_at is not null from public.messages where id = v1), 'unsend erases the text in storage');
  perform tests.assert(tests.n(format('select 1 from public.message_reactions where message_id = %L', v1)) = 0, 'unsend removes reactions');
  perform tests.login(b);
  select * into v_row from public.fetch_messages(m) f where f.id = v1;
  perform tests.assert(v_row.deleted and v_row.body = '', 'the other person sees an unsent placeholder, no text');
  select * into v_row from public.fetch_messages(m) f where f.id = v2;
  perform tests.assert(v_row.reply_deleted and v_row.reply_body = '', 'replies to an unsent message no longer quote its text');
  perform tests.expect_error(format($q$select public.react_to_message(%L, '❤️')$q$, v1), 'invalid_input', 'cannot react to an unsent message');
  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), 'x', %L)$q$, m, v1),
                             'invalid_input', 'cannot reply to an unsent message');
  -- The inbox preview skips unsent messages.
  perform tests.login(a);
  perform public.unsend_message(v3);
  perform tests.login(b);
  perform tests.assert((select last_message_preview from public.my_conversations() where match_id = m) = 'still works',
                       'conversation preview falls back to the latest message that is still there');

  -- Screenshot notices ----------------------------------------------------------------------------
  select * into v_row from public.record_screenshot(m);
  v_shot := v_row.id;
  select * into v_row from public.record_screenshot(m);
  perform tests.assert(v_row.id = v_shot, 'a burst of screenshots is recorded once');
  perform tests.login(a);
  select * into v_row from public.fetch_messages(m) f where f.id = v_shot;
  perform tests.assert(v_row.kind = 'screenshot' and v_row.body = '' and not v_row.sender_is_me, 'the other person sees the screenshot notice');
  perform tests.assert((select last_message_kind = 'screenshot' and last_message_preview is null and unread
                          from public.my_conversations() where match_id = m), 'the inbox shows the screenshot notice as unread');
  perform tests.login(b);
  perform tests.expect_error(format('select public.unsend_message(%L)', v_shot), 'invalid_input', 'a screenshot notice cannot be unsent');
  perform tests.expect_error(format($q$select public.react_to_message(%L, '❤️')$q$, v_shot), 'invalid_input', 'cannot react to a notice');
  perform tests.expect_error(format($q$select public.report_user(%L, 'harassment', 'x', array[%L]::uuid[])$q$, a, v1),
                             'invalid_input', 'unsent messages cannot be submitted as evidence');

  -- Outsiders --------------------------------------------------------------------------------------
  perform tests.login(x);
  perform tests.expect_error(format($q$select public.react_to_message(%L, '❤️')$q$, v2), 'not_found', 'outsider cannot react');
  perform tests.expect_error(format('select public.unsend_message(%L)', v2), 'not_found', 'outsider cannot unsend');
  perform tests.expect_error(format('select * from public.record_screenshot(%L)', m), 'not_found', 'outsider cannot record a screenshot');
  perform tests.expect_sqlstate('select * from public.message_reactions', '42501', 'reactions are not directly readable');

  -- Realtime: reactions and unsends poke both people, without content ------------------------------
  perform tests.logout();
  v_pokes := (select count(*) from realtime.messages);
  perform tests.login(a);
  perform public.react_to_message(v2, '‼️');
  perform tests.logout();
  perform tests.assert((select count(*) from realtime.messages) = v_pokes + 2, 'a reaction pokes both participants');
  perform tests.assert((select count(*) from realtime.messages where payload::text like '%‼️%') = 0, 'pokes carry no reaction content');

  -- Blocking hides everything -----------------------------------------------------------------------
  perform tests.login(a);
  perform public.block_user(b);
  perform tests.assert(tests.n(format('select 1 from public.message_reactions r join public.messages msg on msg.id = r.message_id where msg.match_id = %L', m)) = 0,
                       'reactions are deleted with the conversation');
end $$;
rollback;
