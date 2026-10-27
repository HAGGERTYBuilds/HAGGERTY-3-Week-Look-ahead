# Haggerty Look-Ahead

A 3-week look-ahead scheduler for Haggerty superintendents. It runs in Safari on an iPad (Add to Home Screen) and on any computer, and saves to Supabase so the office can see every super's schedule.

It blends the two existing templates:

- **Restoration template (VBA):** tap a day to cycle blank → blue → red → blank. Blue is scheduled work, red is critical (inspection, delivery, deadline). Start and End fill in from the colored days. Job #, Name/address, Claims Manager, Super.
- **Commercial weekly update:** Item / Activity / Responsible, with section rows (Submittals, Third floor, Second floor…).

## What a super can do

| Screen | What it does |
|---|---|
| All jobs | Every job on one screen as a Gantt, a week calendar, or "Plan my day". Built for supers running up to 10 jobs. |
| Job look-ahead | Tap-to-cycle day grid, or paint blue/red by dragging. Tasks can "start after" another task; when one runs long, the tasks after it move out automatically. "Lost day" pushes the rest of the schedule back a workday on one or several jobs. |
| Look-ahead sheets | One branded letter-landscape page per job, printed or saved to PDF in one tap. |
| Send this week's look-aheads | Saves a copy of each job's look-ahead for the week, so the office can see who has sent theirs. |
| Team (admins) | Who has sent this week, when each super last opened the app, **+ Add super**, and **New sign-in link** for a super who lost theirs. |
| Import schedule (admins) | Brings in an existing schedule and assigns it to a super. See below. |

## Each super has their own page

- A super only ever sees, edits and sends the jobs assigned to them. The server enforces this: `la_get_jobs` returns only their jobs and `la_save_job` refuses anyone else's.
- Admins see every job, create, import and delete jobs, and pick the super on each job.
- Each super gets a personal sign-in link (`…/#k=CODE`). Tapping it signs them in; the 8-letter code in it also works on the sign-in screen. Supers can't create or delete jobs, and the job header (Job #, name, PM/CM, super) is read-only for them.

## Divisions

Each super is tagged **Restoration**, **Commercial** or **Both** (Team › Division). A super's division sets the type of every job they run: assign a job to a restoration super and it becomes a restoration job, with no need to read job numbers or names. Supers tagged Both, and admins, set the type per job. Changing a super's division switches their jobs to match.

## Leadership overview (view only)

People added as **Leader** see an Overview page and can open any job in their scope without changing it. The scope is set per person: all jobs, commercial, or restoration. A leader sees the jobs of their type plus every job run by a super in their division. Hugo (VP) sees all jobs, David Booth (general superintendent, commercial) sees commercial, and Eugene (general superintendent, restoration) sees restoration. Admins see the Overview too.

The Overview shows active jobs, how many look-aheads were sent this week, critical items in the next 7 days, and jobs not updated in 7+ days. It also has a commercial vs restoration split (company view only), a workload grid with one row per super showing how many tasks they have running each day, the critical items coming up in the next 2 weeks, and the jobs that still need sending or updating.

## Printing

**For the client** (the default) prints in the layout of the general superintendent's weekly update spreadsheet. The client's logo goes top left, the job name and "WEEKLY UPDATE" sit in the middle, and the Haggerty logo goes top right. The columns are Item No. / Responsible / Activity, with day columns grouped by month, gray weekends and X marks. Section rows are blue, and critical items (inspections, deliveries, deadlines) get an orange fill. **Download Excel** makes the same layout as an .xlsx file, one sheet per job with both logos. **Haggerty internal** is the blue/red sheet.

Each job's client name and logo are set on the job page (Client › Add client logo…). Admins and the job's super can change them. The logo is shrunk on the iPad before upload and saved with `la_set_client`.


Printed sheets default to 3 weeks from this Monday, whatever the screen shows. Only tasks with work in those weeks print (with their section headings), and the print screen lets you change the weeks (1-4) or include every task.

## Importing existing schedules

Admins tap **Import schedule** and pick a file. A preview shows the job name, Job #, type, which super it goes to, and how many tasks were found, before anything is saved.

| File | How it's read |
|---|---|
| Microsoft Project `.xml` (File › Save As › XML) | Summary tasks become section rows (the last two levels, e.g. "Warehouse › Bridge"). Each task fills its workdays; critical tasks and milestones are red. Finish-to-start links become "starts after" where the dates already follow them. |
| Excel / CSV task list | Any sheet with task name, start and finish columns. Optional: outline level or WBS, % complete, critical, resource/responsible, predecessors. |
| Look-ahead spreadsheets | A row of day numbers with B/R/X marks (or blue/red fills) under it, like the restoration template or the JIE DU INN weekly update. All-caps rows with no marks become sections. |

"Leave out tasks that are already finished" (on by default) skips tasks at 100% or that ended before this week. `.mpp` files can't be read in the browser; save them as XML from Project first.

Supers sign in once per iPad. Without a code, "Try it with sample jobs" opens a demo that saves nothing to the server.

## How it works

```
iPad / browser (index.html on GitHub Pages, works offline)
   │  saves each job a moment after an edit; queues edits when there's no signal
   ▼
Supabase "3-week-Lookahead" project: la_* functions → la_jobs, la_tasks, la_submissions, la_supers
```

- Tables are deny-all under RLS. The app only calls `la_*` functions, and each call carries the super's access code. Codes are stored hashed.
- Every save writes a new revision of a job's task list (`la_tasks.rev`), so older versions are kept as history.
- `la_submissions` keeps a snapshot each time a super sends a week's look-ahead.

## Files

| File | What it is |
|---|---|
| `index.html` | The whole app |
| `sw.js`, `manifest.webmanifest`, `icons/` | Offline support and the home-screen icon |
| `sql/01_lookahead_schema.sql` | Tables and functions (already applied to the 3-week-Lookahead project) |
| `sql/03_client_logo.sql` | Client name and logo per job (applied) |
| `sql/02_roles_dashboards.sql` | Roles (super / admin / view-only leader) and scopes for the Overview (applied) |

## Adding supers

In the app: sign in as an admin, open **Team**, tap **+ Add super**, then **Copy link** and text it to the super. The link is shown once; **New sign-in link** makes a fresh one and turns off the old one.

From the Supabase SQL editor (first admin, or resetting a lost code):

```sql
select public.la_bootstrap_super('Full Name', 'NEWCODE1', false);  -- true for admin
```

## Useful queries

```sql
-- Who sent this week's look-aheads
select s.name super, j.name job, max(b.submitted_at) sent
from la_jobs j join la_supers s on s.id = j.super_id
left join la_submissions b on b.job_id = j.id and b.week_start = date_trunc('week', now())::date
where not j.archived group by 1, 2 order by 1, 2;

-- Current tasks for every job
select s.name super, j.name job, t.position, t.name task, t.resource, t.cells
from la_jobs j join la_supers s on s.id = j.super_id
join la_tasks t on t.job_id = j.id and t.rev = j.rev
where not j.archived order by 1, 2, 3;
```
