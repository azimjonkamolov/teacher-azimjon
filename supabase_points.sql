-- Teacher Azimjon website: points, levels and weekly leaderboard (version 5).
-- Run AFTER supabase_setup.sql. Safe to run again: it keeps all points.
-- Paste everything into Supabase -> SQL Editor -> New query, then press Run.

-- 1) Every activity a student finishes adds one row here
create table if not exists public.points (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind        text not null,              -- mock, px, gram, vocab, match, speak, write
  ref         text not null default '',   -- which mock / unit / set
  pts         int  not null,
  created_at  timestamptz not null default now()
);
create index if not exists points_user_idx on public.points(user_id, created_at);

-- Students can hide their name on the leaderboard
alter table public.profiles add column if not exists board_hide boolean not null default false;

-- 2) Security rules: students add only their own points, with sensible limits
alter table public.points enable row level security;
drop policy if exists "points read"   on public.points;
drop policy if exists "points insert" on public.points;
drop policy if exists "points delete" on public.points;
create policy "points read"   on public.points for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "points insert" on public.points for insert to authenticated
  with check (user_id = auth.uid()
              and pts between 1 and 100
              and kind in ('mock','px','gram','vocab','match','speak','write')
              and created_at > now() - interval '1 minute');
create policy "points delete" on public.points for delete to authenticated using (public.is_admin());
grant select, insert, delete on public.points to authenticated;

-- 3) How points are counted (Tashkent days):
--    only the first 3 tries of the same activity per day count,
--    and every day in a row adds a streak bonus: +5, +10, +15 … up to +50.
create or replace function public.pts_scored(uid uuid default null, since timestamptz default '-infinity')
returns table(user_id uuid, day date, pts bigint)
language sql stable security definer set search_path = public as $$
  with r as (
    select p.user_id, (p.created_at at time zone 'Asia/Tashkent')::date as day, p.pts,
           row_number() over (partition by p.user_id, p.kind, p.ref, (p.created_at at time zone 'Asia/Tashkent')::date
                              order by p.created_at) as n
    from public.points p
    where uid is null or p.user_id = uid
  ),
  d as (select r.user_id, r.day, sum(r.pts) as pts from r where r.n <= 3 group by r.user_id, r.day),
  s as (select d.user_id, d.day, d.pts, d.day - (row_number() over (partition by d.user_id order by d.day))::int as grp from d),
  b as (select s.user_id, s.day,
               s.pts + least(50, 5 * row_number() over (partition by s.user_id, s.grp order by s.day)) as pts
        from s)
  select b.user_id, b.day, b.pts from b
  where b.day >= (since at time zone 'Asia/Tashkent')::date
$$;
revoke all on function public.pts_scored(uuid, timestamptz) from public, anon, authenticated;

-- 4) A student's own total, this week, today and current streak
create or replace function public.my_points() returns json
language sql stable security definer set search_path = public as $$
  with x as (select * from public.pts_scored(auth.uid())),
  t as (select (now() at time zone 'Asia/Tashkent')::date as today),
  g as (select x.day, x.day - (row_number() over (order by x.day))::int as grp from x),
  cur as (select g.grp from g, t where g.day >= t.today - 1 order by g.day desc limit 1)
  select json_build_object(
    'total',  coalesce((select sum(pts) from x), 0),
    'week',   coalesce((select sum(pts) from x, t where x.day >= date_trunc('week', t.today)::date), 0),
    'today',  coalesce((select sum(pts) from x, t where x.day = t.today), 0),
    'streak', (select count(*) from g where g.grp = (select grp from cur)))
$$;

-- 5) This week's top 10 (+ the student's own place). First names only.
create or replace function public.points_board()
returns table(rank int, name text, avatar text, pts bigint, me boolean)
language sql stable security definer set search_path = public as $$
  with w as (
    select s.user_id, sum(s.pts) as pts
    from public.pts_scored(null, (date_trunc('week', now() at time zone 'Asia/Tashkent')) at time zone 'Asia/Tashkent') s
    group by s.user_id
  ),
  r as (
    select w.user_id, w.pts, (rank() over (order by w.pts desc))::int as rk, p.name, p.avatar, p.student_no, p.board_hide
    from w join public.profiles p on p.id = w.user_id
  )
  select r.rk,
         case when r.board_hide and r.user_id <> auth.uid() then 'Student ' || lpad(r.student_no::text, 6, '0')
              else split_part(trim(r.name), ' ', 1) end,
         case when r.board_hide and r.user_id <> auth.uid() then null else r.avatar end,
         r.pts, r.user_id = auth.uid()
  from r
  where r.rk <= 10 or r.user_id = auth.uid()
  order by r.rk
$$;

revoke all on function public.my_points()    from public, anon;
revoke all on function public.points_board() from public, anon;
grant execute on function public.my_points()    to authenticated;
grant execute on function public.points_board() to authenticated;

notify pgrst, 'reload schema';

select 'Points setup v5 finished - OK' as status;
