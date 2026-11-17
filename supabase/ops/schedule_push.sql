-- Schedules push-dispatch every minute (docs/NOTIFICATIONS.md step 4). Run in the SQL Editor AFTER:
--   * pg_cron and pg_net are enabled,
--   * push-dispatch is deployed (Verify JWT OFF) with its 5 secrets, and
--   * the Vault secret exists. Create it once, with the SAME value as the PUSH_DISPATCH_SECRET function secret:
--       select vault.create_secret('<paste PUSH_DISPATCH_SECRET>', 'push_dispatch_secret');
-- Safe to re-run: replaces an existing crushly-push job.

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'push_dispatch_secret') then
    raise exception 'Create the Vault secret push_dispatch_secret first (see the comment at the top).';
  end if;
  if exists (select 1 from cron.job where jobname = 'crushly-push') then
    perform cron.unschedule('crushly-push');
  end if;
  perform cron.schedule('crushly-push', '* * * * *', $job$
    select net.http_post(
      url := 'https://cgqwbgsnnxioowdtxzls.supabase.co/functions/v1/push-dispatch',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-dispatch-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_dispatch_secret')),
      body := '{}'::jsonb)
  $job$);
end $$;

-- After a couple of minutes, check the dispatcher's responses (expect status_code 200):
-- select id, status_code, left(content, 200) as content, created from net._http_response order by created desc limit 5;
select jobname, schedule, active from cron.job order by jobname;
