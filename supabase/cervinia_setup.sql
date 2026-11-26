-- ═══════════════════════════════════════════════════════════════════════
-- 🕎 Dreidel — runs on the CerviniaLive project: the same users (username + password).
-- Only users the manager approved may play. The manager = profiles.is_admin (cl_is_admin()).
-- Run once in the CerviniaLive Supabase project → SQL Editor.
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists public.dreidel_access(
  user_id uuid primary key references auth.users(id) on delete cascade,
  approved_at timestamptz not null default now()
);
alter table public.dreidel_access enable row level security;
revoke all on public.dreidel_access from anon, authenticated;

-- may the person who is signed in play?
create or replace function public.dreidel_allowed()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    exists(select 1 from dreidel_access a where a.user_id = auth.uid()) or coalesce(cl_is_admin(), false));
$$;

-- who am I (for the entry screen): signed in? approved? manager? my username
create or replace function public.dreidel_whoami()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'signed_in', auth.uid() is not null,
    'allowed', dreidel_allowed(),
    'admin', coalesce(cl_is_admin(), false),
    'username', (select p.username from profiles p where p.id = auth.uid()));
$$;

-- the manager: the approved list, finding a user by name, approving / removing
create or replace function public.dreidel_access_list()
returns table(id uuid, username text, approved_at timestamptz) language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(cl_is_admin(), false) then raise exception 'not allowed'; end if;
  return query select a.user_id, p.username, a.approved_at from dreidel_access a left join profiles p on p.id = a.user_id order by p.username;
end $$;

create or replace function public.dreidel_user_find(p_q text)
returns table(id uuid, username text, approved boolean) language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(cl_is_admin(), false) then raise exception 'not allowed'; end if;
  return query select p.id, p.username, exists(select 1 from dreidel_access a where a.user_id = p.id)
    from profiles p where length(trim(coalesce(p_q,''))) >= 2 and p.username ilike '%' || trim(p_q) || '%'
    order by p.username limit 20;
end $$;

create or replace function public.dreidel_access_set(p_user uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(cl_is_admin(), false) then raise exception 'not allowed'; end if;
  if p_on then insert into dreidel_access(user_id) values (p_user) on conflict do nothing;
  else delete from dreidel_access where user_id = p_user; end if;
end $$;

grant execute on function public.dreidel_allowed() to anon, authenticated;
grant execute on function public.dreidel_whoami() to anon, authenticated;
grant execute on function public.dreidel_access_list() to authenticated;
grant execute on function public.dreidel_user_find(text) to authenticated;
grant execute on function public.dreidel_access_set(uuid, boolean) to authenticated;

-- the online rooms (Realtime channels "room_XXXX", private): only approved players can join, send and see
drop policy if exists "dreidel rooms: approved players read" on realtime.messages;
drop policy if exists "dreidel rooms: approved players send" on realtime.messages;
create policy "dreidel rooms: approved players read" on realtime.messages for select to authenticated
  using (realtime.topic() like 'room\_%' and public.dreidel_allowed());
create policy "dreidel rooms: approved players send" on realtime.messages for insert to authenticated
  with check (realtime.topic() like 'room\_%' and public.dreidel_allowed());

-- ── families: names + photos (only approved players) ──

create table if not exists public.dreidel_families(
  key        text primary key,
  name       text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.dreidel_family_players(
  id         uuid primary key default gen_random_uuid(),
  family_key text not null references public.dreidel_families(key) on delete cascade,
  pos        int  not null default 0,
  name       text not null,
  avatar     text,
  level      int  default 2,
  photo      text,                      -- a small square picture (data:image/webp;base64,…, ~10 KB)
  updated_at timestamptz not null default now()
);
create index if not exists dreidel_family_players_key on public.dreidel_family_players(family_key, pos);

alter table public.dreidel_families       enable row level security;
alter table public.dreidel_family_players enable row level security;
-- (no policies: nobody can list or read the tables directly)

-- read one family by its code
-- wrong codes are counted per device address: after 20 wrong tries in an hour, lookups are refused for that address
-- (a 4-letter code has about a million possibilities — this keeps anyone from simply trying them all)
create table if not exists public.dreidel_lookup_fail(ip text not null, at timestamptz not null default now());
create index if not exists dreidel_lookup_fail_ip_at on public.dreidel_lookup_fail(ip, at);
alter table public.dreidel_lookup_fail enable row level security;

create or replace function public.dreidel_client_ip() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.headers', true)::json->>'cf-connecting-ip',''),
    nullif(split_part(current_setting('request.headers', true)::json->>'x-forwarded-for', ',', 1),''),
    nullif(current_setting('request.headers', true)::json->>'x-real-ip',''),
    'unknown');
$$;

create or replace function public.dreidel_lookup_guard() returns void language plpgsql security definer set search_path = public as $$
declare my_ip text := dreidel_client_ip();
begin
  if (select count(*) from dreidel_lookup_fail f where f.ip = my_ip and f.at > now() - interval '1 hour') >= 20
     or (select count(*) from dreidel_lookup_fail where at > now() - interval '10 minutes') >= 600 then
    raise exception 'too many tries';
  end if;
end $$;

create or replace function public.dreidel_lookup_failed() returns void language plpgsql security definer set search_path = public as $$
begin
  insert into dreidel_lookup_fail(ip) values (dreidel_client_ip());
  delete from dreidel_lookup_fail where at < now() - interval '1 day';
end $$;

create or replace function public.dreidel_get_family(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare r json;
begin
  if not dreidel_allowed() then raise exception 'not allowed'; end if;
  perform dreidel_lookup_guard();
  select json_build_object(
    'key', f.key, 'name', f.name, 'updated', f.updated_at,
    'players', coalesce((select json_agg(json_build_object('id',p.id,'name',p.name,'avatar',p.avatar,'level',p.level,'photo',p.photo) order by p.pos)
                         from dreidel_family_players p where p.family_key = f.key), '[]'::json))
    into r
  from dreidel_families f where f.key = upper(trim(p_key));
  if r is null then perform dreidel_lookup_failed(); end if;
  return r;
end $$;

-- create (p_key null) or update a family; returns its code
create or replace function public.dreidel_save_family(p_key text, p_name text, p_players json)
returns text language plpgsql security definer set search_path = public as $$
declare k text := upper(nullif(trim(p_key),'')); n text := left(trim(coalesce(p_name,'')),40); pl json; i int := 0;
begin
  if not dreidel_allowed() then raise exception 'not allowed'; end if;
  if n = '' then raise exception 'family name required'; end if;
  if json_array_length(p_players) > 30 then raise exception 'too many players'; end if;
  if k is null then
    -- a new family gets a short code: 4 letters/digits (about a million possibilities)
    loop
      k := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random()*32)::int, 1), '') from generate_series(1,4));
      exit when not exists(select 1 from dreidel_families where key = k);
    end loop;
    insert into dreidel_families(key,name) values(k,n);
  else
    perform dreidel_lookup_guard();
    update dreidel_families set name = n, updated_at = now() where key = k;
    if not found then perform dreidel_lookup_failed(); return null; end if;   -- (null = no such family; no exception, so the wrong try is counted)
  end if;
  -- keep each player's id when the family is saved again (games already in progress point at these ids)
  delete from dreidel_family_players
   where family_key = k
     and id::text not in (select coalesce(e->>'id','') from json_array_elements(p_players) e);
  for pl in select * from json_array_elements(p_players) loop
    if length(coalesce(pl->>'photo','')) > 120000 then raise exception 'photo too big'; end if;
    if coalesce(pl->>'id','') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       and exists(select 1 from dreidel_family_players where id = (pl->>'id')::uuid and family_key = k) then
      update dreidel_family_players
         set pos = i, name = left(trim(coalesce(pl->>'name','')),30), avatar = left(pl->>'avatar',8),
             level = coalesce((pl->>'level')::int,2), photo = nullif(pl->>'photo',''), updated_at = now()
       where id = (pl->>'id')::uuid;
    else
      insert into dreidel_family_players(family_key,pos,name,avatar,level,photo)
      values(k, i, left(trim(coalesce(pl->>'name','')),30), left(pl->>'avatar',8), coalesce((pl->>'level')::int,2), nullif(pl->>'photo',''));
    end if;
    i := i + 1;
  end loop;
  return k;
