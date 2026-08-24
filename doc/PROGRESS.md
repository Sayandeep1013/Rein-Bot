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
`pipeline/manifest.json`: 46 of 50 titles, 136 themes, 5469 MB of source video.

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
## 2026-08-22 - curate workflow written; three latent data bugs found and fixed

**Manifest now carries the safety flags.** `question_bank` has CHECK constraints
`credit_free_only`, `not_subbed`, `sfw_only`, added in migration 0003 so an unsafe clip
cannot be inserted "even by a buggy ingest run". The manifest did not record
`nc`/`subbed`/`spoiler`/`nsfw` per theme - the builder filtered on them and threw the
evidence away - so the workflow would have had to hardcode `nc: true`. That would leave
those three constraints validating a literal: a tripwire wired to nothing. The builder now
records all four values as the API reported them, and the workflow forwards them, so the
guarantee is auditable from API to row. A guard in the workflow fails the run before
spending encode minutes if any flag is unsafe.

**Theme count was wrong: 130 was really 136.** `Select-Object -First` returns a bare
object, not a one-element array, when exactly one item survives, and PS 5.1 evaluates
`.Count` on a bare `PSCustomObject` as `$null`. The six anime with exactly one theme each
therefore contributed 0 to `theme_count`. The difficulty spread was computed over the
flattened list and always summed to 136, which is what exposed the discrepancy. Fixed by
wrapping the pipeline result in `@()`; the same hazard was fixed in `variants_seen` and in
the `theme_count` sum. The workflow now cross-checks its own flattened count against
`theme_count` and refuses to run if they disagree, so this class of drift cannot return
silently.

**A native title was being corrupted into unmatchable garbage.** Test-ingesting a real
manifest payload produced `title_norm = 'e2aefaRaao'` for 進撃の巨人. Cause was the local
SQL runner: `Get-Content -Raw` with no `-Encoding` makes PS 5.1 decode a BOM-less UTF-8
file as cp1252, so each 3-byte CJK character became three Latin-1 characters. Any Japanese
title would have been stored in a form no player guess could ever match, with no error to
point at it. The runner now reads with `-Encoding UTF8`; re-testing gives
`native=進撃の巨人`. This was a flaw in the test harness only - the workflow builds its
payload with `jq` and posts it with `curl` on Linux, which is UTF-8 end to end. The harness
lives in gitignored `.tmp/`, so the bug class is recorded in
`supabase/migrations/README.md` where it can outlive this session.

**`.github/workflows/curate.yml` written and validated.** `workflow_dispatch` with
`start`/`count`/`dry_run`. Batched because VP9 is slow and a 136-clip job would be
long and all-or-nothing. Every write is idempotent: clip id is `md5(basename)` reformatted
as a uuid, so Storage upserts over the same key and `ingest_question` returns the existing
row, making any re-run a no-op instead of a duplicate. Upload happens before the DB write
so no row can point at bytes that do not exist. The RPC's returned id is compared against
the uploaded uuid, because a mismatch would mean row and object had diverged and the round
would 404 at play time. Per-clip failures are recorded and the loop continues, so one bad
source reports alongside the rest instead of aborting the batch. Thumbnails are a 2x2 tile
sampled every 5 s **from the finished clip**, not the source, so they show the exact frames
a player sees - that is the evidence B-20 needs, and a single frame could miss a brief
title card. `dry_run` defaults to **true** so the first run produces thumbnails and real
byte sizes for inspection without touching the database.

Validated before committing: YAML parses; all 8 item fields and 10 theme fields the `jq`
references exist on all 136 themes; no null `link`; flattened count matches `theme_count`.
Caught during that check that AnimeThemes' `basename` already includes `.webm`, so the
fallback URL would have built `...webm.webm` - fixed, and the thumbnail name now strips the
extension. Test-ingested a real payload against the live DB: uppercase `SPRING`/`TV` are
accepted, `clip_key` is derived correctly, `duration_seconds` and `bytes` are stored as
measured. Test row deleted; bank back to 0 rows / 0 titles.

Also checked whether synonyms are worth ingesting: of 88, **39 add a genuinely new
matchable form** (AoT-style shorthand) and 49 normalise to a title already present. The
RPC already folds duplicates rather than aborting, verified in migration 0008, so all 88
can be passed as-is.

**What this makes possible:** the pipeline is ready to run. A dry-run batch now yields
thumbnails and true clip sizes, which closes B-20 and confirms clips fit under the 5 MB
bucket cap before any row is written.

---
## 2026-08-22 - curate run twice, two real bugs found; frontend moved to GitHub Pages

**Ran the curate workflow for the first time, and it failed twice for two unrelated
reasons.** Both are worth recording because neither was guessable from reading the
script.

**Bug 1 - ffmpeg ate the job list (run `32586028644`, failed after one clip).** The loop
was `while read ... done < jobs.jsonl`, which hands the loop body's stdin to every command
inside it. ffmpeg has an interactive console and reads stdin when it is a pipe, so it
consumed the remaining job lines and fed them to its own command parser - the log shows
`Enter command: <target>|all <time>|-1 <command>` and `Parse error, at least 3 arguments
were expected`. `read` then picked up a half-consumed line and `jq` died with
`Invalid numeric literal at line 1, column 8`, exit 5.

Fixed by reading the job list on **file descriptor 3** (`while IFS= read -r job <&3` /
`done 3< jobs.jsonl`) and adding `-nostdin` to both ffmpeg calls. FD 3 is the actual fix
because it protects the loop from *any* stdin-consuming command, not just ffmpeg;
`-nostdin` is kept as documentation of the specific intent. **The valuable part of that
run: the first clip transcoded correctly - 20 s, 2,046,639 bytes.**

**Bug 2 - AnimeThemes throttling (run `32586647506`, failed in 2m16s).** The stdin fix
worked: all ten jobs were iterated, `ok=0 skipped=5 failed=5`. But items 6-10 all died
with `Server returned 5XX Server Error reply`. The failures were tail-clustered, not
random, after the first five had pulled roughly 200 MB in two minutes.

Checked the obvious hypothesis before acting on it: that AnimeThemes was rejecting a
missing User-Agent. **Locally disproved** - `HEAD` returns 403, but a plain ranged `GET`
returns **206** with no UA, with a browser UA, and with a bot UA alike. So the 5XX is
genuine transient throttling and a UA would not have fixed it. Recorded in the workflow
comments so nobody later mistakes the UA line for the fix.

Fixed with a bounded retry loop (`max_attempts=3`, backoff `attempt*20`s),
`-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 30`, an identifying `UA` sent as
courtesy rather than as a workaround, and the FAIL row now records the attempt count. A
5XX from a free community service is transient by definition; the previous behaviour threw
away half a batch on the first one.

**A third bug found while fixing the second, and this one only existed in dry runs.** The
courtesy `sleep` was at the *bottom* of the loop, on the success path. Every error path
uses `continue`, and the dry-run path exits the iteration early - so **a dry run never
paced at all**, which is exactly the run that got throttled. The pause now sits at the
**top** of the loop, guarded on a `processed` counter so the first item does not pay it,
and is 5 s rather than 1 s. Pacing that is unreachable on the fast path is worse than no
pacing, because it reads as protection that is not there.

**Frontend moved from Vercel Hobby to GitHub Pages** (user directive). Verified Pages'
limits against the official docs rather than assuming: published site and source repo
**1 GB** each, bandwidth **100 GB/month but explicitly a *soft* limit**, deployments time
out at **10 minutes**, throttled requests get **HTTP 429**, and the 10-builds-per-hour
soft limit **does not apply when publishing via a custom Actions workflow** - so
deploy-on-every-push is fine. Over-quota behaviour is a polite email, not a lockout.

The move was nearly free because Vercel was never load-bearing: Vercel *Functions* had
already been rejected as the room server, so Vercel's only job was serving static files.
What it buys is licence terms. **Vercel Hobby forbids all commercial use; Pages forbids
only commercial *transactions* and SaaS**, which a free party game is not. That closes
**B-14** and **B-15** outright - the second because there are no functions left to lock.

Two things worth not rediscovering:

- **Monetisation is still permanently foreclosed**, but the reason changed. It was the
  host's licence; it is now **AnimeThemes' terms**, which forbid commercial use. The ban
  follows the *content*, so changing hosts again will not unlock it. B-14 was re-based
  rather than deleted to make that explicit.
- **Pages has no server-side rewrites.** There is no way to route `/room/ABCD` to
  `index.html`. Room deep links must be **hash-based** (`index.html#ABCD`), and every
  asset path must be relative because the site serves from the subpath
  `https://sayandeep1013.github.io/Rein-Bot/`. This is the one real regression and it is
  now a hard constraint on the client.

Bandwidth is a non-issue on Pages specifically because Pages serves **no video** - clips
come from Supabase Storage, so the site is well under 1 MB. **Supabase egress remains the
only real media budget.**

