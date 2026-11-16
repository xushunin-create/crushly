-- Test-only helpers (schema `tests`). Applied after the migration and seed.
create schema tests;
grant usage on schema tests to authenticated, anon;

-- Impersonate a user for the rest of the current transaction.
create function tests.login(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create function tests.logout() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

create function tests.assert(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then
    raise exception 'ASSERTION FAILED: %', msg;
  end if;
  raise notice 'ok - %', msg;
end $$;

-- Run `sql` and require it to fail with contract error `code` (the message).
create function tests.expect_error(sql text, code text, msg text default null) returns void language plpgsql as $$
declare v_ok boolean := false;
begin
  begin
    execute sql;
  exception when others then
    if sqlerrm = code then
      v_ok := true;
    else
      raise exception 'ASSERTION FAILED: % : expected error [%] but got [%] (sqlstate %) running: %',
        coalesce(msg, code), code, sqlerrm, sqlstate, sql;
    end if;
  end;
  if not v_ok then
    raise exception 'ASSERTION FAILED: % : expected error [%] but statement succeeded: %', coalesce(msg, code), code, sql;
  end if;
  raise notice 'ok - % (raised %)', coalesce(msg, sql), code;
end $$;

-- Run `sql` and require it to fail with SQLSTATE `state` (e.g. 42501 insufficient_privilege).
create function tests.expect_sqlstate(sql text, state text, msg text) returns void language plpgsql as $$
declare v_ok boolean := false;
begin
  begin
    execute sql;
  exception when others then
    if sqlstate = state then v_ok := true;
    else raise exception 'ASSERTION FAILED: % : expected sqlstate % but got % [%]', msg, state, sqlstate, sqlerrm;
    end if;
  end;
  if not v_ok then
    raise exception 'ASSERTION FAILED: % : expected sqlstate % but statement succeeded', msg, state;
  end if;
  raise notice 'ok - % (sqlstate %)', msg, state;
end $$;

-- Fixture space. The boundary is a small square at 0,0 (Null Island): an obvious test fixture,
-- never a real campus location. The server never evaluates boundaries anyway.
create function tests.make_space(p_slug text, p_status text default 'field_validated', p_enabled boolean default true)
returns uuid language sql security definer set search_path = public as $$
  insert into public.campus_spaces (slug, name, boundary, validation_status, enabled)
  values (p_slug, initcap(replace(p_slug, '-', ' ')),
          '{"type":"Polygon","coordinates":[[[0,0],[0,0.001],[0.001,0.001],[0.001,0],[0,0]]]}',
          p_status, p_enabled)
  returning id
$$;

create function tests.space(p_slug text) returns uuid language sql security definer set search_path = public as $$
  select id from public.campus_spaces where slug = p_slug
$$;

-- Creates an auth user with a complete profile, accepted terms and matching preferences. Returns its id.
create function tests.make_user(handle text, complete boolean default true, terms boolean default true,
                                gender text default 'nonbinary',
                                show_me text[] default array['man','nonbinary','woman'],
                                age int default 20)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, email_confirmed_at) values (v, handle || '@usc.edu', now());
  if complete then
    insert into public.profiles (id, first_name, age, interests, vibe_tags, prompt_question, prompt_answer,
                                 intention, availability, photo_paths)
    values (v, initcap(handle), age, array['music','coffee','hiking'], array['night owl'], 'Best spot?', 'Leavey 3rd floor',
            'figuring_it_out', 'either', array[v::text || '/' || gen_random_uuid()::text || '.jpg']);
  end if;
  if terms then
    insert into public.profile_private (user_id, age_confirmed_at, terms_version, terms_accepted_at, privacy_version,
                                        privacy_accepted_at, match_gender, show_me)
    values (v, now(), 'dev-1', now(), 'dev-1', now(), gender, show_me);
  end if;
  return v;
end $$;

-- Strictly increasing fake device fix timestamps.
create sequence tests.fix_seq;

-- A location-evidence claim. Defaults: fresh (1 s old), 10 m accuracy, moving.
create function tests.evidence(age_ms bigint default 1000, accuracy numeric default 10, stationary boolean default false,
                               ts bigint default null)
returns jsonb language sql as $$
  select jsonb_build_object('fix_ts_ms', coalesce(ts, 1700000000000 + nextval('tests.fix_seq') * 1000),
                            'fix_age_ms', age_ms, 'horizontal_accuracy_m', accuracy, 'stationary', stationary)
$$;

-- Records that every active participant has been shown every other participant in the same space
-- (what repeated discovery would eventually do), so tests can exercise express_interest's own rules.
create function tests.expose_all() returns void language sql security definer set search_path = public as $$
  insert into public.discovery_exposures (viewer_session_id, target_session_id)
  select v.id, t.id from public.participation_sessions v
    join public.participation_sessions t on t.space_id = v.space_id and t.id <> v.id
   where v.lease_expires_at > now() and t.lease_expires_at > now()
  on conflict do nothing
$$;

-- Logs in as `uid` and opens participation in the space with fresh consent. Stays logged in.
-- By default also marks everyone in the space as discovered (see tests.expose_all).
create function tests.participate(uid uuid, p_slug text, expose boolean default true) returns uuid language plpgsql as $$
declare st jsonb; r jsonb;
begin
  perform tests.login(uid);
  st := public.my_participation();
  r := public.open_participation(p_slug, 1, (st->>'consent_epoch')::bigint, gen_random_uuid(), tests.evidence());
  if expose then perform tests.expose_all(); end if;
  return (r->>'session_id')::uuid;
end $$;

-- Makes a user's lease lapse (as if renewals stopped).
create function tests.expire(uid uuid) returns void language sql security definer set search_path = public as $$
  update public.participation_sessions set lease_expires_at = now() - interval '1 second' where user_id = uid
$$;

create function tests.reset_rate_limits() returns void language sql security definer set search_path = public as $$
  delete from public.rate_limits
$$;

-- Makes pending interests visible now (skips the random receipt delay).
create function tests.reveal_interests() returns void language sql security definer set search_path = public as $$
  update public.interests set visible_at = now() - interval '1 second'
$$;

-- Test-side inspection of internal tables (runs as the owner, so tests can verify server state
-- while impersonating a user whose own access is correctly denied).
create function tests.n(q text) returns bigint language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  execute 'select count(*) from (' || q || ') t' into v;
  return v;
end $$;

create function tests.val(q text) returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  execute q into v;
  return v;
end $$;

grant execute on all functions in schema tests to authenticated, anon;
grant usage on sequence tests.fix_seq to authenticated, anon;