end $$;

revoke all on function public.dreidel_lookup_guard() from public, anon, authenticated;
revoke all on function public.dreidel_lookup_failed() from public, anon, authenticated;
revoke all on function public.dreidel_client_ip() from public, anon, authenticated;
grant execute on function public.dreidel_get_family(text)             to authenticated;
grant execute on function public.dreidel_save_family(text, text, json) to authenticated;

-- ── error reports (open to all, so a crash before signing in is reported too) ──

create table if not exists public.dreidel_errors(
  id      bigint generated always as identity primary key,
  at      timestamptz not null default now(),
  ver     text,
  kind    text,                 -- 'error' | 'promise'
  msg     text,
  src     text,                 -- file:line:col
  stack   text,
  ua      text,                 -- browser / device
  ctx     text                  -- screen and mode at the time (e.g. "game local wheel")
);
create index if not exists dreidel_errors_at on public.dreidel_errors(at desc);
alter table public.dreidel_errors enable row level security;
-- (no policies: nobody can read the table from the game; you read it in the Supabase dashboard)

create or replace function public.dreidel_log_error(p_ver text, p_kind text, p_msg text, p_src text, p_stack text, p_ua text, p_ctx text)
returns void language plpgsql security definer set search_path = public as $$
begin
  -- flood guard: at most 300 reports an hour from everyone together
  if (select count(*) from public.dreidel_errors where at > now() - interval '1 hour') >= 300 then return; end if;
  insert into public.dreidel_errors(ver,kind,msg,src,stack,ua,ctx)
  values (left(p_ver,20), left(p_kind,10), left(p_msg,500), left(p_src,300), left(p_stack,2000), left(p_ua,300), left(p_ctx,200));
  -- keep only the last 90 days
  delete from public.dreidel_errors where at < now() - interval '90 days';
end $$;
revoke all on function public.dreidel_log_error(text,text,text,text,text,text,text) from public;
grant execute on function public.dreidel_log_error(text,text,text,text,text,text,text) to anon, authenticated;

-- to look at the reports:  select at, ver, msg, src, ctx, ua from dreidel_errors order by at desc limit 50;

-- ── shared settings (the Hebrew pronunciation list): everyone reads, only the manager saves ──
create table if not exists public.dreidel_config(key text primary key, value text not null, updated_at timestamptz not null default now());
alter table public.dreidel_config enable row level security;
create or replace function public.dreidel_get_config(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value from dreidel_config where key = p_key;
$$;
create or replace function public.dreidel_set_config(p_key text, p_value text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(cl_is_admin(), false) then raise exception 'not allowed'; end if;
  if p_key is null or length(p_key) > 40 or length(coalesce(p_value,'')) > 20000 then raise exception 'bad request'; end if;
  insert into dreidel_config(key, value, updated_at) values (p_key, coalesce(p_value,''), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return true;
end $$;
grant execute on function public.dreidel_get_config(text) to anon, authenticated;
grant execute on function public.dreidel_set_config(text, text) to authenticated;