**Docs corrected in the same pass.** Added a verified `doc/RESEARCH.md` **3.9 GitHub
Pages**, marked 3.8 Vercel superseded rather than deleting it (its analysis of why Vercel
Functions cannot be the room server is still live and still why authority is in Postgres),
and updated the section index. Rewrote B-14 and B-15, and reclassified B-15 from
"permanent constraint" to "closed". Updated `doc/ARCHITECTURE.md`, `doc/GAME-DESIGN.md`
and `README.md`, and swapped the repo topic `vercel` for `github-pages`.

**Rebuilt the ARCHITECTURE component map**, which was doing real damage in two ways: its
box-drawing characters were unreadable mojibake, and it was factually stale - it credited
Supabase **Edge Functions** with ingest, curation and difficulty, none of which is true.
In reality transcode, upload and ingest all run in GitHub Actions, ingest goes through the
`ingest_question()` RPC as `service_role`, difficulty is computed locally by
`build-manifest.ps1`, and **no Edge Function is deployed at all**. Redrawn in pure ASCII
so it cannot be corrupted again, split into curation and gameplay halves, and corrected
from the estimated ~1 MB clip to the **measured ~2 MB**.

**What this makes possible:** the workflow's three known failure modes are fixed and the
next dry run should reach the artifact stage, which is what actually settles B-20. It also
means the deployment target is decided, so client work can start without a hosting
question hanging over it.

**Still unproven, and worth being honest about:** the retry path has never executed, and
the Storage upload and RPC-over-curl paths have *never run at all* - both previous runs
died before reaching them. Only one real clip size is known (2.0 MB, double the earlier
estimate), so 136 clips is now projected at ~272 MB stored rather than ~136 MB.

---
## 2026-08-22 - pipeline runs green, and immediately proves the game does not work

**Third dry run passed: run `32590411786`, `ok=0 skipped=10 failed=0`.** All ten themes
transcoded, **zero retries fired and zero 5XX** - so moving the pause to the top of the
loop and raising it to 5 s fixed the throttling outright, and the retry ladder never had
to be used. Every clip came out at exactly 20 s. That closes the three workflow bugs.

Two things are still unexercised and should not be described as working: **the Storage
upload and the ingest RPC have never run**, because a dry run returns before both. The
retry path has also never actually executed.

**Then the artifact killed the premise.** The whole point of the thumbnails was B-20 -
whether a clip shows the anime's title. It does. **Five of ten clips render the title
logo in Latin script inside the played window**: Attack on Titan OP1 (logo plus romanised
`attack on titan`), Death Note OP1 and OP2 (`DEATH NOTE`), and Fullmetal Alchemist
Brotherhood OP1 and OP2 (logo plus `FULLMETAL ALCHEMIST`). Split by type it is
**5 of 6 openings, 0 of 4 endings**.

**The filter was not defective; the assumption behind it was.** All ten clips passed
`nc: true, subbed: false, overlap: NONE`. `nc` means *creditless*, which strips the
**staff credit overlay** - but a show's title card is **part of the animation**, not an
overlay, so a creditless master keeps it deliberately. No value of any AnimeThemes flag
would have excluded these. `subbed: false` does not help either, since that flag concerns
translation subtitles, not artwork.

The cut is `-ss 5 -t 20`, i.e. source seconds 5-25, and openings conventionally place the
title card in the first ~15 seconds. The window was chosen to skip the cold open; it
happens to frame the logo.

**Being honest about the measurement: it understates the problem.** The tile samples
**4 frames out of about 600**. "None seen" means "no title at these four instants", not
"clean" - a logo held for two seconds between samples is invisible to this check. So the
real leak rate is **at least** 50%. The four clean-looking clips are not cleared.

**Also measured, and worse than assumed: clip size.** Mean **2.09 MB**, min **0.94 MB**,
max **4.70 MB** against the **5 MB** bucket cap - the largest is at **93.9%** of it, with
318 KB of headroom. The encode is `-b:v 0 -crf 36`, constant quality with an *unbounded*
bitrate, so with 126 clips still to go some will exceed the cap and be rejected by
Storage after paying the full download and encode cost. 136 clips now project to about
**284 MB** stored rather than ~136 MB.

**What this makes possible, and what it stops.** The pipeline is mechanically sound and
could ingest all 136 themes right now. It should not. Whatever fixes the spoiler decides
the encode - audio-only, a different window, a different resolution - so ingesting first
means encoding everything twice. Recorded as **B-25** (the spoiler decision) and **B-26**
(the size cap), with B-20 answered and reclassified.

Worth noting for the decision: **audio-only was already written down in `RESEARCH.md` 4.7
as the cheapest egress lever**, at ~160 KB against the measured 2.09 MB, about **13x**
cheaper - roughly 390 games/month instead of 30. This finding promotes it from a cost
optimisation to a correctness fix, and it is the only candidate that removes the leak for
**every** clip rather than most of them. It also changes what the game is, which is why it
is the owner's call and not mine.

---
## Project state at a glance

- **Live DB:** full game schema on Supabase Free (`mxkqivivqultfuattuin`), zero content
  rows. Registry tracks migrations 1-9.
- **Storage:** `clips` bucket live - public read, 5 MB cap, `video/webm` only, no write
  policy (service_role only).
- **Pipeline:** **green.** `curate` dry run `32590411786` returned
  `ok=0 skipped=10 failed=0`, all clips 20 s, no retries, no 5XX. Three bugs fixed along
  the way: ffmpeg stealing stdin, AnimeThemes throttling, and pacing that was unreachable
  on the dry-run path. **Storage upload and the ingest RPC remain unexercised** - a dry run
  returns before both.
- **Hosting:** frontend is **GitHub Pages** - limits verified, B-14 and B-15 closed.
  Deploy target `https://sayandeep1013.github.io/Rein-Bot/`; hash routing required.
- **Repo:** design docs, migrations, manifest builder, curate workflow, README; no app
  code yet.
- **Measured, not estimated:** 20 s at 480p crf36 gives mean **2.09 MB**, max **4.70 MB**
  against a 5 MB cap. 136 clips is about **284 MB** stored; a 4-player 20-round game is
  about **167 MB** of egress uncached, so roughly **30 games/month** against the 5 GB
  budget.
- **BLOCKED, and this is the live question:** **B-25** - at least half of all opening clips
  show the anime's title on screen, so the round gives itself away. `nc: true` cannot fix
  it, because the title card is part of the animation rather than a credit overlay.
  Curation is deliberately paused until the owner decides whether guessing is **aural**
  (audio only while guessing, video on reveal - removes the leak entirely and cuts egress
  ~13x) or **visual** (keep video, and pay for OCR window-picking or manual review).
  **B-26** (bitrate vs the 5 MB cap) is deferred behind it, since audio-only makes it moot.
- **Next step:** get that decision, then re-encode accordingly and ingest all 136. After
  that, the single-file HTML test page.

---

## 2026-08-23 — Still-frame content model (migration 0010) applied and verified

### What was done

Replaced the one-video-per-question content model with a five-object model (audio, 2—3
stills, poster), added a per-room audio toggle, fixed a settings-persistence bug, and closed
a content-leak hole found while fixing it. Migration
`supabase/migrations/20260823000010_still_assets.sql` (~605 lines) is **applied live** to
`mxkqivivqultfuattuin`.

### How

**Decided the format from measurement, not preference.** Sampling the 10 dry-run thumbnail
tiles showed 5 of 10 clips display the anime's title in Latin script while satisfying
`nc:true, subbed:false, overlap:NONE` (B-20). Split 5/6 openings, 0/4 endings — the title
card is an opening convention, so a credits-related flag was never going to catch it. Since
a video window is contiguous, a title card at 0:12 cannot be excluded without losing the
window; independently chosen stills can be vetted one at a time. The spoiling frame then
becomes the reveal poster instead of being thrown away.

**Built the frame-quality rule from data.** Measured mean luma, luma std, mean absolute
gradient and JPEG-bytes-at-q82 over 40 real frames (10 tiles × 2×2 quadrants, PIL + numpy),
using two known-dead frames as ground truth. A brightness/`blackframe` filter would have been
actively wrong: the worst frame of the 40 (flat grey) has luma 180.0 and ranks 39/40 on
brightness. JPEG-bytes-versus-**per-theme** median ranks both dead frames 1st and 2nd; the
median must be per-theme because one theme's frames all sit below the global median. Written
up as `doc/RESEARCH.md` §4.10.

**Wrote the migration defensively.** A guard DO-block refuses to run if `question_bank` or
the bucket is non-empty, turning "ran this too late" into a loud failure instead of silent
divergence. Bucket limits were **tightened** rather than widened: `video/webm` removed
outright, 5 MB → 512 KB. Renamed `clips` → `media` while empty, the only moment that is free.

**Two failures worth recording.** First apply died on
`delete from storage.buckets where id='clips'` — `storage.protect_delete()` raises `42501`
on any direct delete; because Management API multi-statement queries run as one transaction,
the entire migration rolled back. Replaced with a comment; second apply clean. Separately,
two Oracle consultations returned empty after 7m43s and 2m10s, bringing failed specialist
invocations to 4 across 2 agent types — the asset-key design was decided directly.

