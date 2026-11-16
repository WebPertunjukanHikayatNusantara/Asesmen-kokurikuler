-- Run after supabase_schema.sql. Securely validates staff role codes server-side.
create or replace function public.complete_user_onboarding(
  p_intended_role text default 'murid',
  p_preferred_division_id text default null,
  p_preferred_class text default 'X-1',
  p_access_code text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt()->>'email',''));
  v_role text := 'murid';
  v_staff jsonb;
  v_code jsonb;
  v_existing public.profiles%rowtype;
  v_division text;
  v_class text;
  v_can_export boolean := false;
begin
  if v_uid is null then raise exception 'Sesi login tidak ditemukan.'; end if;
  if p_intended_role not in ('admin','pendamping','walikelas','murid') then
    raise exception 'Role tidak valid.';
  end if;

  select * into v_existing from public.profiles where id = v_uid;
  select data into v_staff from public.app_records
    where collection_name = 'staffAssignments' and lower(id) = v_email limit 1;

  if v_email = 'prasetyoadhitama92@gmail.com' then
    v_role := 'admin'; v_can_export := true;
  elsif v_staff is not null and v_staff->>'role' = p_intended_role then
    v_role := p_intended_role;
    v_can_export := coalesce((v_staff->>'canExport')::boolean, true);
  elsif v_existing.id is not null and v_existing.role = 'admin' then
    v_role := 'admin'; v_can_export := true;
  elsif p_intended_role = 'murid' then
    v_role := 'murid';
  elsif v_existing.id is not null and v_existing.role = p_intended_role then
    v_role := p_intended_role; v_can_export := v_existing.can_export;
  else
    if p_intended_role = 'admin' then
      raise exception 'Role admin hanya dapat diberikan kepada email bootstrap atau melalui penugasan Admin.';
    end if;
    select data into v_code from public.app_records
      where collection_name = 'roleCodes'
        and upper(id) = upper(coalesce(p_access_code,''))
        and coalesce((data->>'active')::boolean,false) = true
      limit 1;
    if v_code is null or v_code->>'role' <> p_intended_role then
      raise exception 'Kode otorisasi tidak cocok atau email belum ditugaskan oleh Admin.';
    end if;
    v_role := p_intended_role;
    v_can_export := v_role in ('admin','pendamping','walikelas');
  end if;

  v_division := coalesce(v_staff->>'assignedDivisionId', p_preferred_division_id, v_existing.assigned_division_id);
  v_class := coalesce(v_staff->>'assignedClassGroup', p_preferred_class, v_existing.assigned_class_group, v_existing.class_group, 'X-1');

  insert into public.profiles (
    id,email,display_name,photo_url,role,assigned_division_id,secondary_division_id,
    assigned_class_group,student_id,class_group,nisn,can_export,invite_code,updated_at
  ) values (
    v_uid,v_email,
    coalesce(nullif(auth.jwt()->'user_metadata'->>'full_name',''),nullif(auth.jwt()->'user_metadata'->>'name',''),'Warga Sekolah'),
    coalesce(auth.jwt()->'user_metadata'->>'avatar_url',auth.jwt()->'user_metadata'->>'picture',''),
    v_role,v_division,v_existing.secondary_division_id,
    case when v_role='walikelas' then v_class else v_existing.assigned_class_group end,
    v_existing.student_id,v_class,v_existing.nisn,v_can_export,
    coalesce(nullif(upper(p_access_code),''),v_existing.invite_code),now()
  )
  on conflict (id) do update set
    email=excluded.email,
    display_name=coalesce(nullif(public.profiles.display_name,''),excluded.display_name),
    photo_url=coalesce(nullif(public.profiles.photo_url,''),excluded.photo_url),
    role=excluded.role,
    assigned_division_id=coalesce(excluded.assigned_division_id,public.profiles.assigned_division_id),
    assigned_class_group=coalesce(excluded.assigned_class_group,public.profiles.assigned_class_group),
    class_group=coalesce(excluded.class_group,public.profiles.class_group),
    can_export=excluded.can_export,
    invite_code=coalesce(excluded.invite_code,public.profiles.invite_code),
    updated_at=now();
