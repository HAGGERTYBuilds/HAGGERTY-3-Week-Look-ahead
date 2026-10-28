-- Marketing stars (2026-10-28): a super taps ⭐ on a day to tell Liam (marketing)
-- a milestone is coming, so he can plan photos and posts around it.
-- Stars live in their own column, never in cells, so the client printout, the
-- Excel download and the internal sheet never show them. Viewers (leaders) never
-- get them either: la_get_jobs only sends stars to the job's super and admins.

alter table public.la_tasks add column if not exists stars jsonb not null default '{}'::jsonb;  -- {"2026-11-05":"Slab pour"}

-- la_job_json(job, with_stars). The one-argument form (used for weekly snapshots) leaves stars out.
create or replace function public.la_job_json(p_job public.la_jobs, p_stars boolean) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', p_job.id, 'superId', p_job.super_id, 'number', p_job.number, 'name', p_job.name,
    'mode', p_job.mode, 'cm', p_job.cm, 'sup', p_job.sup_name, 'color', p_job.color,
    'weekends', p_job.weekends, 'sort', p_job.sort, 'updatedAt', p_job.updated_at, 'rev', p_job.rev,
    'logo', p_job.client_logo, 'client', p_job.client_name,
    'lastSubmitted', (select max(submitted_at) from public.la_submissions x where x.job_id = p_job.id),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'res', t.resource, 'sec', t.is_section,
        'after', t.after_id, 'cells', t.cells)
        || case when p_stars then jsonb_build_object('stars', t.stars) else '{}'::jsonb end
        order by t.position)
      from public.la_tasks t where t.job_id = p_job.id and t.rev = p_job.rev), '[]'::jsonb))
$$;

create or replace function public.la_job_json(p_job public.la_jobs) returns jsonb
language sql stable set search_path = '' as $$ select public.la_job_json(p_job, false) $$;

create or replace function public.la_get_jobs(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  return jsonb_build_object(
    'jobs', coalesce((select jsonb_agg(public.la_job_json(j, s.is_admin or j.super_id = s.id) order by j.sort, j.created_at)
                      from public.la_jobs j where not j.archived and public.la_sees(s, j)), '[]'::jsonb),
    'supers', case when s.is_admin or s.role = 'viewer' then coalesce((select jsonb_agg(jsonb_build_object(
                 'id', x.id, 'name', x.name, 'isAdmin', x.is_admin, 'role', x.role, 'scope', x.scope, 'lastSeen', x.last_seen) order by x.name)
               from public.la_supers x where x.active
                 and (s.is_admin or exists (select 1 from public.la_jobs j where j.super_id = x.id and not j.archived and public.la_sees(s, j)))),
               '[]'::jsonb) else '[]'::jsonb end);
end $$;

-- Same as before, plus each task's stars.
create or replace function public.la_save_job(p_code text, p_job jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s public.la_supers := public.la_who(p_code);
  v_id uuid := (p_job->>'id')::uuid;
  v_owner uuid;
  v_target uuid;
  v_mode text := case when p_job->>'mode' = 'com' then 'com' else 'res' end;
  v_div text;
  j public.la_jobs;
  t jsonb; i int := 0;
begin
  if s.role = 'viewer' then raise exception 'View-only access' using errcode = '42501'; end if;
  select super_id into v_owner from public.la_jobs where id = v_id;
  if v_owner is not null and v_owner <> s.id and not s.is_admin then
    raise exception 'That job belongs to another super' using errcode = '42501';
  end if;
  v_target := coalesce(v_owner, s.id);
  if s.is_admin and nullif(p_job->>'superId','') is not null then
    select id into v_target from public.la_supers where id = (p_job->>'superId')::uuid and active;
    if v_target is null then raise exception 'Unknown super' using errcode = '22023'; end if;
  end if;
  select scope into v_div from public.la_supers where id = v_target;
  if v_div in ('res','com') then v_mode := v_div; end if;
  insert into public.la_jobs as x (id, super_id, number, name, mode, cm, sup_name, color, weekends, sort, rev, updated_at)
  values (v_id, v_target, coalesce(p_job->>'number',''), coalesce(p_job->>'name',''),
          v_mode, coalesce(p_job->>'cm',''),
          coalesce(p_job->>'sup',''), coalesce(p_job->>'color','#F7943F'),
          coalesce((p_job->>'weekends')::boolean,false), coalesce((p_job->>'sort')::int,0), 1, now())
  on conflict (id) do update set super_id = excluded.super_id, number = excluded.number, name = excluded.name, mode = excluded.mode,
     cm = excluded.cm, sup_name = excluded.sup_name, color = excluded.color, weekends = excluded.weekends,
     sort = excluded.sort, archived = false, rev = x.rev + 1, updated_at = now()
  returning * into j;

  for t in select * from jsonb_array_elements(coalesce(p_job->'tasks','[]'::jsonb)) loop
    i := i + 1;
    insert into public.la_tasks (id, job_id, rev, position, name, resource, is_section, after_id, cells, stars)
    values ((t->>'id')::uuid, j.id, j.rev, i, coalesce(t->>'name',''), coalesce(t->>'res',''),
            coalesce((t->>'sec')::boolean,false), nullif(t->>'after','')::uuid,
            coalesce(t->'cells','{}'::jsonb),
            case when jsonb_typeof(t->'stars') = 'object' then t->'stars' else '{}'::jsonb end);
  end loop;
  return public.la_job_json(j, true);
end $$;

-- Feed for the marketing dashboard: {rows:[...]}, every star on a live job from 14 days ago on.
-- The marketing side calls this once a day with a feed key; only its hash is stored here.
create table if not exists public.la_feed_keys (
  name       text primary key,
  key_hash   text not null,
  created_at timestamptz not null default now()
);
alter table public.la_feed_keys enable row level security;
revoke all on public.la_feed_keys from anon, authenticated;

create or replace function public.la_marketing_feed(p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.la_feed_keys where name = 'marketing' and key_hash = public.la_hash(p_key)) then
    perform pg_sleep(0.5);
    raise exception 'Unknown feed key' using errcode = '28000';
  end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object(
      'jobId', j.id, 'jobNumber', j.number, 'job', j.name, 'mode', j.mode,
      'super', coalesce(nullif(j.sup_name,''), x.name), 'taskId', t.id, 'task', t.name,
      'day', e.key, 'note', e.value, 'critical', t.cells->>e.key = 'R') order by e.key, j.name)
    from public.la_jobs j
    join public.la_supers x on x.id = j.super_id
    join public.la_tasks t on t.job_id = j.id and t.rev = j.rev
    cross join lateral jsonb_each_text(t.stars) e
    where not j.archived and e.key >= to_char(current_date - 14, 'YYYY-MM-DD')), '[]'::jsonb));
end $$;

revoke all on function public.la_job_json(public.la_jobs, boolean) from public, anon, authenticated;
revoke all on function public.la_marketing_feed(text) from public;
grant execute on function public.la_marketing_feed(text) to anon, authenticated;
-- The feed key itself is set once from the SQL editor (not kept in this repo):
--   insert into public.la_feed_keys (name, key_hash) values ('marketing', public.la_hash('<key>'))
--   on conflict (name) do update set key_hash = excluded.key_hash;