### What it changed in the live project

- `question_bank`: `+asset_slug uuid unique`, `+still_count smallint check 2..3`,
  `duration_seconds` → `audio_seconds`, `bytes` → `bytes_total`, `clip_key` **dropped**.
- `rounds.clip_key` **dropped**; `rooms.audio_enabled boolean not null default true` added.
- New `question_asset_keys` (sole definition of the Storage layout) and `get_current_round`
  (sole delivery path for asset keys). `create_room` and `ingest_question` at v2.
- Storage: `media` bucket, public read, `{audio/webm, image/jpeg}`, 512 KB cap.
- Content rows: still **0** — nothing to migrate, by design.

### Security fix included

`rounds.clip_key` handed every room member the asset keys of all *future* rounds:
`rounds_select_for_members` gates on membership alone and `create_room` pre-inserts all
rounds, so round 1 exposed the whole game from a public bucket. Fixed by removing the data,
not guarding it. Keys now derive from `asset_slug`, which lives only on the ungranted
`question_bank` — not from `id`, because `rounds.question_id` is client-readable and
id-derived keys would rebuild the same leak. Rejected an `ordinal <= current_round` RLS
predicate (permanently correctness-critical) and the ROUND_START broadcast (public channel,
~1M room-code keyspace). See B-27a.

### Verified

Schema verification confirmed every column, constraint, function signature, bucket and
policy, and that `clip_key` is absent from **every** table. Behavioural test then proved the
parts schema cannot: `round_count=5` persisted with exactly 5 rounds (B-27 dead),
`audio_enabled=false` persisted, `get_current_round` returned ordinal 1 with 3 stills and
**neither poster nor audio**, and zero residue after rollback.

### What became possible next

The write path's contract is now fixed and proven, so `.github/workflows/curate.yml` can be
rewritten against a stable target: one source download → audio + ~60 candidate frames +
poster, per-theme-median detail filter, OCR spoiler filter, five uploads, `ingest_question`
v2. Egress arithmetic is now known for both modes: ~120 KB/round/player stills-only
(~530 games/month inside 5 GB) versus ~280 KB with audio (~220 games/month); 136 questions
≈ 38 MB stored.

### Still unproven

The Storage upload path and RPC-over-curl have never executed. **B-28** is the real risk:
OCR against stylised anime logos is now the only thing protecting the answer, it cannot be
tested locally (no `tesseract`/`ffmpeg`/ImageMagick), and a green CI run does not prove it
— the artifact must be inspected for false negatives by eye.

### Docs updated in this pass

`doc/DATA-MODEL.md` 736 → 878 lines (§3.1, §4.1, §4.3, §6.3, new §6.6, §8.3, §8.4, §9);
`doc/GAME-DESIGN.md` §1 row 1 and §3; `doc/RESEARCH.md` §4.10 (→ 1275 lines);
`doc/BLOCKERS.md` resolution log (B-25 implemented, B-27 + B-27a resolved, B-28 opened).

---

## 2026-08-23 (later) - Pipeline spec written down, session handoff created

### What was done

Converted `doc/GAME-DESIGN.md` section 5.2 from the old video steps into an implementable
frame-selection spec, and wrote `doc/HANDOFF.md` so the next session starts with full
context instead of rediscovering it.

### How

Section 5.2's step 4 used to read "spot-check a frame visually". That was replaced rather
than amended: it would never have scaled to 136 themes, and B-20 proved that sampling four
frames out of ~600 would not have caught the title cards anyway. In its place are three
filters with measured thresholds - detail (JPEG bytes below 45% of the per-theme median),
text (`tesseract --psm 11`, `eng+jpn`, tuned to over-reject because a false positive costs
one frame of sixty while a false negative ships the answer), and spread (best survivor
from each third). Each carries the reason it was chosen over the alternative, so the
thresholds are not free-floating constants.

The handoff doc was written in plain ASCII on purpose. The rest of `doc/` uses em-dash
U+2014 and similar characters, which repeatedly broke exact-string matching during this
batch and forced every edit through Python scripts with assertions; the one doc most likely
to be edited by a fresh agent should not carry that trap.

### What it changed

- `doc/GAME-DESIGN.md` 823 -> 887 lines. Section 5.2 now has subsections 5.2.1 (detail),
  5.2.2 (text/OCR) and 5.2.3 (spread). Section 5.3's column sketch matches the live
  schema, and explains why `asset_slug` exists separately from `id`.
- `doc/HANDOFF.md` added: hard rules, environment hazards, command recipes, settled
  decisions, the rejected-approaches list, ordered next steps, egress arithmetic, and an
  honest verified-vs-unverified split.

### What became possible next

The `curate.yml` rewrite can now be implemented from section 5.2 directly rather than
re-derived from measurements that existed only in conversation. That was the point: the
frame-quality numbers came from a one-off 40-frame experiment, and had they stayed in chat
history they would have been lost and probably re-run.

### Known doc debt, recorded rather than hidden

`doc/GAME-DESIGN.md` sections 1.1, 2 and 2.1.1 still describe video, and the section 5.1
blockquote still refers to re-encoding to ~1 MB at a step that no longer exists.
`doc/ARCHITECTURE.md` asset flow and `doc/RESEARCH.md` section 4.7 still need the two-mode
egress numbers (~120 KB/round stills-only = ~530 games/month; ~280 KB with audio = ~220).
These are listed in `doc/HANDOFF.md` section 8 as leftover debt rather than left to be
tripped over.

---

## 2026-08-23 — Independent asset keys, a measured OCR rule, and a second OCR engine

Three things, in dependency order: a key-derivation hole found while reading 0010 and
closed; the OCR text filter re-tuned on 647 real frames after the original rule was
disproven; a second OCR engine added because the remaining leaks turned out to be blindness
rather than mis-tuning.

### What was done, and how

**1. Closed the derivable-poster hole (migration `20260823000011`).**

0010 had correctly stopped keys deriving from `question_bank.id`, rooting all five objects
in one `asset_slug` instead. Reading it back showed that fix had a narrower hole inside it:
`posters/{slug}.jpg` is one path segment from the `stills/{slug}-1.jpg` a player is
legitimately sent, and the poster is deliberately the title card — i.e. the answer to the
question being asked.

Before fixing it, the actual read surface was **measured** rather than assumed
(`.tmp/storage-probe.ps1`): with the `"media is publicly readable"` policy dropped, `list`
returned 0 objects but `GET` by key still returned 200. **On a `public = true` bucket, reads
by key bypass RLS entirely** — the policy had only ever granted *enumeration*. So no policy
could ever have restricted a known key, and key unguessability is the only control.

The migration therefore gives each asset class its own root (`asset_slug` for stills,
`poster_slug`, `audio_slug`), each `not null unique`, plus a `question_bank_slugs_distinct`
CHECK because the realistic ingest bug is one uuid reused for all three. The 2-argument
`question_asset_keys` was **dropped, not overloaded** — an overload leaves the hole one call
site away. `ingest_question` became v3 with `MISSING_POSTER_SLUG`, `MISSING_AUDIO_SLUG`,
`SLUGS_NOT_DISTINCT`. The storage policy was dropped outright rather than narrowed, per the
measurement. `get_current_round`'s anon grant was revoked **by name**, because revoking from
`PUBLIC` does not remove a grant to a named role and `create or replace` does not reset an
ACL.

**2. Re-tuned the OCR filter on measured data (run `32605150598`, 12 themes, 647 frames).**

The existing rule counted OCR characters per frame. That is disproven: junk sums across a
frame (p90 = 9, max 34) while a real title card measured 43 characters, so the two
distributions **fully overlap**. It failed in both directions — an earlier run skipped 8 of
10 themes at `chars_70 >= 4` while still not being safe.

Dumping per-frame telemetry (`ocr_dump=true`) and analysing all 647 candidates showed the
discriminator is the **longest single word**, not the total: at confidence >= 70 junk peaks
at p50 = 2 / p95 = 3, and every one of the 18 frames scoring `longest_70 >= 5` was genuine
text (`ASSASSINATION(92)`, `BLACK(94) CLOVER(96)`). The rule is now `longest_word >= 5 @
conf >= 70`, with the floor guarded at 2 in the workflow because 1 would reject nearly every
frame.

**3. Added `rapidocr-onnxruntime` as a second engine, because tuning was exhausted.**

All 36 shipped stills were then viewed by eye rather than trusting a green run. 3 of 36 (8%)
still leak text — "KOROSENSEI teacher.", 出席番号 plus character names, credit names — and
tesseract scored those frames `longest_70` of 1-2. It did not *read* them, so **no threshold
could have caught them**. That is a blindness problem, and the only fix is a second reader.

