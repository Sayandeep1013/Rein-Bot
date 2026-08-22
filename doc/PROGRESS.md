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

