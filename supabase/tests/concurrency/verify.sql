do $$
declare r record; v_gap interval;
begin
  for r in select * from tests.conc_pairs order by n loop
    select max(created_at) - min(created_at) into v_gap from public.heart_signals
     where (sender_id = r.a and recipient_id = r.b) or (sender_id = r.b and recipient_id = r.a);
    perform tests.assert(v_gap < interval '2 seconds',
      format('pair %s: both transactions overlapped (start gap %s < 2s sleep)', r.n, v_gap));
    perform tests.assert((select count(*) from public.matches
                           where user_a = least(r.a, r.b) and user_b = greatest(r.a, r.b)) = 1,
      format('pair %s: exactly one match', r.n));
    perform tests.assert((select count(*) from public.connections c join public.matches m on m.id = c.match_id
                           where m.user_a = least(r.a, r.b) and m.user_b = greatest(r.a, r.b)) = 1,
      format('pair %s: exactly one connection', r.n));
    perform tests.assert((select count(*) from public.heart_signals hs
                           where ((hs.sender_id = r.a and hs.recipient_id = r.b) or (hs.sender_id = r.b and hs.recipient_id = r.a))
                             and hs.status = 'matched'
                             and hs.match_id = public.match_between(r.a, r.b)) = 2,
      format('pair %s: both signals matched to that match', r.n));
  end loop;
end $$;