Pinned `<2` deliberately: 2.x renamed itself to `rapidocr` and downloads weights on first
use, which would put a network fetch inside the 60-frame loop. The install step constructs
the engine once to prove the 1.x wheel bundles its weights — a 30-second check instead of
discovering it 20 minutes into a run. A missing wheel is **fatal**, not a silent
tesseract-only downgrade, since that would invisibly restore the exact blindness the pass
exists to remove; `RAPIDOCR_ENABLE=false` is the explicit opt-out. `jpn_vert` was dropped in
the same pass: across all 647 frames it produced no high-confidence word while costing a
pass per frame.

### What it changed in the live project

- **Live database:** migration 0011 applied (twice, to confirm idempotence). `question_bank`
  carries three key roots and a distinctness CHECK; `question_asset_keys` is 4-argument;
  `ingest_question` is v3; `get_current_round` is no longer callable by `anon`; the `media`
  read policy is gone.
- **`tools/pipeline/curate_theme.py`:** longest-word rule, `eng+jpn`, three slugs minted per
  question, new `rapid_words` pass with a one-element engine cache, `RAPIDOCR_ENABLE` knob,
  and an OCR dump that now records `longest_at_min_conf` and a `culprit` column
  (`engine:WORD(conf)`) so a future run can tell *which* engine earned its runtime.
- **`.github/workflows/curate.yml`:** input renamed `ocr_min_chars` -> `ocr_min_word`
  (default 5), `ocr_min_conf` default 0 -> 70, installs and probes the pinned wheel, new
  guard rejecting `ocr_min_word < 2`.
- Committed as `b830945` and pushed (3 files, 649 insertions).

### Verified, and how

- Migration applied twice with identical result; ACLs re-audited afterwards
  (`get_current_round`: anon `-`, authenticated `YES`); all three new guards plus a positive
  round-trip exercised against the live database in SQL; `ON DELETE CASCADE` confirmed.
- Storage read surface probed empirically before and after the policy drop.
- `rapid_words` unit-tested against a **faked** engine injected into `sys.modules`
  (11 checks, 0 failures): tuple *and* bare-list returns, `None`
  detections, score scaling, line-to-word splitting, malformed rows, single-construction
  caching, the disable flag, and the missing-wheel error path. This is how the engine
  contract gets tested at all without installing the wheel locally. *The suite started in
  `.tmp/` and was later promoted to `tools/pipeline/test_curate_contract.py`; see the next
  entry.*
- Workflow YAML re-parsed, every input reference cross-checked against the declared inputs,
  and all 5 `run` blocks extracted and `bash -n`'d.
- The pinned wheel genuinely bundles its weights: the CI install step constructed
  `RapidOCR()` successfully.

### Still unproven — deliberately stated

Whether rapidocr actually reads the three known-bad frames. That is the whole point of the
change and it has never run against a real image. Verification run `32617226964` is in
flight. Also still never executed even once: Storage upload, `ingest_question` over **HTTP**
(SQL only so far), the retry ladder, and any real egress measurement.

> **Resolved by the next entry.** Run `32617226964` completed: rapidocr earned its place
> (14/14 new catches) but did **not** close the leak — 5 of the 6 known-bad frames are still
> classified `CLEAN`, and 2 readable stills shipped. See
> *2026-08-23 (later) — OCR geometry telemetry* below. The remaining never-executed items
> (Storage upload, HTTP ingest, retry ladder, egress) are still never-executed.

### What became possible next

The OCR filter can now be argued about with numbers instead of intuition — the 647-frame
distribution is written down in `doc/GAME-DESIGN.md` §5.2.2, so the next person cannot
re-propose character-count gating without first contradicting measured data. And because the
three key roots are independent, `get_current_round` withholding the poster key is now an
*effective* control rather than a statement of intent, which is what stills-only rooms rest
on.

### Docs updated in this pass

- `doc/DATA-MODEL.md` — §3.1 rewritten for three roots, schema block, §7.4 key table (now
  with **measured** byte sizes from run `32605150598`, replacing estimates), `get_current_round`
  withholding rationale, `ingest_question` v3 and the dropped-overload reasoning.
- `doc/GAME-DESIGN.md` — §5.2.2 replaced with the measured thresholds, the disproven
  char-count rule, the 8% residual table and the two-engine design; §5.3 column list and key
  derivation; step 11 of §5.2.
- `doc/BLOCKERS.md` — B-28 extended with the measurement, the counterexample table and an
  explicit close condition; **B-29 opened and closed** in one entry; summary table re-scored
  (B-27 closed, B-28 is now the riskiest open item).
- `doc/HANDOFF.md` — schema columns, the Storage key block, rule 1 rewritten, the
  `ingest_question` v3 payload and failure list, settled-decisions row.

---

## 2026-08-23 (later) — OCR geometry telemetry: the leak is structural, so measure a new axis

### What was done

Run `32617226964` came back and settled the rapidocr question in both directions. The second
engine works — rejections rose to 46 and **all 14 newly-rejected frames were credited to
`rapid`**, several of them "Angel Beats!" logo frames tesseract could not read at all — and it
is free, finishing in 18m59s against the tesseract-only run's 21m6s. But it did not fix the
leak. Of the six known-bad frames, exactly one flipped to TEXTY; the other five are still
`CLEAN`. Eyeballing all 36 newly-shipped stills found **2 leaks, both introduced by the
reshuffle** rather than caught by the filter.

The important finding is *why* tuning cannot fix it. Three frames were pulled out of the dump
side by side, and no scalar the pipeline records separates them — on `longest_70`, `chars_70`
and `words`, the **clean** frame ranks highest of the three. Two distinct structural blind
spots explain it: a Japanese name is 1–3 glyphs so it can never reach a 5-character token, and
kinetic Latin title typography is segmented glyph-by-glyph so its longest token is 2 characters
*at a confidence floor of zero*. The Latin threshold also has no downward headroom — dropping
`OCR_MIN_WORD` to 4 would reject a clean cityscape frame (its 4-character token is `ーーーー`,
i.e. window mullions) while still missing both leaks.

So instead of guessing another threshold and burning another 20 CI minutes, this pass
instrumented the axis that is *not* yet recorded: **glyph size**.

### How it was done

Both OCR functions were widened from returning `words` to returning `(words, tokens)`.
`ocr_frame` now builds a `geoms` list in parallel with `passes` and returns both, and
`text_filter` writes a second per-theme artifact, `tokens-<stem>.tsv`, with one row per token
per pass across 14 columns: `ts verdict pass conf h_px hrot_px w_px top_px img_w img_h
line_ntok len text raw`. **No threshold moved and no verdict logic changed.**

The mechanism choices that matter, all of them things that would have quietly corrupted the
calibration if done the obvious way:

- Geometry is recorded as **raw pixels with the image dimensions alongside**, never as
  pre-divided fractions, so normalisation — including undoing the 2× upscale pass — stays an
  offline decision.
- Image dimensions come from **tesseract's own level-1 page row**, not PIL and not ~60
  `ffprobe` calls per theme, and are backfilled onto every token *after* the parse loop,
  because the page row is only conventionally first. rapidocr reports no image size, so it
  writes `0` sentinels that `ocr_frame` fills from the **`orig`** pass — never `up2x`, whose
  page box is 2× and would have silently halved every rapid fraction.
- rapidocr gets **two heights**, axis-aligned and rotation-aware (mean of the side edges),
  because they disagree on rotated text — 70 px vs 22 px in the tests — and the artifact should
  pick, not me.
- The dump is opened `encoding="ascii"` behind an `_ascii()` escaper that doubles backslashes
  first, so escaping is reversible, a non-ASCII leak fails loudly, and the cp1252 console
  cannot corrupt CJK. `len` counts glyphs before escaping.
- Geometry degrades to zeros and never raises. The text half of the return value *is* the
  safety filter and has to survive a malformed box.

The safety argument is a **mirror invariance**, asserted on every one of the 48 checks in
`tools/pipeline/test_curate_contract.py`: `[(t["conf"], t["text"]) for t in tokens] == words`. If that ever drifts,
the geometry rows describe different text than the verdict came from — i.e. the calibration
would be against a lie. Test coverage was extended from 11 checks to 48: rapidocr quad geometry
including a rotated and a malformed box, `ocr_words` TSV parsing driven by a faked `run()`
(page row first, page row *last*, no page row, `conf = -1`, non-numeric box, non-zero exit),
the `_ascii` escaper, and an end-to-end run of `text_filter` with a stubbed `ocr_frame` that
reads the written file back and asserts the header is 14 columns and every row matches its
width.

Writing those tests found a real bug: the `RAPIDOCR_ENABLE=false` opt-out still returned a bare
`[]` after the widening, which would have broken the documented fallback ladder the first time
anyone reached for it.

