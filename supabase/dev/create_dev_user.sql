-- DEV ONLY — remove before launch. NOT a migration; run once by hand in the
-- Supabase dashboard → SQL Editor.
-- Creates (or repairs) a confirmed account the app's "Dev: skip sign-in" button
-- signs into with a fixed password, so no email is ever sent.
-- To add another test account, change v_email and run again.
do $$
declare
  v_email    text := 'crushly-dev@usc.edu';
  v_password text := 'crushly-dev-bypass-password';  -- must match SupabaseBackend.devPassword
  v_id       uuid;
begin
  select id into v_id from auth.users where email = v_email;

  if v_id is null then
    v_id := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) values (
      '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
      extensions.crypt(v_password, extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(),
      '', '', '', ''
    );
    insert into auth.identities (
      id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(), v_id, v_id::text,
      jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true),
      'email', now(), now(), now()
    );
  else
    -- Existing account (e.g. created by an earlier attempt): confirm it and set the dev password.
    update auth.users
       set encrypted_password = extensions.crypt(v_password, extensions.gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()),
           updated_at = now()
     where id = v_id;
  end if;
end $$;
