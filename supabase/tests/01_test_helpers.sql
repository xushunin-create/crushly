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

create function tests.space(p_name text) returns uuid language sql security definer set search_path = public as $$
  select id from public.campus_spaces where name = p_name
$$;

-- Creates an auth user with a complete profile and accepted terms. Returns its id.
create function tests.make_user(handle text, complete boolean default true, terms boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, email_confirmed_at) values (v, handle || '@usc.edu', now());
  if complete then
    insert into public.profiles (id, first_name, age, interests, vibe_tags, prompt_question, prompt_answer,
                                 intention, availability, photo_paths)
    values (v, initcap(handle), 20, array['music','coffee','hiking'], array['night owl'], 'Best spot?', 'Leavey 3rd floor',
            'figuring_it_out', 'either', array[v::text || '/' || gen_random_uuid()::text || '.jpg']);
  end if;
  if terms then
    insert into public.profile_private (user_id, age_confirmed_at, terms_version, terms_accepted_at, privacy_version, privacy_accepted_at)
    values (v, now(), 'dev-1', now(), 'dev-1', now());
  end if;
  return v;
end $$;

-- Logs in as `uid` and starts a 60-minute pulse in the named space. Stays logged in.
create function tests.pulse(uid uuid, space_name text) returns uuid language plpgsql as $$
declare r public.pulse_sessions;
begin
  perform tests.login(uid);
  r := public.start_pulse(tests.space(space_name), 60, false, 'either');
  return r.id;
end $$;

grant execute on all functions in schema tests to authenticated, anon;
