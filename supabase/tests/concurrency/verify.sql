do $$
declare r record;
begin
  for r in select * from tests.conc_pairs order by n loop
    perform tests.assert((select count(*) from public.matches
                           where user_a = least(r.a, r.b) and user_b = greatest(r.a, r.b)) = 1,
      format('pair %s: exactly one match from simultaneous reciprocal interest', r.n));
    perform tests.assert((select count(*) from public.interests i
                            join public.participation_sessions s on s.id in (i.sender_session_id, i.recipient_session_id)
                           where s.user_id in (r.a, r.b)) = 0,
      format('pair %s: no leftover interests', r.n));
  end loop;
end $$;
