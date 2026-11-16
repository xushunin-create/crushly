-- Realtime pokes: own private channel only, receive-only, and content-free — so a subscriber whose cached channel
-- authorization outlives an unmatch, block or account deletion can never receive message content.
begin;
do $$
declare
  a uuid; b uuid; x uuid; m uuid; r jsonb; v_body text := 'secret body 7f3a'; v_n int;
begin
  perform tests.make_space('rt-quad');
  a := tests.make_user('rta'); b := tests.make_user('rtb'); x := tests.make_user('rtx');

  -- Channel authorization (evaluated by Realtime when a client subscribes) --------------------------
  perform public.poke(a, 'match', gen_random_uuid());

  perform tests.login(a);
  perform set_config('realtime.topic', 'user:' || a::text, true);
  perform tests.assert((select count(*) from realtime.messages) = 1, 'a user can receive on their own channel');
  perform set_config('realtime.topic', 'user:' || b::text, true);
  perform tests.assert((select count(*) from realtime.messages) = 0, 'a user cannot join someone else''s channel');
  perform set_config('realtime.topic', 'room-1', true);
  perform tests.assert((select count(*) from realtime.messages) = 0, 'no other topics are readable');
  perform tests.expect_sqlstate(
    format($q$insert into realtime.messages (topic, extension, payload, event, private) values ('user:%s', 'broadcast', '{}', 'poke', true)$q$, b),
    '42501', 'clients cannot broadcast');
  perform tests.logout();
  perform tests.login(a);
  perform tests.expect_sqlstate(format('select public.poke(%L, ''message'', gen_random_uuid())', b), '42501',
                                'clients cannot call poke() to spam another user');
  perform tests.logout();
  delete from realtime.messages;

  -- Match creation pokes both, content-free -----------------------------------------------------------
  perform tests.participate(a, 'rt-quad'); perform tests.participate(b, 'rt-quad');
  perform tests.login(a); perform public.express_interest(b);
  perform tests.login(b); r := public.express_interest(a);
  m := (r->>'match_id')::uuid;
  perform tests.logout();
  perform tests.assert((select count(*) from realtime.messages where topic in ('user:' || a, 'user:' || b)
                         and payload = jsonb_build_object('type', 'match', 'match_id', m)) = 2, 'new match pokes both people');
  perform tests.assert((select count(*) from realtime.messages where private and event = 'poke') = (select count(*) from realtime.messages),
                       'every poke is a private broadcast');

  -- Messages poke both, with no content ----------------------------------------------------------------
  perform tests.login(a);
  perform public.send_message(m, gen_random_uuid(), v_body);
  perform tests.logout();
  perform tests.assert((select count(*) from realtime.messages where payload = jsonb_build_object('type', 'message', 'match_id', m)) = 2,
                       'a message pokes both participants');
  perform tests.assert((select count(*) from realtime.messages
                         where not (payload ?& array['type', 'match_id']) or (select count(*) from jsonb_object_keys(payload)) <> 2) = 0,
                       'pokes contain exactly {type, match_id}');
  perform tests.assert((select count(*) from realtime.messages where payload::text like '%' || v_body || '%') = 0,
                       'message text never enters the realtime channel');

  -- A poke failure never breaks sending ------------------------------------------------------------------
  create or replace function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void
  language plpgsql security definer as $f$ begin raise exception 'realtime down'; end $f$;
  perform tests.login(b);
  perform public.send_message(m, gen_random_uuid(), 'still delivered');
  perform tests.logout();
  perform tests.assert(tests.n(format('select 1 from public.messages where match_id = %L', m)) = 2, 'send succeeds even if realtime fails');
  create or replace function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void
  language plpgsql security definer as $f$
  begin
    insert into realtime.messages (topic, extension, payload, event, private)
    values (send.topic, 'broadcast', send.payload, send.event, send.private);
  end $f$;

  -- Still-connected subscriber after BLOCK ---------------------------------------------------------------
  -- b's channel authorization stays cached by Realtime. Everything b could still receive is content-free,
  -- and every content path now refuses b.
  delete from realtime.messages;
  perform tests.login(a); perform public.block_user(b);
  perform tests.logout();
  perform tests.assert((select count(*) from realtime.messages where payload = jsonb_build_object('type', 'conversation_removed', 'match_id', m)) = 2,
                       'block pokes conversation_removed to both');
  perform tests.login(b);
  perform tests.expect_error(format('select * from public.fetch_messages(%L)', m), 'not_found', 'after block: no history for the old subscriber');
  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), 'hi')$q$, m), 'not_found', 'after block: no sends');
  perform tests.login(a);
  perform tests.expect_error(format($q$select * from public.send_message(%L, gen_random_uuid(), 'hi')$q$, m), 'not_found', 'blocker cannot send either');
  perform tests.logout();
  perform tests.assert((select count(*) from realtime.messages where topic = 'user:' || b and payload->>'type' = 'message') = 0,
                       'no message pokes reach the blocked user afterwards');

  -- Still-connected subscriber after LEAVE ---------------------------------------------------------------
  perform tests.login(a); perform public.unblock_user(b); perform tests.logout();
  perform tests.reset_rate_limits();
  perform tests.participate(a, 'rt-quad'); perform tests.participate(b, 'rt-quad');
  perform tests.login(a); perform public.express_interest(b);
  perform tests.login(b); r := public.express_interest(a); m := (r->>'match_id')::uuid;
  perform public.send_message(m, gen_random_uuid(), v_body);
  perform tests.logout();
  delete from realtime.messages where true;
  perform tests.login(b); perform public.leave_conversation(m);
  perform tests.logout();
  perform tests.assert((select count(*) from realtime.messages where payload = jsonb_build_object('type', 'conversation_removed', 'match_id', m)) = 2,
                       'leave pokes conversation_removed to both');
  perform tests.login(a);
  perform tests.expect_error(format('select * from public.fetch_messages(%L)', m), 'not_found', 'after leave: the other person loses the history too');

  -- Still-connected subscriber after ACCOUNT DELETION -------------------------------------------------
  perform tests.logout();
  perform tests.reset_rate_limits();
  perform tests.participate(a, 'rt-quad'); perform tests.participate(x, 'rt-quad');
  perform tests.login(a); perform public.express_interest(x);
  perform tests.login(x); r := public.express_interest(a); m := (r->>'match_id')::uuid;
  perform public.send_message(m, gen_random_uuid(), v_body);
  perform tests.logout();
  delete from realtime.messages where true;
  delete from auth.users where id = x;
  perform tests.assert((select count(*) from realtime.messages where topic = 'user:' || a
                         and payload = jsonb_build_object('type', 'conversation_removed', 'match_id', m)) = 1,
                       'account deletion pokes conversation_removed to the other person');
  perform tests.login(a);
  perform tests.expect_error(format('select * from public.fetch_messages(%L)', m), 'not_found', 'after deletion: history is gone');
  perform tests.assert((select count(*) from public.my_conversations() where match_id = m) = 0, 'after deletion: conversation is gone');
  perform tests.logout();
  perform tests.assert((select count(*) from realtime.messages where payload::text like '%' || v_body || '%') = 0,
                       'no realtime payload ever carried message text');
end $$;
rollback;