**The suite was also promoted out of scratch.** It had been living in `.tmp/`, which is
gitignored — so `doc/BLOCKERS.md` was citing, as the safety argument for a pipeline change,
a file that would not exist in a fresh clone. It is now
`tools/pipeline/test_curate_contract.py`, tracked, runnable as
`python tools/pipeline/test_curate_contract.py` with no arguments and no dependencies (it fakes
both `rapidocr_onnxruntime` and `run()`, so it passes on a machine with neither the wheel nor
tesseract). `ROOT` moved from `parent.parent` to `parents[2]` for the new depth, and the temp
directory is now created if missing, since a fresh clone has no `.tmp/`.

### What it changed in the live project

Nothing in the database or in Storage — this pass touched the pipeline and the docs only, and
deliberately produced **no behaviour change**. `tools/pipeline/curate_theme.py` compiles and
its contract tests pass 48/48. The repo gained one tracked file,
`tools/pipeline/test_curate_contract.py` (previously untracked scratch). The measured
per-question size was corrected across the docs
from ~42 MB to **45.6 MB** for 134 questions (mean `bytes_total` 356,637 B from run
`32617226964`); the rise is not drift but a consequence of `ocr_min_conf` 0 → 70 changing which
frames ship. `doc/ARCHITECTURE.md` was found to still describe a **`clips` bucket of 2 MB VP9
videos** — an entire design generation stale — and was corrected to the `media` bucket with
three opaque roots and five objects per question, including the Storage ceiling, which is
~3,000 questions rather than the ~1,000 previously stated. `doc/DATA-MODEL.md` §8.3 had the
same problem in a subtler form: a newer `media` block described the live bucket correctly, then
an older migration-0009 note *below it* still asserted `file_size_limit = 5242880` and
`allowed_mime_types = {video/webm}`, so a reader hit the wrong facts last. That note is now
explicitly marked superseded and states the live values (512 KB, `{audio/webm, image/jpeg}`)
alongside the historical ones.

### What became possible next

The next threshold can be chosen **offline from the artifact**. Because the metric path is
byte-identical, the next run must ship exactly the same 36 stills as run `32617226964` —
checkable with `.tmp/cmp-ship.py` — which promotes those already-eyeballed 36 (2 leaks, 34
clean) into labelled ground truth. A candidate height rule can then be scored against real
data with three hard acceptance criteria (rejects both leaks, keeps `AoNoExorcist-OP1`
ts=37.6, holds yield at 3 stills per theme) before a single behaviour-changing CI minute is
spent.

### Still unproven

The height hypothesis itself. Nothing yet demonstrates that glyph height separates the
counterexamples — that is exactly what the next run's artifact is for. Normalising height
across the `up2x` pass and across rapidocr's line-level boxes remains the part most likely to
go wrong. And still never executed even once: Storage upload, `ingest_question` over **HTTP**,
the retry ladder, and any real egress measurement.

### Docs updated in this pass

- `doc/BLOCKERS.md` — B-28 gains an *Instrumented* section: the 14-column schema, each
  mechanism decision with its failure mode, the mirror-invariance safety argument, the bug the
  tests caught, and an explicit order of operations. B-28 **stays OPEN** — 2 leaks shipped.
- `doc/GAME-DESIGN.md` — §5.2.2's "3 of 36, cause unverified" replaced with the measured
  2-of-36 outcome, the coincidence warning, both blind spots, the three-frame counterexample
  table, the no-downward-headroom finding, and the glyph-size hypothesis; §3's "riskiest
  unverified premise" sharpened to *measured insufficient*; a dangling §5.2.4 reference fixed.
- `doc/DATA-MODEL.md` — §9 byte table re-sourced to run `32617226964` with the 45.6 MB
  arithmetic and why it moved; §4.3 `rounds` key-derivation note corrected to name all three
  roots; §8.3's migration-0009 paragraph marked superseded and given the live bucket settings.
- `doc/ARCHITECTURE.md` — both pipeline diagrams, the stack table, the Edge Function list, the
  Storage ceiling and the no-cache rationale corrected from video clips to the five-object
  still/audio model.

## 2026-08-23 (later still) — The height hypothesis was wrong, and the labels were wrong first

The previous entry ended by naming glyph height as the next axis to calibrate and the run
`32620787219` artifact as the data to calibrate it on. Both halves of that plan were executed.
**The hypothesis is falsified, and the reason it looked plausible for two sessions is that three
of the five suspect frames were mislabelled.**

### How it was done

An offline calibrator (`.tmp/tokens.py`, ~727 lines) reads the OCR dumps straight out of the
downloaded artifact, so every experiment costs seconds instead of a 16-minute CI run. Run
`32620787219` was first proved **bit-identical** to run `32617226964` in its shipped set, which
promoted those 36 already-eyeballed stills into trustworthy ground truth. The five additional
frames carried over from run 2 were treated the same way — and that is where the work started
paying off.

**The label audit came first, and it overturned the premise.** Re-opening all five run-2 frames
with `read` rather than trusting the earlier notes: `AngelBeats-OP1` ts=39.1 and
`AnsatsuKyoushitsu-OP1` ts=79.5 are **real leaks**, but `BlackClover-OP1` ts=46.5,
`AnsatsuKyoushitsu-OP1` ts=43.6 and `AnsatsuKyoushitsu-ED1` ts=65.2 are **clean**. The 46.5 frame
had been written up as an *uncatchable* leak and was about to be conceded as a permanent hole in
any rule; it simply has no text in it. Labels are now 2 confirmed leaks, 2 confirmed pool leaks
and 37 clean, each with its verdict and reasoning inline in the harness so the next session
cannot silently inherit a bad one.

**Then height died.** Sweeping every candidate threshold on `h_px`, `hrot_px`, `w_px` and
`top_px`, at every confidence floor, returned `NOT SEPARABLE` in all cases. The mechanism is
concrete: the tallest single token across all 16,038 is **0.6865 of frame height at confidence
79.7 — a hallucinated `と` on a character's hair curve** in ts=43.6, one of the frames the audit
had just reclassified as clean. From the other direction, the ts=79.5 leak scores **0.0000 on
every confidence-weighted measure**, because its five tokens top out at confidence 58.6. A
stylised logo is confidently *misread*, not confidently read. No scalar built on one token can
straddle those two facts.

**Two structural fixes made the data usable.** First, detections were being double-counted across
OCR passes: ts=43.6's hair curve is found by both the original and 2× pass (`|Δh|/h = 0.026`,
`Δtop = 0`), and counting it twice gave that clean frame the **highest coherence score of all 41
frames, 0.9918**. A cross-pass `dedupe()` — normalise each box by its own row's image
dimensions, never merge two boxes from the same pass, keep the highest-confidence member — drops
it to **0.0000**. Second, an Oracle suggestion to relax the minimum cluster size to 2 for large
type was **rejected by measurement**: it readmitted exactly that hair-curve pair and made the
clean frame top-scoring again. It was deleted with an inline record of why, so it does not get
re-proposed.

**The rule that survived is a union of two features, because each fails alone.** Coherence
(median box height × √cluster size × median confidence weight, with a baseline-tightness bonus)
catches title text the engine genuinely read, including short CJK names — and is blind to logos.
A large-box count (regions above 0.28 of frame height, deliberately **without a confidence
floor**) catches logos the engine misread — and is blind to small confident text. Swept
individually, both returned `NOT SEPARABLE`; the harness **refused to emit a threshold** rather
than picking a plausible-looking one. Combined as `max(coh / 0.21, bigbox / 3) >= 1.0` they
separate cleanly.

**The large-box threshold is 3 rather than 4 for a mechanical reason, not for margin.** The
ts=79.5 leak does have four large boxes — but one is a degenerate full-frame `1.0 × 1.0`
detection at confidence 28.1, a segmentation artifact rather than a glyph. Its real boxes number
three (0.876 / 0.568 / 0.378). A threshold of 4 catches that confirmed leak **only by counting the
artifact**, and would stop catching it after any engine or upscale change. The price of 3 over 4
is two extra clean frames lost, against a worst-theme yield of 33 candidates for a floor of 3.
Both thresholds were fully priced before choosing (`.tmp/union3.txt`, `.tmp/union4.txt`).

**Two bugs in the harness itself were caught by distrusting a clean-looking result.** The
per-frame audit printed `0.0000` for all 41 frames: labels hold float timestamps while the frame
index is keyed `"%.1f"`, so a `.get(key, [])` default was scoring every frame against an empty
token list. A missing frame now raises `RuntimeError("labels are stale")` instead of rendering as
*clean* — a lookup miss must never look like a pass. Separately, a cost-estimation script crashed
on `MIN_CONF`, which is a `main()` local rather than a module constant.

**Finally, the real cost of the rule was measured rather than assumed.** The rule promotes 10
never-eyeballed frames into the ship set, which read as 10 frames of CI debt. A script that
cross-references those picks against the JPEGs already sitting in earlier artifacts found **3 of
them were already on disk**. All three were opened and are **clean**: a sunset group shot, a
night cityscape with a grand piano — which incidentally explains that theme's hallucinated
`NN` / `SZ` / `NIN` tokens as grids of city lights — and Kurikara's glowing blade against a night
sky, glow only, no legible text. Real remaining debt is **7 frames, not 10**.

