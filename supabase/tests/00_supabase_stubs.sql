-- Minimal stand-ins for what the Supabase stack provides, so the migration can
-- be applied to a plain Postgres for tests. NOT part of the deployed schema.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin noinherit bypassrls; end if;
end $$;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create table auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  email_confirmed_at timestamptz,
  raw_user_meta_data jsonb,
  created_at         timestamptz default now()
);

create function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;
grant execute on function auth.uid() to anon, authenticated, service_role;

create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;

create table storage.buckets (
  id     text primary key,
  name   text not null,
  public boolean default false
);

create table storage.objects (
  id        uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name      text,
  owner     uuid
);
alter table storage.objects enable row level security;
grant select, insert, update, delete on storage.objects to authenticated;

create function storage.foldername(name text) returns text[] language plpgsql immutable as $$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end $$;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;

-- Realtime (Broadcast authorization). Mirrors the parts of Supabase's `realtime` schema our migration uses:
-- private-channel messages live in realtime.messages, RLS decides who may join/receive a topic, realtime.topic()
-- is the topic being joined, and realtime.send() inserts a broadcast. Tests set the topic with
-- set_config('realtime.topic', 'user:<uuid>', true) to impersonate a subscriber joining that channel.
create schema if not exists realtime;
grant usage on schema realtime to anon, authenticated, service_role;

create table realtime.messages (
  id          bigserial primary key,
  topic       text not null,
  extension   text not null,
  payload     jsonb,
  event       text,
  private     boolean default false,
  inserted_at timestamptz not null default now()
);
alter table realtime.messages enable row level security;
grant select, insert on realtime.messages to authenticated;
grant all on realtime.messages to service_role;
grant usage on sequence realtime.messages_id_seq to authenticated, service_role;

create function realtime.topic() returns text language sql stable as $$
  select nullif(current_setting('realtime.topic', true), '')
$$;
grant execute on function realtime.topic() to anon, authenticated, service_role;

create function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void
language plpgsql security definer as $$
begin
  insert into realtime.messages (topic, extension, payload, event, private)
  values (send.topic, 'broadcast', send.payload, send.event, send.private);
end $$;
