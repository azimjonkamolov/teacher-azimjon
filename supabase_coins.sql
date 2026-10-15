-- Teacher Azimjon website: coins, visits and student stats for Admin (version 1).
-- Run AFTER supabase_setup.sql and supabase_points.sql. Safe to run again.
-- It does NOT change or delete any points: coins = the same points, just a new name on the site.
-- Paste everything into Supabase -> SQL Editor, then press Run.

-- 1) Visits: one row each time a student opens the site
--    (a new visit starts after 30 minutes without activity)
create table if not exists public.visits (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  started_at  timestamptz not null default now(),
  last_at     timestamptz not null default now()
);
create index if not exists visits_user_idx on public.visits(user_id, last_at desc);

alter table public.visits enable row level security;
drop policy if exists "visits read" on public.visits;
create policy "visits read" on public.visits for select to authenticated using (user_id = auth.uid() or public.is_admin());
grant select on public.visits to authenticated;

-- The site calls this when a student opens it (and every few minutes while it is open)
create or replace function public.log_visit() returns void
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if auth.uid() is null or not exists (select 1 from public.profiles where id = auth.uid()) then return; end if;
  select id into v from public.visits
   where user_id = auth.uid() and last_at > now() - interval '30 minutes'
   order by last_at desc limit 1;
  if v is null then
    insert into public.visits (user_id) values (auth.uid());
  else
    update public.visits set last_at = now() where id = v;
  end if;
end $$;
revoke all on function public.log_visit() from public, anon;
grant execute on function public.log_visit() to authenticated;

-- 2) Admin only: coins, visits, active days and last activity for every student
create or replace function public.admin_student_stats()
returns table(user_id uuid, coins bigint, coins_week bigint, visits bigint, active_days bigint, activities bigint, last_active timestamptz)
language sql stable security definer set search_path = public as $$
  with c as (select s.user_id, sum(s.pts) as n from public.pts_scored(null) s group by s.user_id),
  w as (select s.user_id, sum(s.pts) as n
          from public.pts_scored(null, (date_trunc('week', now() at time zone 'Asia/Tashkent')) at time zone 'Asia/Tashkent') s
         group by s.user_id),
  v as (select x.user_id, count(*) as n, max(x.last_at) as last from public.visits x group by x.user_id),
  r as (select x.user_id, max(x.created_at) as last from public.results x group by x.user_id),
  p as (select x.user_id, count(*) as n, max(x.created_at) as last from public.points x group by x.user_id),
  d as (select y.user_id, count(distinct y.day) as n from (
          select x.user_id, (x.created_at at time zone 'Asia/Tashkent')::date as day from public.results x
          union all
          select x.user_id, (x.created_at at time zone 'Asia/Tashkent')::date from public.points x
          union all
          select x.user_id, (x.started_at at time zone 'Asia/Tashkent')::date from public.visits x) y
        group by y.user_id)
  select pr.id, coalesce(c.n, 0)::bigint, coalesce(w.n, 0)::bigint, coalesce(v.n, 0), coalesce(d.n, 0), coalesce(p.n, 0),
         greatest(v.last, r.last, p.last)
  from public.profiles pr
  left join c on c.user_id = pr.id
  left join w on w.user_id = pr.id
  left join v on v.user_id = pr.id
  left join r on r.user_id = pr.id
  left join p on p.user_id = pr.id
  left join d on d.user_id = pr.id
  where public.is_admin()
$$;
revoke all on function public.admin_student_stats() from public, anon;
grant execute on function public.admin_student_stats() to authenticated;

notify pgrst, 'reload schema';

select 'Coins setup v1 finished - OK' as status;