end;
$$;
revoke all on function public.complete_user_onboarding(text,text,text,text) from public, anon;
grant execute on function public.complete_user_onboarding(text,text,text,text) to authenticated;

create or replace function public.current_user_student_id()
returns text language sql stable security definer set search_path = public
as $$ select student_id from public.profiles where id = auth.uid() $$;

-- Allow the signed-in student to maintain only their own non-privileged profile linkage.
grant update (display_name, photo_url, class_group, nisn, student_id,
              assigned_division_id, secondary_division_id, updated_at)
on public.profiles to authenticated;

-- Student self-claim is limited to a student row carrying their verified Google email.
drop policy if exists "records_insert_by_role_scope" on public.app_records;
create policy "records_insert_by_role_scope" on public.app_records
for insert to authenticated with check (
  public.is_admin()
  or (collection_name = 'students' and public.current_user_role() = 'murid'
      and lower(coalesce(data->>'email','')) = lower(coalesce(auth.jwt()->>'email','')))
  or (collection_name = 'divisionPeers' and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId')
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name = 'divisionPeers' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name = 'progressLogs' and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId'))
  or (collection_name = 'assessments' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name in ('selfAssessments','studentReflections')
      and public.current_user_role() = 'murid' and public.can_access_student(data->>'studentId'))
  or (collection_name = 'appreciations' and data->>'fromUserId' = auth.uid()::text)
  or (collection_name = 'homeroomNotes' and public.current_user_role() = 'walikelas'
      and data->>'classGroup' = public.current_user_class())
);

drop policy if exists "records_update_by_role_scope" on public.app_records;
create policy "records_update_by_role_scope" on public.app_records
for update to authenticated using (
  public.is_admin()
  or (collection_name = 'students' and (
      (public.current_user_role() = 'pendamping' and (
        data->>'primaryDivisionId' = any(public.current_user_division_ids())
        or data->>'secondaryDivisionId' = any(public.current_user_division_ids())))
      or (public.current_user_role() = 'murid' and (
        lower(coalesce(data->>'email','')) = lower(coalesce(auth.jwt()->>'email',''))
        or (id = public.current_user_student_id() and coalesce(data->>'email','') ~ '^std_.*@siswa\.smyosef\.sch\.id$')))))
  or (collection_name = 'divisionPeers' and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId')
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name = 'divisionPeers' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name = 'assessments' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name in ('selfAssessments','studentReflections') and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId'))
  or (collection_name = 'appreciations' and data->>'fromUserId' = auth.uid()::text)
  or (collection_name = 'homeroomNotes' and public.current_user_role() = 'walikelas'
      and data->>'classGroup' = public.current_user_class())
  or (collection_name = 'progressLogs' and (
      (public.current_user_role() = 'pendamping' and (
        data->>'primaryDivisionId' = any(public.current_user_division_ids())
        or data->>'secondaryDivisionId' = any(public.current_user_division_ids())))
      or (public.current_user_role() = 'murid' and public.can_access_student(data->>'studentId'))))
) with check (
  public.is_admin()
  or (collection_name = 'students' and (
      (public.current_user_role() = 'pendamping' and (
        data->>'primaryDivisionId' = any(public.current_user_division_ids())
        or data->>'secondaryDivisionId' = any(public.current_user_division_ids())))
      or (public.current_user_role() = 'murid' and (
        lower(coalesce(data->>'email','')) = lower(coalesce(auth.jwt()->>'email',''))
        or (id = public.current_user_student_id() and coalesce(data->>'email','') ~ '^std_.*@siswa\.smyosef\.sch\.id$')))))
  or (collection_name = 'divisionPeers' and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId')
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name = 'divisionPeers' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name = 'assessments' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name in ('selfAssessments','studentReflections') and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId'))
  or (collection_name = 'appreciations' and data->>'fromUserId' = auth.uid()::text)
  or (collection_name = 'homeroomNotes' and public.current_user_role() = 'walikelas'
      and data->>'classGroup' = public.current_user_class())
  or (collection_name = 'progressLogs' and (
      (public.current_user_role() = 'pendamping' and (
        data->>'primaryDivisionId' = any(public.current_user_division_ids())
        or data->>'secondaryDivisionId' = any(public.current_user_division_ids())))
      or (public.current_user_role() = 'murid' and public.can_access_student(data->>'studentId'))))
);

drop policy if exists "records_delete_admin_only" on public.app_records;
create policy "records_delete_by_owner_or_admin" on public.app_records
for delete to authenticated using (
  public.is_admin()
  or (collection_name = 'assessments' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
  or (collection_name = 'appreciations' and data->>'fromUserId' = auth.uid()::text)
  or (collection_name = 'divisionPeers' and public.current_user_role() = 'murid'
      and public.can_access_student(data->>'studentId'))
  or (collection_name = 'divisionPeers' and public.current_user_role() = 'pendamping'
      and data->>'divisionId' = any(public.current_user_division_ids()))
);

-- Match the existing Firestore self-claim workflow for preloaded placeholder roster rows.
drop policy if exists "students_claim_target_read" on public.app_records;
create policy "students_claim_target_read" on public.app_records
for select to authenticated using (
  collection_name = 'students' and public.current_user_role() = 'murid'
  and id = public.current_user_student_id()
);

-- For a placeholder roster row, the app must keep the official ID, name, NISN and class unchanged.
create or replace function public.guard_student_self_update()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_email text := lower(coalesce(auth.jwt()->>'email',''));
begin
  if old.collection_name = 'students' and new.collection_name = 'students'
     and public.current_user_role() = 'murid' and not public.is_admin() then
    if lower(coalesce(old.data->>'email','')) = v_email then
      if (old.data - array['primaryDivisionId','secondaryDivisionId','name','classGroup','nisn','gender','isDpkCommittee','updatedAt'])
         <> (new.data - array['primaryDivisionId','secondaryDivisionId','name','classGroup','nisn','gender','isDpkCommittee','updatedAt']) then
        raise exception 'Perubahan data siswa tidak diizinkan.';
      end if;
    elsif coalesce(old.data->>'email','') ~ '^std_.*@siswa\.smyosef\.sch\.id$' then
      if old.id <> public.current_user_student_id()
         or new.data->>'id' <> old.data->>'id'
         or new.data->>'name' <> old.data->>'name'
         or new.data->>'nisn' <> old.data->>'nisn'
         or new.data->>'classGroup' <> old.data->>'classGroup'
         or lower(coalesce(new.data->>'email','')) <> v_email
         or (old.data - array['email','gender','primaryDivisionId','secondaryDivisionId','isDpkCommittee','updatedAt'])
            <> (new.data - array['email','gender','primaryDivisionId','secondaryDivisionId','isDpkCommittee','updatedAt']) then
        raise exception 'Data roster tidak cocok dengan identitas siswa.';
      end if;
    else
      raise exception 'Siswa hanya dapat memperbarui data miliknya.';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists guard_student_self_update_trigger on public.app_records;
create trigger guard_student_self_update_trigger
before update on public.app_records
for each row execute function public.guard_student_self_update();

-- Atomic bulk import used by the admin's official roster import workflow.
create or replace function public.admin_upsert_records_batch(p_records jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Hanya Admin yang dapat melakukan impor roster.'; end if;
  if jsonb_typeof(p_records) <> 'array' then raise exception 'Format batch tidak valid.'; end if;
  insert into public.app_records (collection_name,id,data,updated_at)
  select r.collection_name,r.id,r.data,now()
  from jsonb_to_recordset(p_records) as r(collection_name text,id text,data jsonb)
  on conflict (collection_name,id) do update
    set data = excluded.data, updated_at = now();
end;
$$;
revoke all on function public.admin_upsert_records_batch(jsonb) from public, anon;
grant execute on function public.admin_upsert_records_batch(jsonb) to authenticated;
