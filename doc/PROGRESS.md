# PROGRESS.md — what exists, how it was built, what is next

Reverse-chronological log. Each entry: **what / how / what it changed / what it
unlocked.** New entries go on top. This file is the project's memory; the
conversation that produced a change is not.

---

## 2026-08-22 — docs reorganized into `doc/`, self-updating rule added

**What:** all six design documents moved to `doc/` (`ARCHITECTURE`, `BLOCKERS`,
`DATA-MODEL`, `GAME-DESIGN`, `RESEARCH`, `SEED-LIST`). `CLAUDE.md` stays at the root
on purpose: Claude Code auto-discovers it there, and it is agent config, not
documentation. All 14 files with cross-references rewritten to `doc/…` paths —
including the SQL header comments inside every migration, which are documentation.
Zero stale references verified by scan.

**Also:** this rule was added to `CLAUDE.md`: every completed task must end with a
documentation update (this file + any doc the task made stale) before it may be
reported done.

**Unlocked:** a stranger (or future us) can find project state in one folder.

---

## 2026-08-22 — schema complete: migrations 0001–0007 applied AND execution-tested

**What:** the entire game database now exists on live project `mxkqivivqultfuattuin`:
extensions (`unaccent`, `fuzzystrmatch` in `extensions`), title normalisation
(`normalise_title`, `strip_season_markers`, `immutable_unaccent`), content tables
(`question_bank`, `question_titles`), game tables (`rooms`, `players`, `rounds`,
`guesses`, partial-unique `one_winner_per_round`), five SECURITY DEFINER functions
(`create_room`, `join_room`, `start_game`, `advance_round`, `grade_guess`) plus
`emit_room_event` and RLS helper `is_room_member`, RLS + grants, realtime publication.

**How:**
- Applied via **Supabase Management API** query endpoint using the PAT in
  `.env.local` (the MCP was unbound — B-19). Runner: `.tmp/apply-sql.ps1`.
  PS 5.1 gotcha worth keeping: its JSON serializer wraps raw multiline strings as
  `{"value": …}`, so bodies are escaped by hand and written UTF-8 **without BOM**.
- Execution-tested, not just applied. Claims were injected per call with
  `set_config('request.jwt.claims', …)`; real role behaviour via
  `set_config('role','authenticated',true)` for RLS. Full matrix passed:
  create/join/start/grade/advance positives; every designed error code
  (`AUTH_REQUIRED`, `BAD_NAME`, `BAD_ROUND_COUNT`, `BAD_DIFFICULTY`,
  `ROOM_NOT_FOUND`, `NOT_IN_LOBBY`, `NAME_TAKEN`, `ALREADY_IN_ROOM`, `NOT_HOST`,
  `NOT_A_MEMBER`, `EMPTY_GUESS`, `EMPTY_NORMALISED` path guarded,
  `GUESS_TOO_LONG`, `ROUND_NOT_ACTIVE` both expired and future, `ALREADY_CORRECT`,
  `INSUFFICIENT_CONTENT`); all four match tiers in isolation (exact / near /
  season_lenient / prefix); winner-takes-all race-loser branch proven (same answer,
  second place → recorded correct at 0 pts); B-23 invariant (`rounds.ends_at =
  rooms.deadline`, stamped behind the not-found gate); start_game idempotency with
  unchanged deadline; RLS member/outsider/denials under real roles.
- Test data deleted afterwards; all six tables verified at zero rows.

**Bugs execution testing caught (both fixed, kept as warnings in
`supabase/migrations/README.md`):**
1. Declared `v_count`, referenced `v_round_count`. PL/pgSQL reports undeclared names
   as `42703 column does not exist` even inside IF expressions — two successive
   "parser limitation" theories were wrong before the typo was found.
2. `select … into v_rec.field` on a never-assigned record → `55000 record not
   assigned yet`; scalar targets used instead.

**Migration registry:** `supabase_migrations.schema_migrations` did not exist (never
CLI-managed). Created in supabase/cli's exact shape and backfilled with all seven
versions, so a future `supabase db push` works without replay conflicts. Documented
in `supabase/migrations/README.md`.

**Changed:** repo gained `supabase/migrations/0001–0007`; live DB has full schema;
registry backfilled.

**Unlocked:** the curation pipeline has somewhere to write.

---

## 2026-08-22 — repo published

**What:** pushed to `github.com/Sayandeep1013/Rein-Bot` (`main`: `b2dc41b`, `e761db4`).
Secrets safe: `.env.local` gitignored and verified untracked; `.tmp/` ignored;
`opencode.json` holds only an env-var placeholder reference.

**How:** plain git over HTTPS with stored credentials.

---

## 2026-08-22 — decisions closed (details live where they belong)

| Decision | Where |
| --- | --- |
| Winner-takes-all scoring; speed bonus 100→0 linear | doc/DATA-MODEL §6.2 note, doc/GAME-DESIGN §6.2 |
| All correct tiers score identically (full credit) | doc/GAME-DESIGN §4.3.1, B-22 |
| Room codes: 4-char Crockford base32, enforced by CHECK | doc/DATA-MODEL §4.1 |
| `[[:alnum:]]` not `\p{L}` (Postgres rejects Perl property escapes) | migration 0002 header |
| `start_game` added; lobby→playing transition (B-24) | doc/DATA-MODEL §6.5 |
| Egress budget = full 5 GB (user read dashboard: 0% used, B-21 closed) | doc/BLOCKERS.md B-21 |
| Seed list = MAL top-50, no hand-picking (user decision) | doc/SEED-LIST.md |

---

## Project state at a glance

- **Live DB:** full game schema on Supabase Free (`mxkqivivqultfuattuin`), zero
  content rows. Registry tracks migrations 1–7.
- **Repo:** design docs + migrations only; no app code yet.
- **Next phase:** curation pipeline — SEED-LIST → AnimeThemes fetch → variant
  filter (nc=true, subbed=false, nsfw=false, CHECK-enforced) → clip transcode →
  Storage upload (`clips/{uuid}.webm`) → `question_bank`/`question_titles` rows.
  Open practical question: ffmpeg is NOT installed locally; portable binary in-repo
  vs GitHub Actions transcoding is the first decision of that phase
  (`doc/ARCHITECTURE.md` §5.5 already sketches Actions owning compute).
