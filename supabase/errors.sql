-- 🕎 Dreidel — error reports from players' devices (run once in Supabase → SQL Editor)
-- The game sends a short report when something breaks (message, place in the code, version, device).
-- No names, no pictures, no room contents. The table is closed; the game can only add rows through the function.

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
