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

## 2026-08-22 - manifest builder, ingest RPC, clips bucket

**Manifest builder.** `tools/pipeline/build-manifest.ps1` turns `doc/SEED-LIST.md` into
`pipeline/manifest.json`: 46 of 50 titles, 130 themes, 5469 MB of source video.

How it works, and what had to be discovered first:

- AnimeThemes slugs are romaji, lowercase, **underscore**-separated
  (`shingeki_no_kyojin`, `hunter_x_hunter`) - not hyphenated. Probed live against
  `https://graphql.animethemes.moe/`.
- `resources { site link }` does not exist on `ExternalResourceConnection`;
  `animeSearch` is not a root field (it is `search(search:, first:, page:)`);
  `AnimeSort` has no `SLUG` member. All three were assumptions that failed, now removed.
- Resolution is three-tier: explicit override, then slug derived from the romaji title,
  then `search` ranked by year + exact title + format + shortest slug. The naive
  "first search hit" is wrong - "Steins;Gate" returns `steinsgate_0` (2018) ahead of
  `steinsgate` (2011). The ladder is what rescued `ao_no_exorcist`, `enen_no_shouboutai`,
  `kimi_no_na_wa`, `fatezero` and six others, because the seed list's "Romaji" column
  sometimes holds an English title.
- Two PowerShell 5.1 traps, both now avoided in-file: `$PSScriptRoot` is empty inside
  `param()` defaults under `-File`, and a literal multiplication-sign character never
  matched because a `.ps1` with no BOM is read as ANSI - so `Hunter x Hunter` and
  `Spy x Family` silently failed. Use `[char]0x00D7`; no non-ASCII literals in `.ps1`.
- UTF-8 was verified rather than assumed: native titles survive as codepoints
  (`36914,25731,12398,24040,20154`). The earlier `?????` was a console *display*
  artefact, not data loss.

Four titles are excluded, each checked rather than accepted: three are films, and
`kuroko_no_basket` has no usable variant - every one is `nc:false` except an ED flagged
`spoiler`. **Credit-free availability, not popularity, is the real content ceiling.**

Per-anime cap of 4 themes: uncapped, `naruto_shippuuden` alone contributes 59 themes and
downloads reach 10.7 GB. Capping gives answer variety and halves the transfer.

Difficulty is `ceil(seed_rank / 10)`, +1 each for ED, sequence >= 3, non-TV format, and
pre-2000, clamped 1-5. Seed rank supplies exactly the recognisability signal
`doc/ARCHITECTURE.md` A8.3 records AnimeThemes as lacking. **Caveat: only 13
difficulty-1 questions result, so a 20-round difficulty-1-only room will correctly fail
`INSUFFICIENT_CONTENT`.** Tuning deferred to playtest (A5), not silently patched.

**Ingest RPC - migration 0008, applied and execution-tested.** `ingest_question(jsonb)`
is the pipeline's only write path.

- An RPC rather than a PostgREST insert because `question_titles.title_norm` must come
  from `normalise_title` - the same function `grade_guess` applies to a guess. Computing
  it in PowerShell or bash would let the two normalisers drift, and answers would stop
  matching for reasons invisible in both codebases.
- It takes a bare `clip_uuid` and derives **both** `id` and `clip_key`
  (`clips/{id}.webm`, per A8.3). An earlier draft accepted `clip_key` from the caller,
  which meant two independent uuids that had to agree forever; the day they disagreed a
  live round would resolve to a missing object. Deriving the key server-side also makes
  a leaky key impossible rather than merely rejected, and fixes the ordering - the
  pipeline uploads the object first and inserts only after the upload succeeds.
- Verified live: `id` equals the supplied uuid; `clip_key` provably equals
  `clips/{id}.webm`; a retried batch returns the same id without duplicating titles; a
  duplicate synonym folds to 4 title rows instead of aborting on the composite key;
  `nc:false` is stopped by the `credit_free_only` CHECK; a title-less payload raises
  `NO_TITLES` rather than shipping an unwinnable question; the AnimeThemes basename is
  rejected by the uuid cast. Test rows deleted - the bank is back to 0.

**`clips` bucket - migration 0009, applied.** A8.3 specified the bucket but no migration
created it, so the pipeline had nowhere to upload. Now: public read (uuid keys make
signed URLs unnecessary, and public caching keeps repeat plays in the separate 5 GB
cached-egress allowance), 5 MB per-object limit, `video/webm` only. No write policy
exists, so anon and authenticated cannot upload; only the service_role key can.

**What this makes possible next:** every input the transcode workflow needs now exists -
a manifest, a bucket, and one idempotent RPC. The workflow itself is the only step left.

---
## Project state at a glance

- **Live DB:** full game schema on Supabase Free (`mxkqivivqultfuattuin`), zero content
  rows. Registry tracks migrations 1-9.
- **Storage:** `clips` bucket live - public read, 5 MB cap, `video/webm` only, no write
  policy (service_role only).
- **Pipeline:** `pipeline/manifest.json` built - 46 anime, 130 themes, 5469 MB source,
  difficulty spread 13/32/28/28/35.
- **Repo:** design docs, migrations, and the manifest builder; no app code yet.
- **Next step:** `.github/workflows/curate.yml` - install ffmpeg (B-12: not preinstalled),
  transcode 20 s clips with `-ss` **before** `-i` so HTTP range-seek avoids pulling the
  full 5469 MB, upload to `clips/{uuid}.webm`, then call `ingest_question`. Needs the
  `SUPABASE_SERVICE_ROLE_KEY` repo secret (user action). Emit thumbnails as an artifact
  to settle B-20, which is still open: whether `nc:false` reliably implies on-screen text
  is unverified, so clips need a visual spot-check before they go live.