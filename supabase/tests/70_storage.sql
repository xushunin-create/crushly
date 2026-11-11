-- Exercises the profile-photos policies against the stubbed storage.objects table.
begin;
do $$
declare a uuid; b uuid; n int;
begin
  a := tests.make_user('pa'); b := tests.make_user('pb');
  perform tests.assert((select public from storage.buckets where id = 'profile-photos') = false, 'profile-photos bucket is private');
  perform tests.login(a);
  insert into storage.objects (bucket_id, name, owner) values ('profile-photos', a::text || '/one.jpg', a);
  perform tests.assert(true, 'owner can upload into own folder');
  perform tests.expect_sqlstate(format($q$insert into storage.objects (bucket_id, name, owner) values ('profile-photos', '%s/evil.jpg', %L)$q$, b, a),
                                '42501', 'cannot upload into another folder');
  perform tests.expect_sqlstate(format($q$insert into storage.objects (bucket_id, name, owner) values ('profile-photos', 'loose.jpg', %L)$q$, a),
                                '42501', 'cannot upload outside a user folder');
  perform tests.login(b);
  perform tests.assert((select count(*) from storage.objects where name like a::text || '/%') = 0, 'stranger cannot read photos');
  delete from storage.objects where name like a::text || '/%';
  get diagnostics n = row_count;
  perform tests.assert(n = 0, 'stranger cannot delete photos');
  perform tests.pulse(a, 'Leavey Library'); perform tests.pulse(b, 'Leavey Library');
  perform tests.assert((select count(*) from storage.objects where name like a::text || '/%') = 1, 'discoverable user can read photos');
  perform tests.login(a);
  perform public.block_user(b);
  perform tests.login(b);
  perform tests.assert((select count(*) from storage.objects where name like a::text || '/%') = 0, 'blocked user cannot read photos');
  perform tests.login(a);
  delete from storage.objects where name = a::text || '/one.jpg';
  get diagnostics n = row_count;
  perform tests.assert(n = 1, 'owner can delete own photo');
end $$;
rollback;
