# supabase/migrations — how this schema reaches the database

**Apply mechanism as of 2026-08-22:** files here are applied through the
[Supabase Management API](https://supabase.com/docs/reference/api/intro) query
endpoint (`POST /v1/projects/{ref}/database/query`) using a personal access token,
NOT through `supabase db push`. The CLI was unavailable when the project was
bootstrapped (B-19 in `doc/BLOCKERS.md`), so the API path became primary.

Consequence, handled deliberately: `supabase_migrations.schema_migrations` did not
exist on a never-CLI-managed project. It has been created **in supabase/cli's exact
table shape** (`version text PK / statements text[] / name text not null`) and
backfilled with all seven migration versions. A future `supabase migration list` or
`supabase db push` therefore works unmodified: existing versions report as applied,
and any NEW file dropped into this directory applies normally.

## Rules for new migrations

1. One concern per file; name them `YYYYMMDDHHMMSS_<topic>.sql`, numbered in order.
2. Every function is `security definer set search_path = ''` with fully qualified
   names (`extensions.*`, `public.*`, `auth.uid()`). A wrong qualification does NOT
   fail at CREATE — it fails at first execution, so **execution-test everything**
   against the live project after applying, don't trust CREATE success.
3. Prefer re-runnability (`create or replace`, `if not exists`, guarded
   `alter publication`) so an apply can be retried without manual cleanup.
4. Content tables have no client grants and RLS enabled with zero policies
   (`20260822000006`); game tables are SELECT-only via membership policies. Any new
   client-visible path goes through a SECURITY DEFINER function, never a grant.

## Bugs caught by execution testing (kept as warnings)

- `v_count` declared but referenced as `v_round_count`: PL/pgSQL surfaces undeclared
  names as `42703 column does not exist` even inside IF expressions — two successive
  "parser limitation" theories were wrong before the typo was found.
- `select .. into v_rec.field` on a never-assigned record raises `55000 record not
  assigned yet`; use scalar targets.
- The round clock is real (20 s): tests that grade a round must start it and grade in
  the SAME call, or they correctly receive `ROUND_NOT_ACTIVE`.

## 0008 / 0009 - curation write path (added 2026-08-22)

- **0008 `ingest_question.sql`** - the pipeline's only write path. Takes a bare
  `clip_uuid` and derives `id` and `clip_key` (`clips/{id}.webm`) from it; computes
  `title_norm` with `normalise_title` so it can never drift from `grade_guess`.
  Idempotent on the uuid. `service_role` only. See doc/DATA-MODEL.md 8.4.
- **0009 `storage_clips.sql`** - creates the `clips` bucket (public read, 5 MB cap,
  `video/webm` only). doc/DATA-MODEL.md 8.3 had specified it but nothing created it.

Both applied and execution-tested against the live project; test rows deleted
afterwards, so `question_bank` is still at 0 rows. Registry tracks 1-9.

**Note on 0009:** it writes to `storage.buckets`, which the Management API can do but
`supabase db reset` against a local stack cannot always reproduce identically - the
bucket row is data, not schema. Treat the migration as the source of truth for the
bucket's settings.