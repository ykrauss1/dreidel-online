-- 🕎 Dreidel — family rosters with photos (run once in Supabase → SQL Editor)
-- A family is reached only by its secret family code (8 letters). The tables are closed to direct access;
-- the game reads and writes only through the two functions below.

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
create or replace function public.dreidel_get_family(p_key text)
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'key', f.key, 'name', f.name, 'updated', f.updated_at,
    'players', coalesce((select json_agg(json_build_object('id',p.id,'name',p.name,'avatar',p.avatar,'level',p.level,'photo',p.photo) order by p.pos)
                         from dreidel_family_players p where p.family_key = f.key), '[]'::json))
  from dreidel_families f where f.key = upper(p_key);
$$;

-- create (p_key null) or update a family; returns its code
create or replace function public.dreidel_save_family(p_key text, p_name text, p_players json)
returns text language plpgsql security definer set search_path = public as $$
declare k text := upper(nullif(trim(p_key),'')); n text := left(trim(coalesce(p_name,'')),40); pl json; i int := 0;
begin
  if n = '' then raise exception 'family name required'; end if;
  if json_array_length(p_players) > 30 then raise exception 'too many players'; end if;
  if k is null then
    loop
      k := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random()*32)::int, 1), '') from generate_series(1,8));
      exit when not exists(select 1 from dreidel_families where key = k);
    end loop;
    insert into dreidel_families(key,name) values(k,n);
  else
    update dreidel_families set name = n, updated_at = now() where key = k;
    if not found then raise exception 'unknown family code'; end if;
  end if;
  delete from dreidel_family_players where family_key = k;
  for pl in select * from json_array_elements(p_players) loop
    if length(coalesce(pl->>'photo','')) > 120000 then raise exception 'photo too big'; end if;
    insert into dreidel_family_players(family_key,pos,name,avatar,level,photo)
    values(k, i, left(trim(coalesce(pl->>'name','')),30), left(pl->>'avatar',8), coalesce((pl->>'level')::int,2), nullif(pl->>'photo',''));
    i := i + 1;
  end loop;
  return k;
end $$;

grant execute on function public.dreidel_get_family(text)             to anon, authenticated;
grant execute on function public.dreidel_save_family(text, text, json) to anon, authenticated;
