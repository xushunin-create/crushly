create table tests.conc_pairs (n int primary key, a uuid not null, b uuid not null);
do $$
declare i int; a uuid; b uuid;
begin
  for i in 1..5 loop
    a := tests.make_user('conc_a' || i);
    b := tests.make_user('conc_b' || i);
    perform tests.pulse(a, 'Leavey Library');
    perform tests.pulse(b, 'Leavey Library');
    perform tests.logout();
    insert into tests.conc_pairs values (i, a, b);
  end loop;
end $$;
