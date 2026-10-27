-- Client-facing printouts (2026-10-27): each job can carry the client's name and logo.
alter table public.la_jobs add column if not exists client_logo text not null default '';
alter table public.la_jobs add column if not exists client_name text not null default '';
-- la_job_json now also returns 'logo' and 'client' (see the applied migration "lookahead_client_logo").
-- la_set_client(p_code, p_job_id, p_client, p_logo): owner super or admin; logo is a PNG/JPEG data URL under ~300 KB.