Measured result of the chosen configuration: **4 of 4 known-bad frames caught, 0 missed, 0
known-bad frames promoted into the ship set, 0 themes short of 3 stills**, at a cost of 5 clean
frames.

### What it changed in the live project

**Nothing executable.** No migration, no Storage object, no database row, and no change to
`tools/pipeline/curate_theme.py` — the shipping rule is still the old one, and runs 3 and 4 still
ship 2 readable stills out of 36. This pass produced a *decision* and the evidence for it. The
repo gained documentation only; the calibrator and its output live in untracked `.tmp/`.
**B-28 stays OPEN**, and the triage index was corrected to say so accurately: it previously read
"measured insufficient, geometry now instrumented so the next rule can be calibrated", which was
true a session ago and is now understated — the rule is chosen, it is simply not shipped.

### What became possible next

Implementation is now mechanical rather than exploratory. The rule has a written form, a
measured price, a refusal guard that fires when a leak survives, and a simulator that predicts
the exact 36 frames the next run will ship. That prediction is the acceptance test: the CI run
that implements this rule must ship precisely the simulated set, checkable with `.tmp/cmp-sim.py`,
which has been validated against both a positive and a negative control. The remaining sequence
is: risk-rank the spread selector, implement the union in `text_filter`, extend the contract
suite, one CI run with per-frame uploads to clear the 7 unverified frames, then the 134-theme
batch.

### Still unproven

The 7 promoted frames — none can be inspected offline, because the union rule is strictly
stricter than the shipped rule, so every newly promoted frame already passed the old filter and
was merely not selected; no JPEG of it exists anywhere. The risk-ranked selector is specified but
not built, and until it is, removing a leak can still promote the next-most-suspicious frame in
the same span. And still never executed even once: Storage upload, `ingest_question` over
**HTTP**, the retry ladder, the frontend, and any real egress measurement.

### Docs updated in this pass

- `doc/BLOCKERS.md` — B-28 gains a *Calibrated* section with 11 findings: the label-audit table,
  the falsified height axis with the hair-curve token named, the cross-pass dedupe and its
  before/after numbers, the two-feature comparison, why the box count carries no confidence
  floor, the chosen rule, the degenerate-box reasoning for 3-not-4, the measured cost,
  non-separability reframed as a costing question rather than a tuning bug, the silent-zero bug,
  and the 3-verified / 7-pending frame list. The old *Closes when* and *Order of operations*
  blocks are struck through and labelled superseded rather than deleted. The triage index prose
  was rewritten in place, since it is a current-state summary rather than a trail.
- `doc/GAME-DESIGN.md` — §5.2.2's glyph-size hypothesis replaced with the falsification, the
  label correction, and the shipped rule including why the two features are complementary and why
  the count has no confidence floor; §5.2.3 corrected — it claimed the selector takes the
  "highest-detail survivor" when it actually takes the largest JPEG — and the pending
  risk-ranked change recorded there; §3's leak note updated to say a replacement exists but is
  not implemented.

---

## 2026-08-23 (later still) — The calibrated OCR rule becomes the shipped OCR rule, and parity proves it

### What was done

The two-feature union rule and a new frame selector were implemented in
`tools/pipeline/curate_theme.py`. A local parity gate then proved the ported arithmetic is
bit-identical to the calibration harness on all 621 dumped frames. Two candidate mechanisms —
risk-ranked selection and spatial dilation — were priced and rejected on measurements. The contract
suite was extended to cover the new paths and is green.

### How it was done

**Four edits, deliberately separated by concern.** The four operational knobs (`OCR_COH_T` 0.21,
`OCR_BIG_T` 3, `OCR_BIG_MIN_H` 0.28, `OCR_QUIET_T` 0.85) went into the top constants block as
env-overridable values; the six structural constants of the clustering maths stayed next to the
functions that use them, because they are not operator dials and exposing them would invite
un-calibrated tuning. `text_filter` now computes a risk score for every candidate, rejects on
`max(coherence/0.21, large_boxes/3) >= 1.0`, and reports `ocr_union_only` per theme so the new rule's
independent contribution is visible in `results.jsonl` rather than inferred.

**The port was done by renaming the data, not by rewriting the code.** A small adapter reshapes the
pipeline's token dicts into the exact key schema the offline harness uses (`h_px`, `img_h`, `pass`,
…), which let the scoring functions be copied across character-for-character. That was the whole
point: identical code is the precondition for a parity check to mean anything.

**Parity was then measured rather than assumed.** `.tmp/parity.py` loads the run-4 artifact, scores
every frame through both implementations, and compares them exactly: **621 frames, 0 mismatches,
worst absolute delta `0.000e+00`** (328 frames scoring nonzero, 78 rejected). A gate that passes is
worthless without a control, so it also mutates the pipeline's box-height constant from 0.28 to 0.05
and requires disagreement — it produced **589 mismatches**, confirming the comparison actually
exercises the pipeline's own code path and its module-level constants.

This is not pedantry. `.tmp/cmp-sim.py`'s gate is *"reality must equal the simulation's
prediction"*. Had the two implementations diverged by a float, that gate would validate against a
prediction that no longer describes the shipped rule, and the entire calibration would be
untransferable.

**The dump was extended without breaking its consumers.** `ocr-*.tsv` gained a `reason` column
(`word` / `union` / `both` / `-`) and the raw risk value. `reason` is what makes a rejection
recoverable after the fact — without it, a frame that both rules reject is indistinguishable from one
only the new rule catches, and the next calibration pass would have to re-derive it. The offline
loader reads this file with a header-keyed dict reader, so adding columns is safe; that was verified
before the columns were added, not after. Both dumps were also aligned to one `verdict` convention —
*the decision that shipped* — so cross-referencing them can never produce a contradiction.

**Selection was measured twice.** The obvious refinement (rank each span by risk, take the quietest)
was implemented and then rejected: it changed picks in 11 of 12 themes across 18 spans, replaced 17
already-inspected frames with never-inspected ones, and cut one span's winner to 55% of its byte
size — while avoiding **zero** known-bad frames, since the text filter has already removed those. A
threshold sweep found the tiered alternative: take the largest JPEG among survivors scoring below
`0.85`, falling back to the whole span if none qualify. From `0.67` upward it changes nothing on this
data (0 spans, 0 new frames, worst byte ratio 1.000) yet is not vacuous — three live survivors sit at
`0.901`, `0.907` and `0.997`. A bytes floor was considered and dropped: with a worst-case ratio of
1.000 it would guard a regression that cannot occur.

**Dilation was tested and deleted.** Three questions, three numeric answers: the union rule catches
4 of 4 known-bad frames *directly*, so nothing is left to catch; **zero** surviving frames adjacent
to a rejection are known-bad, making the adjacency hypothesis untestable rather than merely
unsupported; and every penalty weight is either inert or starts deleting clean survivors. Keeping an
unmeasurable mechanism "to be safe" would have been the unsafe choice.

**The contract suite justified itself immediately.** Returning the new counter changed
`text_filter`'s arity and the suite failed at once with an unpack error at the call site, rather than
silently in CI later. New coverage: the union rule staying inert on a word-rule rejection; a risk
score present on every candidate; the new dump columns; a **geometry-only** rejection end-to-end,
isolated by driving detection confidence below the confidence floor so coherence is structurally zero
and only the confidence-free box count can fire — which is `AnsatsuKyoushitsu-OP1` 79.5, the
OCR-blind leak, reproduced in miniature; and five selector cases including the fallback, the
exact-threshold boundary, and the deliberate hard failure when an unscored candidate reaches the
selector.

**One planned task dissolved on inspection.** The workflow was believed to need a change to upload
the newly promoted frames for review. Reading it showed the upload step already takes `out/`
wholesale, and run 4 confirmed that dry runs write all 36 stills there (`status='DRY'`, 36 files). A
capability assumed missing was verified before being built.

### What it changed in the live project

- `tools/pipeline/curate_theme.py` — the shipped still filter is now the calibrated rule, and the
  selector is risk-aware. Both were previously priced only on paper.
- `tools/pipeline/test_curate_contract.py` — covers the union path, the dump schema, and all five
  selector behaviours.
- `results.jsonl` gains `ocr_union_only`; `ocr-*.tsv` gains `reason` and `risk`.
- `.tmp/parity.py` — a reusable gate that will catch any future drift between the pipeline and the
  calibration harness.
- Nothing in the database or Storage changed; this pass was pipeline-only.

### What became possible next

One CI run with `ocr_dump=true` now settles B-28. It produces the seven never-inspected frames as
ordinary artifacts and lets `.tmp/cmp-sim.py` compare reality against the prediction — a comparison
that is only meaningful because of the parity result above. If both pass, the 134-theme population
run is unblocked.

### Still unproven

