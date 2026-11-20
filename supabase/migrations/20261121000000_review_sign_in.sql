-- Rate limit for the App Review sign-in edge function (supabase/functions/review-sign-in).
-- Every attempt, right or wrong, counts against the reviewer account's user id, so the 6-digit code
-- can't be brute-forced: 10 per hour, 30 per day.

update public.app_settings
   set value = value || '{"review_sign_in": [[10, 3600], [30, 86400]]}'::jsonb
 where key = 'rate_limits';
