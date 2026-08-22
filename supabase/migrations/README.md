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

## Applying SQL that contains non-ASCII text (read before you do)

Anime titles are frequently CJK, so any migration, seed, or ad-hoc test involving titles
carries an encoding hazard that fails **silently and destructively**.

**Windows PowerShell 5.1 `Get-Content` defaults to the system ANSI codepage, not UTF-8**,
for any file without a BOM. A UTF-8 `.sql` file containing `進撃の巨人` is therefore decoded
as cp1252, turning each 3-byte character into three Latin-1 characters (`é€²æ’ƒã®...`).
Nothing errors. The mangled text inserts happily, and `normalise_title` reduces it to
something like `e2aefaRaao` - a `title_norm` that no player guess can ever match. The game
would simply never accept a Japanese title, and the cause is invisible at every layer:
the migration looks fine, the insert succeeds, the constraint passes.

Rules:

- Read SQL files with an explicit encoding: `Get-Content -Raw -Encoding UTF8`.
- Write request bodies with `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))`.
  UTF-8 **without** BOM: a BOM makes the Management API's Go JSON decoder reject the body.
- After applying anything that touches titles, verify by reading `title_norm` back. Round-
  tripping the text is the only check that actually proves the encoding survived.
- This applies to local tooling only. The `curate` workflow builds its payload with `jq`
  and posts it with `curl` on Linux, which is UTF-8 end to end and not affected.

Found the hard way: a real-payload test of `ingest_question` stored a corrupted native
title. The runner in gitignored `.tmp/` has been fixed, but the hazard is recorded here
because that file is not committed and the next person will write another one.