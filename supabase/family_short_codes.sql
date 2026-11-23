-- 🕎 Dreidel — short family codes (4 letters) + a guard against guessing codes. Run once in Supabase → SQL Editor.
-- Families that already have an 8-letter code keep it; new families get 4 letters.

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

create or replace function public.dreidel_save_family(p_key text, p_name text, p_players json)
returns text language plpgsql security definer set search_path = public as $$
declare k text := upper(nullif(trim(p_key),'')); n text := left(trim(coalesce(p_name,'')),40); pl json; i int := 0;
begin
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

grant execute on function public.dreidel_get_family(text)             to anon, authenticated;
revoke all on function public.dreidel_lookup_guard() from public, anon, authenticated;
revoke all on function public.dreidel_lookup_failed() from public, anon, authenticated;
revoke all on function public.dreidel_client_ip() from public, anon, authenticated;
grant execute on function public.dreidel_get_family(text) to anon, authenticated;
grant execute on function public.dreidel_save_family(text, text, json) to anon, authenticated;
