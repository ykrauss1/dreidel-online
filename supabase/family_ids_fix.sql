-- 🕎 Dreidel — fix: saving a family again keeps each player's id (run once in Supabase → SQL Editor)

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
grant execute on function public.dreidel_save_family(text, text, json) to anon, authenticated;
