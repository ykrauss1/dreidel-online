-- 🕎 Dreidel — inviting players straight from the list of approved users.
-- The host ticks names → each one gets an invitation inside the game (a banner with "join").
-- The manager can also e-mail them (the addresses are given only to the manager).
-- Run once in the CerviniaLive Supabase project → SQL Editor.

create table if not exists public.dreidel_invites(
  id bigint generated always as identity primary key,
  room text not null,
  room_type text,
  from_user uuid references auth.users(id) on delete cascade,
  from_name text,
  to_user uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists dreidel_invites_to on public.dreidel_invites(to_user, created_at desc);
alter table public.dreidel_invites enable row level security;
revoke all on public.dreidel_invites from anon, authenticated;

-- the approved players (names only) — for the host to tick
create or replace function public.dreidel_players()
returns table(id uuid, username text) language plpgsql stable security definer set search_path = public as $$
begin
  if not dreidel_allowed() then raise exception 'not allowed'; end if;
  return query
    select p.id, p.username from profiles p
    where p.id <> auth.uid() and (exists(select 1 from dreidel_access a where a.user_id = p.id) or p.is_admin = true)
    order by p.username;
end $$;

-- send invitations to a room
create or replace function public.dreidel_invite(p_room text, p_type text, p_users uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare n integer; me text;
begin
  if not dreidel_allowed() then raise exception 'not allowed'; end if;
  if p_room !~ '^[A-Z0-9]{4,8}$' or coalesce(array_length(p_users,1),0) = 0 or array_length(p_users,1) > 60 then raise exception 'bad request'; end if;
  select username into me from profiles where id = auth.uid();
  delete from dreidel_invites where created_at < now() - interval '2 days';
  delete from dreidel_invites where to_user = any(p_users) and from_user = auth.uid();   -- one open invitation per host and player
  insert into dreidel_invites(room, room_type, from_user, from_name, to_user)
    select upper(p_room), left(p_type,10), auth.uid(), me, u from unnest(p_users) u
    where exists(select 1 from dreidel_access a where a.user_id = u) or exists(select 1 from profiles p where p.id = u and p.is_admin);
  get diagnostics n = row_count;
  return n;
end $$;

-- my invitations (the last 6 hours)
create or replace function public.dreidel_my_invites()
returns table(id bigint, room text, room_type text, from_name text, created_at timestamptz) language sql stable security definer set search_path = public as $$
  select i.id, i.room, i.room_type, i.from_name, i.created_at from dreidel_invites i
  where i.to_user = auth.uid() and i.created_at > now() - interval '6 hours' order by i.created_at desc limit 5;
$$;

create or replace function public.dreidel_invite_dismiss(p_id bigint)
returns void language sql security definer set search_path = public as $$
  delete from dreidel_invites where id = p_id and to_user = auth.uid();
$$;

-- the manager only: e-mail addresses of the ticked players
create or replace function public.dreidel_player_emails(p_users uuid[])
returns table(username text, email text) language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(cl_is_admin(), false) then raise exception 'not allowed'; end if;
  return query select p.username, p.email from profiles p where p.id = any(p_users) and coalesce(p.email,'') like '%@%';
end $$;

grant execute on function public.dreidel_players() to authenticated;
grant execute on function public.dreidel_invite(text, text, uuid[]) to authenticated;
grant execute on function public.dreidel_my_invites() to authenticated;
grant execute on function public.dreidel_invite_dismiss(bigint) to authenticated;
grant execute on function public.dreidel_player_emails(uuid[]) to authenticated;
