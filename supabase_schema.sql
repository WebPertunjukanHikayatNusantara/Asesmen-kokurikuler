-- Sistem Asesmen Kokurikuler Kelas X
-- Supabase migration foundation (PostgreSQL + RLS)
-- Run once in Supabase Dashboard > SQL Editor.
-- This schema preserves the existing Firestore document shape in JSONB while
-- moving authentication/authorization to Supabase Auth + PostgreSQL RLS.

create extension if not exists pgcrypto;

-- 1) User profiles: role and assignment data are server-controlled.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null default '',
  display_name text not null default '',
  photo_url text not null default '',
  role text not null default 'murid'
    check (role in ('admin', 'pendamping', 'walikelas', 'murid')),
  assigned_division_id text,
  secondary_division_id text,
  assigned_class_group text,
  student_id text,
  class_group text,
  nisn text,
  can_export boolean not null default false,
  invite_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profiles_email_lower_idx on public.profiles (lower(email));
create index if not exists profiles_role_idx on public.profiles (role);

-- 2) Generic document store. Existing app document fields remain camelCase JSON.
create table if not exists public.app_records (
  collection_name text not null check (collection_name in (
    'students', 'divisionPeers', 'assessments', 'selfAssessments',
    'studentReflections', 'appreciations', 'homeroomNotes', 'progressLogs',
    'staffAssignments', 'roleCodes', 'appConfig'
  )),
  id text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (collection_name, id)
);

create index if not exists app_records_collection_idx on public.app_records (collection_name);
create index if not exists app_records_data_gin_idx on public.app_records using gin (data);
create index if not exists app_records_student_id_idx on public.app_records ((data->>'studentId'));
create index if not exists app_records_class_group_idx on public.app_records ((data->>'classGroup'));
create index if not exists app_records_primary_division_idx on public.app_records ((data->>'primaryDivisionId'));
create index if not exists app_records_secondary_division_idx on public.app_records ((data->>'secondaryDivisionId'));
create index if not exists app_records_division_idx on public.app_records ((data->>'divisionId'));

-- 3) Helpers used by RLS. SECURITY DEFINER avoids recursive profile policies.
create or replace function public.current_user_role()
returns text language sql stable security definer set search_path = public
as $$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.current_user_division_ids()
returns text[] language sql stable security definer set search_path = public
as $$
  select array_remove(array[assigned_division_id, secondary_division_id], null)
  from public.profiles where id = auth.uid()
$$;

create or replace function public.current_user_class()
returns text language sql stable security definer set search_path = public
as $$ select assigned_class_group from public.profiles where id = auth.uid() $$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.current_user_role() = 'admin', false) $$;

create or replace function public.can_access_student(p_student_id text)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.is_admin()
    or exists (
      select 1 from public.app_records s
      where s.collection_name = 'students'
        and s.id = p_student_id
        and (
          (public.current_user_role() = 'pendamping' and (
            s.data->>'primaryDivisionId' = any(public.current_user_division_ids())
            or s.data->>'secondaryDivisionId' = any(public.current_user_division_ids())
          ))
          or (public.current_user_role() = 'walikelas'
            and s.data->>'classGroup' = public.current_user_class())
          or (public.current_user_role() = 'murid'
            and lower(coalesce(s.data->>'email','')) = lower(coalesce(auth.jwt()->>'email','')))
        )
    )
$$;

-- 4) Create a least-privilege profile after Google OAuth sign-up.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name, photo_url, role, can_export)
  values (
    new.id,
    lower(coalesce(new.email, '')),
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', ''),
    coalesce(new.raw_user_meta_data->>'avatar_url', new.raw_user_meta_data->>'picture', ''),
    case when lower(coalesce(new.email,'')) = 'prasetyoadhitama92@gmail.com' then 'admin' else 'murid' end,
    lower(coalesce(new.email,'')) = 'prasetyoadhitama92@gmail.com'
  )
  on conflict (id) do update set
    email = excluded.email,
    display_name = case when public.profiles.display_name = '' then excluded.display_name else public.profiles.display_name end,
    photo_url = case when public.profiles.photo_url = '' then excluded.photo_url else public.profiles.photo_url end,
    updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute procedure public.handle_new_auth_user();

-- 5) RLS and grants.
alter table public.profiles enable row level security;
alter table public.app_records enable row level security;

revoke all on public.profiles from anon, authenticated;
revoke all on public.app_records from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, photo_url, class_group, nisn, updated_at) on public.profiles to authenticated;
grant select, insert, update, delete on public.app_records to authenticated;

drop policy if exists "profiles_select_self_or_admin" on public.profiles;
create policy "profiles_select_self_or_admin" on public.profiles
for select to authenticated using (id = auth.uid() or public.is_admin());

drop policy if exists "profiles_update_self_basic_fields" on public.profiles;
create policy "profiles_update_self_basic_fields" on public.profiles
for update to authenticated using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

