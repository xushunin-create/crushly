-- Production readiness check (docs/PRE_LAUNCH_CHECKLIST.md). READ-ONLY: changes nothing.
-- Paste the whole file into Supabase dashboard → SQL Editor → Run. Every row should say PASS;
-- rows marked CHECK need a human comparison (e.g. against the dashboard's backup retention).
--
-- Not checkable from SQL (do these in the dashboard): JWT expiry, custom SMTP + {{ .Token }} template,
-- OTP rate limits, Realtime "Allow public access" OFF, edge function deploys and their Verify JWT settings,
-- edge function secrets.

drop table if exists pg_temp.crushly_checks;
create temp table crushly_checks (n int, item text, expected text, actual text, result text);

do $$
declare
  v text;
  has_cron boolean := to_regclass('cron.job') is not null;
  has_mig  boolean := to_regclass('supabase_migrations.schema_migrations') is not null;
  missing  text;
begin
  -- 1. allow_draft_spaces
  select value::text into v from public.app_settings where key = 'allow_draft_spaces';
  insert into crushly_checks values (1, 'allow_draft_spaces', 'false', coalesce(v, '(missing)'),
    case when v = 'false' then 'PASS' else 'FAIL' end);

  -- 2. tombstone retention (compare with Project Settings → Database → Backups)
  select value::text into v from public.app_settings where key = 'deletion_tombstone_retention_days';
  insert into crushly_checks values (2, 'deletion_tombstone_retention_days', '>= backup retention days',
    coalesce(v, '(missing)'), case when v is null then 'FAIL' else 'CHECK' end);

  -- 3. extensions
  insert into crushly_checks
  select 3, 'extension ' || e, 'installed',
         coalesce((select extversion from pg_extension where extname = e), '(not installed)'),
         case when exists (select 1 from pg_extension where extname = e) then 'PASS' else 'FAIL' end
    from unnest(array['pg_cron', 'pg_net']) as e;

  -- 4. cron jobs
  if has_cron then
    execute $q$
      insert into crushly_checks
      select 4, 'cron job ' || j.name, 'scheduled every minute, active',
             coalesce((select c.schedule || case when c.active then ' (active)' else ' (INACTIVE)' end
                         from cron.job c where c.jobname = j.name), '(missing)'),
             case when exists (select 1 from cron.job c
                                where c.jobname = j.name and c.active and c.schedule = '* * * * *')
                  then 'PASS' else 'FAIL' end
        from unnest(array['crushly-tick', 'crushly-push']) as j(name)
    $q$;
    -- 5. tick actually ran recently (cron.job_run_details exists on pg_cron >= 1.4)
    if to_regclass('cron.job_run_details') is not null then
      execute $q$
        insert into crushly_checks
        select 5, 'crushly-tick last run', 'succeeded within 5 min',
               coalesce(max(d.end_time)::text || ' ' || (array_agg(d.status order by d.end_time desc))[1], '(never)'),
               case when max(d.end_time) > now() - interval '5 minutes'
                     and (array_agg(d.status order by d.end_time desc))[1] = 'succeeded' then 'PASS' else 'FAIL' end
          from cron.job_run_details d join cron.job c on c.jobid = d.jobid
         where c.jobname = 'crushly-tick'
      $q$;
    end if;
  else
    insert into crushly_checks values (4, 'cron jobs', 'crushly-tick, crushly-push', 'pg_cron not enabled', 'FAIL');
  end if;

  -- 6. migrations (only tracked when applied with `supabase db push`)
  if has_mig then
    select string_agg(m, ', ') into missing
      from unnest(array['20261110000000', '20261111000000', '20261116000000',
                        '20261117000000', '20261118000000']) as m
     where not exists (select 1 from supabase_migrations.schema_migrations s where s.version = m);
    insert into crushly_checks values (6, 'migrations applied', 'all 5', coalesce('missing: ' || missing, 'all 5'),
      case when missing is null then 'PASS' else 'FAIL' end);
  else
    -- Applied by hand: look for one object from each of the later migrations instead.
    select string_agg(o, ', ') into missing
      from unnest(array['public.poke_on_message()', 'public.crushly_tick()']) as o
     where to_regprocedure(o) is null;
    if to_regclass('public.campus_spaces') is null then missing := concat_ws(', ', missing, 'public.campus_spaces'); end if;
    insert into crushly_checks values (6, 'migrations applied (untracked; by object)', 'latest objects present',
      coalesce('missing: ' || missing, 'campus_spaces, crushly_tick, poke_on_message present'),
      case when missing is null then 'PASS' else 'FAIL' end);
  end if;

  -- 7. dev bypass account gone, and no password-based accounts at all (the app is OTP-only)
  select count(*)::text into v from auth.users where email = 'crushly-dev@usc.edu';
  insert into crushly_checks values (7, 'dev account crushly-dev@usc.edu', '0', v,
    case when v = '0' then 'PASS' else 'FAIL' end);
  select count(*)::text into v from auth.users where coalesce(encrypted_password, '') <> '';
  insert into crushly_checks values (7, 'accounts with a password set', '0', v,
    case when v = '0' then 'PASS' else 'FAIL' end);

  -- 8. campus spaces: only field-validated zones are enabled
  select coalesce(string_agg(slug || ' (v' || boundary_version || ')', ', '), '(none)') into v
    from public.campus_spaces where enabled and validation_status = 'draft';
  insert into crushly_checks values (8, 'enabled draft zones', '(none)', v,
    case when v = '(none)' then 'PASS' else 'CHECK' end);
  select count(*)::text into v from public.campus_spaces where enabled and validation_status = 'field_validated';
  insert into crushly_checks values (8, 'enabled field-validated zones', '>= 1', v,
    case when v <> '0' then 'PASS' else 'FAIL' end);

  -- 9. photo bucket private
  select coalesce((select public::text from storage.buckets where id = 'profile-photos'), '(missing)') into v;
  insert into crushly_checks values (9, 'profile-photos bucket public', 'false', v,
    case when v = 'false' then 'PASS' else 'FAIL' end);

  -- 10. push secret in Vault
  if to_regclass('vault.secrets') is not null then
    select count(*)::text into v from vault.secrets where name = 'push_dispatch_secret';
    insert into crushly_checks values (10, 'vault secret push_dispatch_secret', 'present', v,
      case when v <> '0' then 'PASS' else 'FAIL' end);
  end if;
end $$;

select item, expected, actual, result from crushly_checks order by n, item;
