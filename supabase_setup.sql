-- Teacher Azimjon website: database setup.
-- Paste everything into Supabase -> SQL Editor -> New query, then press Run.

-- 1) Student numbers: 1, 2, 3 ... (shown on the site as 000001, 000002 ...)
create sequence if not exists public.student_no_seq start 1;

-- 2) Students
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  student_no  int unique,
  name        text not null default '',
  email       text not null,
  avatar      text default '🙂',
  goal        text default 'B2',
  paid        boolean not null default false,
  paid_at     timestamptz,
  created_at  timestamptz not null default now()
);

-- 3) Scores (mocks and practice exercises)
create table if not exists public.results (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  mock        text not null,
  score       int  not null,
  total       int  not null,
  created_at  timestamptz not null default now()
);
create index if not exists results_user_idx on public.results(user_id);

-- 4) Site settings (free list, Telegram, price) – one row
create table if not exists public.settings (
  id          int primary key default 1 check (id = 1),
  free        jsonb not null default '[]'::jsonb,
  tg          text default '',
  price       text default '',
  updated_at  timestamptz default now()
);
insert into public.settings (id, free, tg, price)
values (1, '["1","L1","r1-1","r2-1","r3-1","r4-1","r5-1","l1-1","l2-1","l3-1","l4-1","l5-1","l6-1"]'::jsonb, 'azimjonadminTG', '49 000')
on conflict (id) do nothing;

-- 5) Who is the teacher (admin): only the account(s) listed in this table
create table if not exists public.admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.admins enable row level security;
insert into public.admins (user_id)
  select id from auth.users where lower(email) = 'azimjon.6561@gmail.com'
on conflict do nothing;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

-- 6) Every new sign-up gets the next Student number automatically
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if lower(new.email) <> 'azimjon.6561@gmail.com' then
    insert into public.profiles (id, student_no, name, email)
    values (new.id, nextval('public.student_no_seq'),
            coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), split_part(new.email, '@', 1)),
            lower(new.email));
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 7) Students cannot give themselves full access or change their number
create or replace function public.guard_profile() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.paid := old.paid;
    new.paid_at := old.paid_at;
  end if;
  new.id := old.id;
  new.student_no := old.student_no;
  new.email := old.email;
  new.created_at := old.created_at;
  if new.paid and not old.paid then new.paid_at := now(); end if;
  if not new.paid then new.paid_at := null; end if;
  return new;
end $$;
drop trigger if exists guard_profile on public.profiles;
create trigger guard_profile before update on public.profiles
  for each row execute function public.guard_profile();

-- 8) Security rules
alter table public.profiles enable row level security;
alter table public.results  enable row level security;
alter table public.settings enable row level security;

drop policy if exists "profiles read"   on public.profiles;
drop policy if exists "profiles update" on public.profiles;
drop policy if exists "results read"    on public.results;
drop policy if exists "results insert"  on public.results;
drop policy if exists "results delete"  on public.results;
drop policy if exists "settings read"   on public.settings;
drop policy if exists "settings update" on public.settings;

create policy "profiles read"   on public.profiles for select to authenticated using (id = auth.uid() or public.is_admin());
create policy "profiles update" on public.profiles for update to authenticated using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());
create policy "results read"    on public.results  for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "results insert"  on public.results  for insert to authenticated with check (user_id = auth.uid());
create policy "results delete"  on public.results  for delete to authenticated using (public.is_admin());
create policy "settings read"   on public.settings for select to anon, authenticated using (true);
create policy "settings update" on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant usage on schema public to anon, authenticated;
grant select on public.settings to anon, authenticated;
grant update on public.settings to authenticated;
grant select, update on public.profiles to authenticated;
grant select, insert, delete on public.results to authenticated;
grant execute on function public.is_admin() to anon, authenticated;

select case when exists (select 1 from public.admins) then 'Setup finished ✅ Teacher account found.' else 'Setup finished, but the teacher account was NOT found. Create it first (Authentication -> Users -> Add user), then run this again.' end as status;
