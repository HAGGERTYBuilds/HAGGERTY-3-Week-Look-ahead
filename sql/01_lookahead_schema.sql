-- Haggerty Look-Ahead: tables + access functions.
-- Tables are deny-all under RLS; the app only talks to the security-definer
-- functions below, and every call carries the super's personal access code.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.la_supers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  code_hash   text not null unique,
  is_admin    boolean not null default false,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  last_seen   timestamptz
);

create table if not exists public.la_jobs (
  id          uuid primary key default gen_random_uuid(),
  super_id    uuid not null references public.la_supers(id) on delete cascade,
  number      text not null default '',
  name        text not null default '',
  mode        text not null default 'res' check (mode in ('res','com')),
  cm          text not null default '',
  sup_name    text not null default '',
  color       text not null default '#F7943F',
  weekends    boolean not null default false,
  sort        int not null default 0,
  rev         int not null default 0,          -- bumps on every save
  archived    boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists la_jobs_super_idx on public.la_jobs(super_id);

create table if not exists public.la_tasks (
  row_id      bigint generated always as identity primary key,
  id          uuid not null,                   -- task id, stable across revisions
  job_id      uuid not null references public.la_jobs(id) on delete cascade,
  position    int not null default 0,
  name        text not null default '',
  resource    text not null default '',
  is_section  boolean not null default false,
  rev         int not null default 0,          -- matches la_jobs.rev for the current list; older revs are history
  after_id    uuid,
  cells       jsonb not null default '{}'::jsonb,   -- {"2026-10-19":"B","2026-10-20":"R"}
  updated_at  timestamptz not null default now()
);
create index if not exists la_tasks_job_rev_idx on public.la_tasks(job_id, rev);

-- A copy of a job's look-ahead each time a super submits it for the week.
create table if not exists public.la_submissions (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid not null references public.la_jobs(id) on delete cascade,
  super_id     uuid not null references public.la_supers(id) on delete cascade,
  week_start   date not null,
  submitted_at timestamptz not null default now(),
  snapshot     jsonb not null
);
create index if not exists la_submissions_job_idx on public.la_submissions(job_id, week_start);

alter table public.la_supers      enable row level security;
alter table public.la_jobs        enable row level security;
alter table public.la_tasks       enable row level security;
alter table public.la_submissions enable row level security;
revoke all on public.la_supers, public.la_jobs, public.la_tasks, public.la_submissions from anon, authenticated;

-- ---------- helpers ----------
create or replace function public.la_hash(p_code text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest('haggerty-lookahead:' || upper(trim(p_code)), 'sha256'), 'hex')
$$;

create or replace function public.la_who(p_code text) returns public.la_supers
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers;
begin
  select * into s from public.la_supers where code_hash = public.la_hash(p_code) and active;
  if s.id is null then
    perform pg_sleep(0.5);  -- slow down code guessing
    raise exception 'Unknown access code' using errcode = '28000';
  end if;
  update public.la_supers set last_seen = now() where id = s.id;
  return s;
end $$;

create or replace function public.la_job_json(p_job public.la_jobs) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', p_job.id, 'superId', p_job.super_id, 'number', p_job.number, 'name', p_job.name,
    'mode', p_job.mode, 'cm', p_job.cm, 'sup', p_job.sup_name, 'color', p_job.color,
    'weekends', p_job.weekends, 'sort', p_job.sort, 'updatedAt', p_job.updated_at, 'rev', p_job.rev,
    'lastSubmitted', (select max(submitted_at) from public.la_submissions x where x.job_id = p_job.id),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'res', t.resource, 'sec', t.is_section,
        'after', t.after_id, 'cells', t.cells) order by t.position)
      from public.la_tasks t where t.job_id = p_job.id and t.rev = p_job.rev), '[]'::jsonb))
$$;

