-- Run ONCE in Supabase dashboard → SQL Editor, after custom SMTP works and the app build without the dev
-- sign-in bypass is installed. Deletes the dev bypass account and anything hanging off it (cascades through
-- profiles, participation, matches, messages). Then run verify_production.sql: item 7 should PASS.
--
-- If you created extra test accounts with the old create_dev_user.sql, they also have a password set;
-- the second statement lists them so you can decide (OTP-only accounts never have one).

delete from auth.users where email = 'crushly-dev@usc.edu' returning id, email;

select id, email, created_at from auth.users where coalesce(encrypted_password, '') <> '';
