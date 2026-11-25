-- 🕎 Dreidel — shared settings for every device (for now: the Hebrew pronunciation list). Run once in Supabase → SQL Editor.
-- Anyone can read; saving needs the manager code. The first save sets the code (the manager's 4 digits);
-- wrong codes count toward the same guard as wrong family codes (20 an hour from one connection).

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.dreidel_config(
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.dreidel_config enable row level security;

create or replace function public.dreidel_get_config(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value from dreidel_config where key = p_key and left(p_key,1) <> '_';
$$;

create or replace function public.dreidel_set_config(p_key text, p_value text, p_secret text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  perform dreidel_lookup_guard();
  if p_key is null or left(p_key,1) = '_' or length(p_key) > 40 or length(coalesce(p_value,'')) > 20000
     or coalesce(length(p_secret),0) < 4 then
    raise exception 'bad request';
  end if;
  select value into h from dreidel_config where key = '_admin';
  if h is null then
    insert into dreidel_config(key, value) values ('_admin', crypt(p_secret, gen_salt('bf')));
  elsif h <> crypt(p_secret, h) then
    perform dreidel_lookup_failed();
    return false;
  end if;
  insert into dreidel_config(key, value, updated_at) values (p_key, coalesce(p_value,''), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return true;
end $$;

grant execute on function public.dreidel_get_config(text) to anon, authenticated;
grant execute on function public.dreidel_set_config(text, text, text) to anon, authenticated;

-- forgot the code / want a new one:  delete from dreidel_config where key = '_admin';   (the next save sets it again)