-- ---------- app API (callable with the publishable key) ----------
create or replace function public.la_login(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  return jsonb_build_object('id', s.id, 'name', s.name, 'isAdmin', s.is_admin);
end $$;

-- Own jobs; admins get every active job plus the super list.
create or replace function public.la_get_jobs(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  return jsonb_build_object(
    'jobs', coalesce((select jsonb_agg(public.la_job_json(j) order by j.sort, j.created_at)
                      from public.la_jobs j
                      where not j.archived and (j.super_id = s.id or s.is_admin)), '[]'::jsonb),
    'supers', case when s.is_admin then coalesce((select jsonb_agg(jsonb_build_object(
                 'id', x.id, 'name', x.name, 'isAdmin', x.is_admin, 'lastSeen', x.last_seen) order by x.name)
               from public.la_supers x where x.active), '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- Upsert one whole job (header + all tasks). Each save writes a new revision of
-- the task list; older revisions stay as history. Returns the saved job.
create or replace function public.la_save_job(p_code text, p_job jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s public.la_supers := public.la_who(p_code);
  v_id uuid := (p_job->>'id')::uuid;
  v_owner uuid;
  j public.la_jobs;
  t jsonb; i int := 0;
begin
  select super_id into v_owner from public.la_jobs where id = v_id;
  if v_owner is not null and v_owner <> s.id and not s.is_admin then
    raise exception 'That job belongs to another super' using errcode = '42501';
  end if;
  insert into public.la_jobs as x (id, super_id, number, name, mode, cm, sup_name, color, weekends, sort, rev, updated_at)
  values (v_id, coalesce(v_owner, s.id), coalesce(p_job->>'number',''), coalesce(p_job->>'name',''),
          case when p_job->>'mode' = 'com' then 'com' else 'res' end, coalesce(p_job->>'cm',''),
          coalesce(p_job->>'sup',''), coalesce(p_job->>'color','#F7943F'),
          coalesce((p_job->>'weekends')::boolean,false), coalesce((p_job->>'sort')::int,0), 1, now())
  on conflict (id) do update set number = excluded.number, name = excluded.name, mode = excluded.mode,
     cm = excluded.cm, sup_name = excluded.sup_name, color = excluded.color, weekends = excluded.weekends,
     sort = excluded.sort, archived = false, rev = x.rev + 1, updated_at = now()
  returning * into j;

  for t in select * from jsonb_array_elements(coalesce(p_job->'tasks','[]'::jsonb)) loop
    i := i + 1;
    insert into public.la_tasks (id, job_id, rev, position, name, resource, is_section, after_id, cells)
    values ((t->>'id')::uuid, j.id, j.rev, i, coalesce(t->>'name',''), coalesce(t->>'res',''),
            coalesce((t->>'sec')::boolean,false), nullif(t->>'after','')::uuid,
            coalesce(t->'cells','{}'::jsonb));
  end loop;
  return public.la_job_json(j);
end $$;

create or replace function public.la_archive_job(p_code text, p_job_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  update public.la_jobs set archived = true, updated_at = now()
  where id = p_job_id and (super_id = s.id or s.is_admin);
end $$;

-- Super sends this week's look-ahead for one or more jobs.
create or replace function public.la_submit(p_code text, p_job_ids uuid[], p_week_start date) returns int
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code); n int;
begin
  insert into public.la_submissions (job_id, super_id, week_start, snapshot)
  select j.id, j.super_id, p_week_start, public.la_job_json(j)
  from public.la_jobs j where j.id = any(p_job_ids) and (j.super_id = s.id or s.is_admin);
  get diagnostics n = row_count;
  return n;
end $$;

-- Admin: who has submitted for a week.
create or replace function public.la_week_report(p_code text, p_week_start date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  if not s.is_admin then raise exception 'Admins only' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'jobId', j.id, 'job', j.name, 'number', j.number, 'super', x.name,
      'submittedAt', (select max(submitted_at) from public.la_submissions b where b.job_id = j.id and b.week_start = p_week_start))
      order by x.name, j.name)
    from public.la_jobs j join public.la_supers x on x.id = j.super_id where not j.archived), '[]'::jsonb);
end $$;

-- Admin: add a super, returns their new code (shown once).
create or replace function public.la_add_super(p_code text, p_name text, p_is_admin boolean default false) returns text
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code); v_code text;
begin
  if not s.is_admin then raise exception 'Admins only' using errcode = '42501'; end if;
  v_code := upper(substr(translate(encode(extensions.gen_random_bytes(12),'base64'),'+/=0O1lI',''),1,8));
  insert into public.la_supers (name, code_hash, is_admin) values (trim(p_name), public.la_hash(v_code), p_is_admin);
  return v_code;
end $$;

-- SQL-editor only (not granted to the app): first admin, or a code reset.
create or replace function public.la_bootstrap_super(p_name text, p_code text, p_is_admin boolean) returns uuid
language sql security definer set search_path = '' as $$
  insert into public.la_supers (name, code_hash, is_admin) values (p_name, public.la_hash(p_code), p_is_admin)
  on conflict (code_hash) do update set name = excluded.name, is_admin = excluded.is_admin, active = true
  returning id
$$;

revoke all on function public.la_who(text), public.la_hash(text), public.la_job_json(public.la_jobs),
  public.la_bootstrap_super(text,text,boolean) from public, anon, authenticated;
revoke all on function public.la_login(text), public.la_get_jobs(text), public.la_save_job(text,jsonb),
  public.la_archive_job(text,uuid), public.la_submit(text,uuid[],date), public.la_week_report(text,date),
  public.la_add_super(text,text,boolean) from public;
grant execute on function public.la_login(text), public.la_get_jobs(text), public.la_save_job(text,jsonb),
  public.la_archive_job(text,uuid), public.la_submit(text,uuid[],date), public.la_week_report(text,date),
  public.la_add_super(text,text,boolean) to anon, authenticated;