The rule has never executed in CI. The seven newly promoted frames remain un-eyeballed — no JPEG of
them exists anywhere yet, because they passed the old filter but the old selector never chose them.
Storage upload, `ingest_question` over HTTP, the retry ladder, real egress, and the entire frontend
remain untouched.

### Docs updated in this pass

- `doc/GAME-DESIGN.md` — §5.2.2 now states the rule is implemented and parity-proven rather than
  "priced but not shipped", and records the dilation deletion with its three numeric answers; §5.2.3
  replaces the *planned* risk-ranked selector with the measured rejection of it, the tiered rule that
  shipped, the threshold sweep, the absent bytes floor, and the faithfulness assertion.
- `doc/BLOCKERS.md` — B-28's old *Closes when* struck through and superseded by a new
  implementation section carrying the parity table, the negative control, the two rejected
  mechanisms, and a closing condition reduced to evidence only.
- `doc/PROGRESS.md` — this entry.



## 2026-08-23 (verification) — The rule passes CI, and passing CI is how a second leak class surfaced

Run `32629295922` (dry, `ocr_dump=true`, 12 themes, 19m29s) was the first CI execution of the
calibrated union rule. **Every automated gate passed.** `.tmp/cmp-sim.py` reported its positive
control at `disagreements: 0 -- control PASSES` with the negative control firing as required,
`PROMOTED 0`, and `themes shipping fewer than 3 stills: 0`. The shipped set matched
`simulate()`'s offline prediction **exactly** — all 12 themes, all 36 frames. Both previously
confirmed leaks are gone (`AngelBeats-OP1` 45.1, `AnsatsuKyoushitsu-OP1` 78.0). A second checker
written for this run, `.tmp/check5.py`, cross-validated the telemetry three independent ways
(TSV `CLEAN` against `ocr_clean`, TSV `reason=union` against `ocr_union_only`, and
`clean(run4) - union_only == clean(run5)`) and reported `inconsistencies: 0`; clean population
fell 599 -> 535 with 64 union-only rejections.

### How that turned into a blocker rather than a closure

The rule was verified. Coverage was not. The union rule promotes 10 frames that no earlier pass
had looked at, and the automated gates could only ever measure the **4 labelled** positives —
`PROMOTED 0` means "no *known* bad frame shipped", not "no bad frame shipped". Eyeballing all ten
found nine clean and one leak: **`BlackClover-OP1` @ 57.9 s, a cursive character-name card**
("Vanessa Enoteca", "Gauche", "Charmy Pappitson", ...). Overlaid production text, no title
anywhere, one search from the answer. The criterion recorded back in the first eyeball pass
already counts this as a leak — *title, credit and character-name overlays* — and the run-3 table
had in fact flagged a different `BlackClover-OP1` frame as "faint cursive, verdict ?" and never
resolved it. The first three eyeball passes hunted *title* text specifically, which is exactly how
a name card walked through them.

### Every available remedy was priced, and all but one were falsified

`.tmp/shipscan.py` ranked all 36 shipped frames by text density and priced every candidate risk
threshold against the full 535-frame clean pool. `.tmp/cursive.py` tested whether the hazard is
confined to a credits window.

- **Threshold-lowering: rejected.** The leak scores `risk` 0.5183 while **four confirmed-clean
  shipped frames score 0.6667**. Catching it costs 67 of 535 clean frames and displaces those four
  known-good stills to gain one — the same trade already rejected for `BIG_T=4` and for dilation.
- **Density: rejected.** The leak ranks **9th** at 72 `chars_0`. The two densest shipped frames
  (287 and 253) are a repeating damask motif and a grunge texture — **zero text in either**.
- **Time-window exclusion: rejected.** Matching frames occur in contiguous runs of **1-4,
  overwhelmingly 1**, scattered across the clip. There is no window to cut.
- **Triage filter: viable.** The same signature (`longest_0 >= 5 AND longest_70 < 5 AND
  chars_0 >= 40`) is far too noisy to reject on — 47 of 647 candidates, mostly texture. But
  restricted to the *ship set* it fires on **2 of 36 frames, one being the leak**: 1 true
  positive, 1 false positive, 0 false negatives. That scales a 402-frame human review across all
  134 themes down to roughly **22 flagged frames**. Recall rests on a single positive and is
  honestly unproven.

### What this changed in the repo

No code changed. The pipeline shipped at `ed3d177` is confirmed correct and needs no
recalibration. What changed is knowledge: B-28's closing condition is now *"the name-card class has
an agreed remedy and all 134 themes' shipped stills are cleared under the full criterion"* rather
than *"seven frames survive an eyeball"*. A newly documented gap blocks any remedy — **no
frame-level exclusion mechanism exists**: `manifest.json`'s `excluded` is theme-level and
`curate_theme.py` has no per-timestamp blocklist, so acting on a rejected frame means building one
first (small, but it does not exist today).

Two stale claims were also corrected. The "~3x coherence safety margin" was measured over the 41
labelled frames only; the name-card leak sits at coherence 0.1088 against `COH_T` 0.21, so the
**real margin is 1.93x**. And `doc/GAME-DESIGN.md` still said the rule "has not yet run in CI".

### What became possible next

The content run is unblocked on correctness grounds — the rule is proven and re-runs skip
already-ingested themes, so the 134-theme batch can proceed whenever the review policy is settled.
What is *not* yet decided is that policy, and it needs a call rather than a default, because it
trades a documented product promise ("2-3 progressively revealed still frames, **text-free**",
shown during play at 0/7/14 s) against days of review effort.

### Docs updated in this pass

- `doc/BLOCKERS.md` - B-28's evidence-only *Closes when* struck through and superseded by a
  verification section carrying the six-row gate table, the new leak class, the three-row
  discriminator table, the threshold cost, the dead time-window option, the triage finding, and
  the missing-exclusion-mechanism note.
- `doc/GAME-DESIGN.md` - 3 no longer claims the rule is unrun in CI and now names the second leak
  class; 5.2.2 records the CI confirmation, why the blocker still stays open, and the corrected
  1.93x coherence margin.
- `doc/PROGRESS.md` - this entry.

## 2026-08-23 (supervision + build) — Both answer leaks closed, and the game is deployed

A supervisory audit of everything built so far ran first: all 11 migrations and the whole
curation pipeline, read against the docs that describe them. It found a single recurring
failure mode rather than a scatter of unrelated bugs, and that framing is the most
reusable thing in this entry.

**The pattern: a comment asserting safety stops the next reader from checking.** Four of
the six SQL defects below are gaps between what a comment claims and what the statements
beside it do. Migration 0010 removed `clip_key` and recorded that `question_id` "stays on
the row and remains harmless". The `guesses` policy called a live answer leak "a UI
obligation, not schema-enforceable". `ocr_words` makes a tesseract crash fatal with
exactly the right reasoning, and the ffmpeg three lines away failed silently. This is why
execution testing missed all of them: **the tests confirmed what the comments claimed.**
The rule adopted going forward, and applied throughout migration 0012, is that a comment
asserting something is safe must name the query that proves it.

### What was wrong, and what it now does

**Two independent paths let a client read the answer.** Either one defeats the product.

- `rounds.question_id` was readable for every round of the game, unplayed ones included,
  and `create_room` pre-inserts them all. `question_id` is a *globally stable* identifier
  for a fixed answer, so a player who recorded `(question_id -> ROUND_REVEAL titles)`
  across a few games owned a permanent answer key to a ~134-row bank, then read every
  answer out of the lobby before round 1. Closed with a **column-level GRANT** — RLS is
  row-level and cannot withhold a column. Verified: `authenticated` now holds SELECT on
  `ends_at, id, ordinal, room_id, started_at` and nothing else.
- `guesses.raw` was readable by every room member the instant it was inserted, and
  `guesses` is in the realtime publication, so the winning guess text was *pushed* to
  every client with ~15 s still on the clock. Now: own guesses always, everyone else's
  only past that round's `ends_at`, via a new SECURITY DEFINER `is_own_player`.

**Four correctness bugs, all user-visible.** `grade_guess` stored `(false, 0)` for the
first-correct race loser and then returned the *unreset* locals, so two players 15 ms
apart both saw "+187" while the scoreboard paid one — the doc's own pseudocode has the fix
and 0005 dropped the line. The final round never revealed, because `ROUND_REVEAL` sat
after the game-over branch. The 8-second reveal phase did not exist at all:
`reveal_duration` was read by nothing and `state='reveal'` set by nothing. And fuzzy
matching used edit distance 1 with **no length floor**, which against the real manifest
made **15 of 46 anime winnable by typing one or two characters** — `HQ!` normalises to
`hq`, so `h` scored; `SAO`, `FMA`, `DBZ`, `OPM`, `CSM`, `HxH` are all three.

The reveal phase is now real *without new state*: `advance_round` pushes the next round's
`started_at` forward by `reveal_duration`, and `grade_guess` already rejects anything
outside `[started_at, ends_at]`, so the gap is enforced rather than advisory.

