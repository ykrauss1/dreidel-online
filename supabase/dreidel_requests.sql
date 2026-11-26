-- 🕎 Dreidel — players waiting for approval: whoever signs up (or signs in) through the game and is not approved yet
-- shows up for the manager under "ממתינים לאישור". Run once in the CerviniaLive Supabase project → SQL Editor.

create table if not exists public.dreidel_requests(
  user_id uuid primary key references auth.users(id) on delete cascade,
  asked_at timestamptz not null default now()
);
alter table public.dreidel_requests enable row level security;
revoke all on public.dreidel_requests from anon, authenticated;

-- "I'd like to play" — the signed-in user, once (asking again only refreshes the time)
create or replace function public.dreidel_request_access()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or dreidel_allowed() then return; end if;
  insert into dreidel_requests(user_id) values (auth.uid())
  on conflict (user_id) do update set asked_at = now();
end $$;

-- the manager: who is waiting
create or replace function public.dreidel_request_list()
returns table(id uuid, username text, asked_at timestamptz) language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(cl_is_admin(), false) then raise exception 'not allowed'; end if;
  return query select r.user_id, p.username, r.asked_at from dreidel_requests r left join profiles p on p.id = r.user_id
    where not exists(select 1 from dreidel_access a where a.user_id = r.user_id) order by r.asked_at desc;
end $$;

-- approving / removing also clears the request
create or replace function public.dreidel_access_set(p_user uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(cl_is_admin(), false) then raise exception 'not allowed'; end if;
  if p_on then insert into dreidel_access(user_id) values (p_user) on conflict do nothing;
  else delete from dreidel_access where user_id = p_user; end if;
  delete from dreidel_requests where user_id = p_user;
end $$;

-- the manager can also turn a request down without approving
create or replace function public.dreidel_request_dismiss(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(cl_is_admin(), false) then raise exception 'not allowed'; end if;
  delete from dreidel_requests where user_id = p_user;
end $$;

grant execute on function public.dreidel_request_access() to authenticated;
grant execute on function public.dreidel_request_list() to authenticated;
grant execute on function public.dreidel_access_set(uuid, boolean) to authenticated;
grant execute on function public.dreidel_request_dismiss(uuid) to authenticated;
