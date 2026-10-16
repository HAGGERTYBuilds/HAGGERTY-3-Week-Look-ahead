-- Roles for leadership dashboards.
--   super  : edits only their own jobs
--   admin  : everything
--   viewer : read-only overview (VP / general superintendents), limited by scope
--   scope  : 'all', 'res' (restoration jobs) or 'com' (commercial jobs); used for viewers
alter table public.la_supers add column if not exists role text not null default 'super';
alter table public.la_supers add column if not exists scope text not null default 'all';
alter table public.la_supers add constraint la_supers_role_chk check (role in ('super','admin','viewer'));
alter table public.la_supers add constraint la_supers_scope_chk check (scope in ('all','res','com'));
update public.la_supers set role = 'admin' where is_admin and role <> 'admin';

create or replace function public.la_sees(s public.la_supers, j public.la_jobs) returns boolean
language sql stable set search_path = '' as $$
  select s.is_admin or j.super_id = s.id or (s.role = 'viewer' and (s.scope = 'all' or s.scope = j.mode))
$$;

create or replace function public.la_login(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  return jsonb_build_object('id', s.id, 'name', s.name, 'isAdmin', s.is_admin, 'role', s.role, 'scope', s.scope);
end $$;

-- Own jobs for supers; every job for admins; jobs in scope for viewers. Admins and viewers also get the people list.
create or replace function public.la_get_jobs(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  return jsonb_build_object(
    'jobs', coalesce((select jsonb_agg(public.la_job_json(j) order by j.sort, j.created_at)
                      from public.la_jobs j where not j.archived and public.la_sees(s, j)), '[]'::jsonb),
    'supers', case when s.is_admin or s.role = 'viewer' then coalesce((select jsonb_agg(jsonb_build_object(
                 'id', x.id, 'name', x.name, 'isAdmin', x.is_admin, 'role', x.role, 'scope', x.scope, 'lastSeen', x.last_seen) order by x.name)
               from public.la_supers x where x.active
                 and (s.is_admin or exists (select 1 from public.la_jobs j where j.super_id = x.id and not j.archived and public.la_sees(s, j)))),
               '[]'::jsonb) else '[]'::jsonb end);
end $$;

create or replace function public.la_week_report(p_code text, p_week_start date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  if not (s.is_admin or s.role = 'viewer') then raise exception 'Admins only' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'jobId', j.id, 'job', j.name, 'number', j.number, 'super', x.name,
      'submittedAt', (select max(submitted_at) from public.la_submissions b where b.job_id = j.id and b.week_start = p_week_start))
      order by x.name, j.name)
    from public.la_jobs j join public.la_supers x on x.id = j.super_id where not j.archived and public.la_sees(s, j)), '[]'::jsonb);
end $$;

-- Admins add a super, an admin, or a view-only leader with a scope. Returns the new code once.
create or replace function public.la_add_person(p_code text, p_name text, p_role text, p_scope text) returns text
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code); v_code text;
begin
  if not s.is_admin then raise exception 'Admins only' using errcode = '42501'; end if;
  v_code := upper(substr(translate(encode(extensions.gen_random_bytes(12),'base64'),'+/=0O1lI',''),1,8));
  insert into public.la_supers (name, code_hash, is_admin, role, scope)
  values (trim(p_name), public.la_hash(v_code), p_role = 'admin', coalesce(p_role,'super'), coalesce(p_scope,'all'));
  return v_code;
end $$;

revoke all on function public.la_sees(public.la_supers, public.la_jobs) from public, anon, authenticated;
revoke all on function public.la_add_person(text,text,text,text) from public;
grant execute on function public.la_add_person(text,text,text,text) to anon, authenticated;

-- Divisions (2026-10-16): for supers, scope is their division. 'res' or 'com' sets the type of
-- every job they run (enforced in la_save_job); 'all' means they run both kinds.
-- Leaders see jobs of their type, plus every job run by a super in their division.
create or replace function public.la_sees(s public.la_supers, j public.la_jobs) returns boolean
language sql stable set search_path = '' as $$
  select s.is_admin or j.super_id = s.id or (s.role = 'viewer' and (s.scope = 'all' or s.scope = j.mode
    or exists (select 1 from public.la_supers o where o.id = j.super_id and o.scope = s.scope)))
$$;

-- Admins set a person's division (supers) or which jobs they see (leaders). Jobs follow a super's new division.
create or replace function public.la_set_scope(p_code text, p_super_id uuid, p_scope text) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  if not s.is_admin then raise exception 'Admins only' using errcode = '42501'; end if;
  if p_scope not in ('all','res','com') then raise exception 'Unknown division' using errcode = '22023'; end if;
  update public.la_supers set scope = p_scope where id = p_super_id;
  if p_scope in ('res','com') then
    update public.la_jobs set mode = p_scope, updated_at = now() where super_id = p_super_id and mode <> p_scope;
  end if;
end $$;
revoke all on function public.la_set_scope(text,uuid,text) from public;
grant execute on function public.la_set_scope(text,uuid,text) to anon, authenticated;
