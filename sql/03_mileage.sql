-- Mileage reimbursement (2026-10-19): each person logs their own trips and prints them
-- onto the company Mileage Reimbursement Form. Trips are never deleted (removed = true),
-- so a printed form can always be traced back.

create table if not exists public.la_trips (
  id          uuid primary key,
  super_id    uuid not null references public.la_supers(id) on delete cascade,
  trip_date   date not null,
  start_loc   text not null default '',
  dest        text not null default '',
  job_id      uuid references public.la_jobs(id) on delete set null,
  job_label   text not null default '',   -- "26033 Benjamin Moore TI", kept as printed
  notes       text not null default '',
  odo_start   numeric,
  odo_end     numeric,
  miles       numeric not null default 0 check (miles >= 0),
  rate        numeric not null default 0.70,
  removed     boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists la_trips_super_date_idx on public.la_trips(super_id, trip_date);
alter table public.la_trips enable row level security;
revoke all on public.la_trips from anon, authenticated;

create or replace function public.la_trip_json(t public.la_trips) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'date', t.trip_date, 'from', t.start_loc, 'to', t.dest,
    'jobId', t.job_id, 'job', t.job_label, 'notes', t.notes, 'odoStart', t.odo_start, 'odoEnd', t.odo_end,
    'miles', t.miles, 'rate', t.rate, 'updatedAt', t.updated_at)
$$;

-- Your own trips (newest first).
create or replace function public.la_get_trips(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code);
begin
  return coalesce((select jsonb_agg(public.la_trip_json(t) order by t.trip_date desc, t.created_at desc)
    from public.la_trips t where t.super_id = s.id and not t.removed), '[]'::jsonb);
end $$;

-- Add or update one of your trips. p_trip.removed = true takes it off your list.
create or replace function public.la_save_trip(p_code text, p_trip jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.la_supers := public.la_who(p_code); v_id uuid := (p_trip->>'id')::uuid; v_owner uuid; t public.la_trips;
begin
  select super_id into v_owner from public.la_trips where id = v_id;
  if v_owner is not null and v_owner <> s.id then raise exception 'Not your trip' using errcode = '42501'; end if;
  insert into public.la_trips as x (id, super_id, trip_date, start_loc, dest, job_id, job_label, notes, odo_start, odo_end, miles, rate, removed)
  values (v_id, s.id, (p_trip->>'date')::date, coalesce(p_trip->>'from',''), coalesce(p_trip->>'to',''),
    (select j.id from public.la_jobs j where j.id = nullif(p_trip->>'jobId','')::uuid),
    coalesce(p_trip->>'job',''), coalesce(p_trip->>'notes',''),
    nullif(p_trip->>'odoStart','')::numeric, nullif(p_trip->>'odoEnd','')::numeric,
    greatest(coalesce(nullif(p_trip->>'miles','')::numeric, 0), 0), coalesce(nullif(p_trip->>'rate','')::numeric, 0.70),
    coalesce((p_trip->>'removed')::boolean, false))
  on conflict (id) do update set trip_date = excluded.trip_date, start_loc = excluded.start_loc, dest = excluded.dest,
    job_id = excluded.job_id, job_label = excluded.job_label, notes = excluded.notes, odo_start = excluded.odo_start,
    odo_end = excluded.odo_end, miles = excluded.miles, rate = excluded.rate, removed = excluded.removed, updated_at = now()
  returning * into t;
  return public.la_trip_json(t);
end $$;

revoke all on function public.la_trip_json(public.la_trips) from public, anon, authenticated;
revoke all on function public.la_get_trips(text), public.la_save_trip(text,jsonb) from public;
grant execute on function public.la_get_trips(text), public.la_save_trip(text,jsonb) to anon, authenticated;