**Caps and hygiene the design claimed and nothing enforced.** An 8-player cap with the
room row locked `FOR UPDATE` (which also closes a `start_game`/`join` race); one question
per anime, because `anime_slug` existed unused and `unique(room_id, question_id)` only
stops the same *theme* — about half of all 10-round games repeated a show, and the second
time it was free points; genuinely dense round ordinals, which previously relied on
`LIMIT` without `ORDER BY` returning rows in window order (a plan artefact, not a
guarantee — sparse ordinals would leave `start_game`'s `WHERE ordinal = 1` matching
nothing and the room permanently unstartable); realtime topics keyed by room uuid instead
of the 4-character code; and removal of the `anon` execute grants, which were never needed
because Supabase anonymous sign-in issues `role=authenticated`.

### Migration 0013 and the transport decision

`get_room_state` is the client's single polled read endpoint: room state, scoreboard,
current round with asset keys, and the reveal for the most recently *finished* round.

**Polling was chosen over Realtime deliberately.** `emit_room_event` publishes with
`realtime.send(..., false)` — a public channel — and the reveal payload contains the
answer. But the decisive argument is not security: *a push tells a client what happened,
it does not tell a client what is true.* After a refresh, a backgrounded tab, or a dropped
socket, the client needs a "what is the state right now" call regardless. Once that call
exists, polling it **is** the whole client. Measured cost is ~1.2 MB per game against
10-22 MB of media for the same game — about 10% overhead, still ~215 games inside 5 GB.
The broadcasts are left in place as a future latency optimisation.

### The web client, and the pipeline's silent fail-open paths

`app/` is the first frontend this project has ever had: home, lobby, play, reveal and game
over, progressive stills, a countdown corrected against `server_now` (a browser clock can
be minutes out), deep-link invites, and a mobile-first layout. No framework, no build step,
**and no `supabase-js`** — polling plus REST is all `fetch()`, so the page carries zero
third-party runtime dependencies. It detects both remaining setup steps and renders the
fix rather than failing blankly.

The pipeline audit found three fail-open paths in the one filter standing between a title
card and the player:

- **rapidocr's geometry was discarded on exactly the frames it exists to catch.** Its
  boxes carry no page dimensions and were backfilled *only* from the `orig` tesseract
  pass; when that pass read nothing — 24 of 621 frames in run 5 — every rapid box kept
  `img_h = 0`, scored `_frac() == 0.0`, and dropped out of **both** union features. Those
  are precisely the frames where tesseract is blind and rapidocr is the only defence. Now
  falls back to the `up2x` page box halved, and **unresolvable geometry scores at the
  reject line instead of zero**: unmeasured is not clean.
- **A failed ffmpeg upscale silently deleted an OCR pass** — no log, no counter, no effect
  on exit status. Now fatal, matching the policy `ocr_words` already applies to a tesseract
  crash three lines above it. The partial PNG no longer leaks either.
- **The baseline bonus read `toks[0]`, the first token of the frame**, which need not be in
  the cluster being scored. Latent on run-5 data, and faithfully ported from the offline
  calibrator, defect included.

Also: stdin is decoded as explicit UTF-8. Every job line carries CJK and the workflow sets
no `LANG`/`PYTHONUTF8`, so this worked only by grace of the runner image.

### CI

`curate.yml` gains a **minimum-yield gate**. It previously went green when the pipeline
produced nothing at all — every theme skipping is "0 failures" — and that is not
hypothetical: §5.2.2 records a measured run where the then-current rule skipped 8 of 10
themes, and it would have reported success. `test.yml` runs the contract suite, which had
been tracked, green and **never executed in CI once**. `pages.yml` deploys `app/` and
refuses to publish a privileged key by decoding any JWT it finds and checking the `role`
claim — the first version grepped for the string `service_role` and failed the deploy on
`config.js`'s own comment explaining that the service_role key must not go there. A grep
for a key name cannot tell a key from a sentence about keys.

Contract tests gained coverage of the union rule's own arithmetic. Neither existing fixture
ever drove `_coherence` to a nonzero value or made `_dedupe` merge anything, so the two
functions the whole calibration rests on had **none**. Pinning the expected coherence value
immediately earned its keep: the first assertion was wrong (the median of three heights is
80, not 82) and the code was right.

### What changed in the live project

- Migrations **0012** and **0013** applied to `mxkqivivqultfuattuin` and verified by
  querying `information_schema` and `pg_policy` rather than trusting the apply.
- **GitHub Pages enabled** (`build_type=workflow`) and **the site is live** at
  `https://sayandeep1013.github.io/Rein-Bot/`, serving `index.html`, `style.css`, `app.js`
  and `config.js` at 200 with `charset=utf-8`. Note that `actions/configure-pages` with
  `enablement: true` does **not** bootstrap a site that has never existed — the first
  deploy failed there, and `gh api -X POST repos/<owner>/<repo>/pages -f
  build_type=workflow` is what created it.
- A first **non-dry curation run**, exercising the Supabase Storage upload and HTTP
  `ingest_question` paths that had never executed even once.

One verification lesson worth keeping: the first check of the `question_id` fix reported
`YES -- LEAK STILL OPEN`. The migration was correct; the *check* was wrong, matching a
leftover `REFERENCES` grant because it did not filter on `privilege_type`. An audit query
that is not itself audited is just a rumour with a `select` in front of it.

### What became possible next

The two remaining blockers are both manual dashboard steps (anonymous sign-in, and the
publishable key), and the client renders precise instructions for each rather than failing
blankly. Once those are done the game is playable end to end, and the only remaining work
is bulk content: the curation run is idempotent on `asset_slug`, so the remaining themes
are a mechanical re-run.

### Addendum, same day — the content bank is full

The self-chaining load walked the whole pool unsupervised. **134 questions, 46 distinct
anime, 371 accepted answer strings, 43.1 MB stored** — against a prediction of ~45.6 MB,
so the arithmetic in HANDOFF §9 was good to within 3%. The OP/ED split came out 79/55,
exactly the figure computed from the manifest. Every question carries the full 3 stills;
no theme degraded to 2.

Round capacity by difficulty range, which matters because `create_room` now picks one
question **per anime**:

| Difficulty | Distinct anime = max rounds |
| --- | --- |
| 1–5 (default) | **46** |
| 2–5 | 46 |
| 3–5 | 36 |
| 4–5 | 29 |
| 5 only | 16 |

All comfortably above the 20-round maximum, so the anime-dedupe added in 0012 costs
nothing at any setting a host can actually choose. The tier-1 warning carried in earlier
handoffs — "tier 1 holds only 13 themes" — only ever bit a *tier-1-only* room, and that
configuration now caps at 8 rounds rather than failing confusingly.

**Two workflow lessons from the load**, both recorded in `curate.yml` itself:

- **Dispatching several slices at once does not queue them.** A concurrency group holds
  one running plus one pending run, and a third arrival *cancels* the pending one.
  Firing four slices produced one running, one pending and two `cancelled` — silently,
  because a cancelled run is not a failed run and nothing in the run list draws
  attention to it. Replaced with `auto_continue`, where a successful run dispatches its
  own successor. The whole pool then loads end to end with exactly one run in flight,
  and the chain halts on failure rather than being papered over by the next slice.
- **`ingest_question` failed on its first ever HTTP call** with `PGRST202`. PostgREST
  maps the top-level keys of an RPC body to *named* arguments, and the pipeline posted
  the payload bare against a function taking one `p_payload jsonb`. Every previous test
  went through SQL, where the argument is positional and the mistake cannot exist. The
  best argument in this repo for exercising a path rather than reasoning about it.

**Orphan handling closed the loop.** That failed ingest left five objects with no row
pointing at them, which is the intended failure direction — objects upload before the
row is written, so a row can never point at bytes that never arrived. `sweep.yml`
removed them and `tools/sweep-orphans.sql` confirmed `orphan_count: 0` from the SQL
side, so two independent methods agree the bucket now holds exactly the 670 objects
`question_bank` references.

Sweeping had to become a workflow rather than a script: `storage.protect_delete()`
rejects a direct `DELETE` from `storage.objects`, not only from `storage.buckets` as
HANDOFF §5 recorded.

**Security advisor, run after the schema settled.** Two WARN findings were real and
fixed: `is_room_member` and `is_own_player` were executable by `anon`. Both are internal
helpers used inside RLS policy expressions, neither is client API, and both return false
for `anon` anyway since they resolve identity from `auth.uid()` — but "returns false
today" is precisely the reasoning migration 0012 exists to stop relying on. Revoked from
`anon` only: a policy expression's function calls are permission-checked against the
querying role, so revoking from `authenticated` would break the policies that call them.

Two further findings were reviewed and deliberately not acted on. The game RPCs are
`SECURITY DEFINER` and callable by `authenticated` because they **are** the client API,
and each re-checks membership rather than trusting its caller. And
`question_bank`/`question_titles` report "RLS enabled, no policies" — which, combined
with zero grants, is the strongest posture available rather than an oversight.