-- Read access by role and document scope.
drop policy if exists "records_read_by_role_scope" on public.app_records;
create policy "records_read_by_role_scope" on public.app_records
for select to authenticated using (
  public.is_admin()
  or (collection_name = 'appConfig')
  or (collection_name = 'staffAssignments'
      and lower(id) = lower(coalesce(auth.jwt()->>'email','')))
  or (collection_name = 'roleCodes' and false) -- Validate codes through a server-side RPC in the next migration step.
  or (collection_name = 'divisionPeers'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name = 'students' and (
      (public.current_user_role() = 'pendamping' and (
        data->>'primaryDivisionId' = any(public.current_user_division_ids())
        or data->>'secondaryDivisionId' = any(public.current_user_division_ids())))
      or (public.current_user_role() = 'walikelas' and data->>'classGroup' = public.current_user_class())
      or (public.current_user_role() = 'murid' and lower(coalesce(data->>'email','')) = lower(coalesce(auth.jwt()->>'email','')))
  ))
  or (collection_name in ('assessments','selfAssessments','studentReflections','appreciations','homeroomNotes','progressLogs')
      and public.can_access_student(coalesce(data->>'studentId', data->>'toStudentId')))
  or (collection_name = 'appreciations' and lower(coalesce(data->>'fromUserId','')) = auth.uid()::text)
);

-- Inserts: admins can manage all; teachers and students get narrowly scoped inserts.
drop policy if exists "records_insert_by_role_scope" on public.app_records;
create policy "records_insert_by_role_scope" on public.app_records
for insert to authenticated with check (
  public.is_admin()
  or (collection_name = 'assessments' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name in ('selfAssessments','studentReflections')
      and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId'))
  or (collection_name = 'appreciations'
      and data->>'fromUserId' = auth.uid()::text)
  or (collection_name = 'homeroomNotes'
      and public.current_user_role() = 'walikelas'
      and data->>'classGroup' = public.current_user_class())
);

-- Updates: scope remains tied to the same authorized record.
drop policy if exists "records_update_by_role_scope" on public.app_records;
create policy "records_update_by_role_scope" on public.app_records
for update to authenticated using (
  public.is_admin()
  or (collection_name = 'students' and public.current_user_role() = 'pendamping' and (
      data->>'primaryDivisionId' = any(public.current_user_division_ids())
      or data->>'secondaryDivisionId' = any(public.current_user_division_ids())))
  or (collection_name = 'assessments' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name in ('selfAssessments','studentReflections') and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId'))
  or (collection_name = 'appreciations' and data->>'fromUserId' = auth.uid()::text)
  or (collection_name = 'homeroomNotes' and public.current_user_role() = 'walikelas'
      and data->>'classGroup' = public.current_user_class())
  or (collection_name = 'progressLogs' and public.current_user_role() = 'pendamping'
      and (data->>'primaryDivisionId' = any(public.current_user_division_ids())
        or data->>'secondaryDivisionId' = any(public.current_user_division_ids())))
) with check (
  public.is_admin()
  or (collection_name = 'students' and public.current_user_role() = 'pendamping' and (
      data->>'primaryDivisionId' = any(public.current_user_division_ids())
      or data->>'secondaryDivisionId' = any(public.current_user_division_ids())))
  or (collection_name = 'assessments' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name in ('selfAssessments','studentReflections') and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId'))
  or (collection_name = 'appreciations' and data->>'fromUserId' = auth.uid()::text)
  or (collection_name = 'homeroomNotes' and public.current_user_role() = 'walikelas'
      and data->>'classGroup' = public.current_user_class())
  or (collection_name = 'progressLogs' and public.current_user_role() = 'pendamping'
      and (data->>'primaryDivisionId' = any(public.current_user_division_ids())
        or data->>'secondaryDivisionId' = any(public.current_user_division_ids())))
);

-- Deletes are deliberately restricted to admins. A later role-specific RPC can
-- grant narrowly scoped deletes after the app's delete workflows are reviewed.
drop policy if exists "records_delete_admin_only" on public.app_records;
create policy "records_delete_admin_only" on public.app_records
for delete to authenticated using (public.is_admin());

-- Realtime: add app_records to the publication if it is not already present.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_records'
  ) then
    alter publication supabase_realtime add table public.app_records;
  end if;
end $$;

-- Helpful view of current profile for authenticated sessions.
create or replace view public.my_profile as
select id, email, display_name, photo_url, role, assigned_division_id,
       secondary_division_id, assigned_class_group, student_id, class_group,
       nisn, can_export, created_at, updated_at
from public.profiles
where id = auth.uid();

grant select on public.my_profile to authenticated;

-- IMPORTANT:
-- 1. Configure Google provider in Authentication > Providers > Google.
-- 2. Set the exact Site URL and Redirect URLs in Authentication > URL Configuration.
-- 3. Do not expose service_role/secret keys in frontend code.
-- 4. Role-code verification and assignment writes must be moved to a trusted RPC/Edge Function
--    before enabling staff self-registration. This is intentionally not exposed to clients here.
