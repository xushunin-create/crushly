begin;
do $$
declare v uuid;
begin
  perform tests.expect_error($q$insert into auth.users (email) values ('someone@gmail.com')$q$, 'domain_not_allowed', 'gmail rejected');
  perform tests.expect_error($q$insert into auth.users (email) values ('a@evilusc.edu')$q$, 'domain_not_allowed', 'lookalike domain rejected');
  perform tests.expect_error($q$insert into auth.users (email) values ('a@usc.edu.evil.com')$q$, 'domain_not_allowed', 'suffix trick rejected');
  perform tests.expect_error($q$insert into auth.users (email) values ('a@sub.usc.edu')$q$, 'domain_not_allowed', 'subdomain not in allow-list rejected');
  perform tests.expect_error($q$insert into auth.users (email) values (null)$q$, 'domain_not_allowed', 'null email rejected');
  perform tests.expect_error($q$insert into auth.users (email) values ('no-at-sign')$q$, 'domain_not_allowed', 'malformed email rejected');

  insert into auth.users (email) values ('Tommy.Trojan@USC.EDU') returning id into v;
  perform tests.assert(v is not null, 'mixed-case allowed domain accepted');
  perform tests.expect_error(format($q$update auth.users set email = 'tommy@ucla.edu' where id = %L$q$, v),
                             'domain_not_allowed', 'email change to other domain rejected');

  -- university_domain is derived server-side even if a client inserts its own profile.
  perform tests.login(v);
  insert into public.profiles (id, first_name) values (v, 'Tommy');
  perform tests.expect_sqlstate(format($q$insert into public.profiles (id, first_name, university_domain) values (%L, 'x', 'mit.edu')$q$, gen_random_uuid()),
                                '42501', 'client cannot write university_domain');
  perform tests.logout();
  perform tests.assert((select university_domain from public.profiles where id = v) = 'usc.edu', 'university_domain derived (lower-case) from email');

  -- Allow-list is data-driven.
  update public.app_settings set value = '["usc.edu","ucla.edu"]' where key = 'allowed_email_domains';
  insert into auth.users (email) values ('joe@ucla.edu');
  perform tests.assert(true, 'domain added to app_settings is accepted');
end $$;
rollback;
