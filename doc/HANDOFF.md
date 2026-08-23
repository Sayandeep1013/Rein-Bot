# Session handoff

**Written 2026-08-23.** State at commit `b86ca2f`.

Read this top to bottom before touching anything. It is written for an agent with no
memory of prior sessions.

This file is deliberately plain ASCII (no em-dashes, no arrows, no section-sign
characters) so that exact-string edits against it always match. The rest of `doc/`
is not - see "Editing the docs" below.

---

## 1. What this project is

**GuessTheAnime** (repo name `Rein-Bot`). A free-to-run, browser-based multiplayer
guessing game. Players are shown material from an anime opening or ending and race to
name the show.

- 2 to 8 players per room, 3 to 20 rounds (default 10), 20 s per round, 8 s reveal.
- Room codes are 4 characters of Crockford base32. No accounts, no email, no passwords.
- Free-text answers with fuzzy matching, not multiple choice.
- Winner-takes-all per round: only the first correct answer scores. It earns a
  speed-decaying score from 200 down to 100 over the round. A correct-but-second guess
  scores **0** by design (this was a documented contradiction, resolved as B-22).
- Content is a curated pool built from a popularity cut of AnimeThemes.moe.

### What a round actually contains (settled 2026-08-23, do not relitigate)

**No video is ever stored or served.** Each question owns five objects:

| Object | Count | Approx size |
| --- | --- | --- |
| Opus audio, ~20 s from the musical body | 1 | ~160 KB |
| Text-free still frames | 2 or 3 | ~30 KB each |
| Poster, shown only on reveal | 1 | ~30 KB |

During a round, stills are revealed progressively at roughly 0 s / 7 s / 14 s. On reveal
the client shows the poster plus the title.

**Audio is optional per room.** The host toggles it at room creation
(`rooms.audio_enabled`, default `true`). Two formats exist and both must work:

- **stills-only** - frames only, no audio
- **audio + stills** - the default

This was the user's explicit request: "give teo options ... one just frames ... n one
just audio n frames ... like while room creation give the host option to toggle aufio on
n off".

---

## 2. Hard rules you must not break

These come from `CLAUDE.md` at the repo root. Read that file too; it is short.

1. **`D:\Projects\GuessTheAnime` is the entire world.** Do not read, write, glob or grep
   any path outside it. No writing to `%APPDATA%`, `%USERPROFILE%`, drive roots, or any
   global tool config. No global installs (`npm i -g`, winget, choco, scoop).
2. **Temp files go in `.tmp/` inside this folder.** Never a system temp directory.
   `.tmp/` is scratch; nothing in it is authoritative.
3. **Secrets live in `.env.local` only**, which is never committed.
4. **Free tier only, for every service including CI.** If something has no free option,
   say so plainly rather than assuming a paid plan. Record the actual quota numbers and
   the arithmetic showing the design fits.
5. **Testing happens in the cloud.** Do not add a local database server, local Docker,
   or anything that installs a background service on the user's laptop.
6. **Every completed task ends with a documentation update.** `doc/PROGRESS.md` gains a
   dated entry describing what was done, the mechanism (not just the outcome), what it
   changed in the live project, and what became possible next. Any doc the task made
   stale is fixed in the same pass. A task whose only deliverable was code, with
   untouched docs, is an incomplete task.
7. **No implementation code without explicit approval.** This rule is now partially
   lifted: the user said "u start the next phase and continue building", which authorises
   the backend, the curation pipeline and the frontend. It does **not** authorise
   redesigning settled decisions.

### Deployment target

**GitHub Pages, not Vercel.** The user said "skip vercel ... use github pages for the
deployment". Site will serve from `https://sayandeep1013.github.io/Rein-Bot/`, so the
frontend must use **relative asset paths only**.

Frontend stack: static HTML plus vanilla JS. No framework, no build step.

---

## 3. Current state

### Done and verified

- **Migrations 0001 through 0010 are applied live** to Supabase project
  `mxkqivivqultfuattuin` and schema-verified.
- `pipeline/manifest.json` holds **46 anime, 136 themes**, 5469 MB of source video.
  Difficulty distribution across tiers 1-5 is **13 / 32 / 28 / 28 / 35**.
- `.github/workflows/curate.yml` exists and its **dry run is green** (run
  `32590411786`, `ok=0 skipped=10 failed=0`). Three separate bugs in it were found and
  fixed.
- README and GitHub About/topics match the user's own repo style, as requested.
- Docs are current as of `b86ca2f`.

### Not done at all

- **`question_bank` has 0 rows.** No content exists. Nothing is playable.
- **Nothing has ever been uploaded to Supabase Storage.** That code path has never
  executed, not once.
- **`ingest_question` has never been called over HTTP**, only via SQL.
- **There is no frontend.** Not one HTML file.
- The retry/backoff ladder in the workflow has never been triggered.
- Real Supabase egress has never been measured.

### The single most important open risk: B-28

Frame selection uses OCR to reject any frame containing text. **That OCR step is now the
only thing standing between an anime's title card and the player.**

The previous protection was believed to be the AnimeThemes `nc: true` (credit-free) flag.
On 2026-08-23 that was measured and found to be worthless for this purpose: **5 of 10
sampled clips display the title in Latin script**, and all ten satisfied
`nc:true, subbed:false, overlap:NONE`. The split was **5 of 6 openings vs 0 of 4
endings** - the title card is an *opening convention*, not a credits artefact, so a flag
about credits was never going to catch it.

Anime title logos are the adversarial case for OCR: heavy stylisation, outlines,
gradients, rotation, overlap with artwork. Tesseract may simply not see them.

**This cannot be tested locally.** `tesseract`, `ffmpeg` and ImageMagick are all absent
from the user's machine. It is provable only in CI.

**A green CI run proves nothing here.** You must open the dry-run artifact and look at
every surviving still with your own eyes, specifically hunting false negatives. Full
detail and the fallback ladder are in `doc/BLOCKERS.md` under B-28.

---

## 4. The data model as it now stands

`doc/DATA-MODEL.md` is authoritative (878 lines). Summary:

### Content tables

- **`question_bank`** - one row per question. Key columns: `id uuid`,
  `asset_slug uuid not null unique` (stills), `poster_slug uuid not null unique`,
  `audio_slug uuid not null unique`, a `question_bank_slugs_distinct` CHECK that the three
  differ, `still_count smallint not null check (2..3)`,
  `audio_seconds int`, `bytes_total int`, plus provenance and `difficulty`.
- **`question_titles`** - the accepted answers, with `title_norm` produced by
  `normalise_title`.
- Neither table has **any** client grant. Clients cannot read them at all.

### Game tables

`rooms`, `players`, `rounds`, `guesses`. `rooms` carries the settings including
`round_count`, `difficulty_min/max`, `round_duration`, `reveal_duration` and
`audio_enabled`.

### Storage

One public-read bucket, **`media`**, limits `{audio/webm, image/jpeg}` and a 512 KB
per-object cap. Keys, and this is the only place they are defined - by the SQL function
`question_asset_keys(p_still_slug, p_poster_slug, p_audio_slug, p_still_count)`:

```
audio/{audio_slug}.webm
stills/{asset_slug}-{n}.jpg      n = 1 .. still_count
posters/{poster_slug}.jpg
```

The two-argument version was dropped by migration 0011, not kept as an overload.

An empty legacy `clips` bucket still exists and is inert (its read policy was dropped).
Deleting it requires a Storage API call, not SQL - see the hazard list below.

### The two rules you must not violate

**1. Each asset class has its own key root. None derives from `id`, or from each other.**

`rounds.question_id` is readable by every room member, and `create_room` pre-inserts
every round of the game up front. So if keys were a function of `id`, reading a row you
are allowed to read would be equivalent to holding the keys to content you have not
reached yet - and the bucket is public-read.

Migration 0010 fixed that with one `asset_slug`, which left a smaller hole: the poster is
deliberately the title card, and `posters/{slug}.jpg` was one path segment away from the
`stills/{slug}-1.jpg` a player legitimately holds. So `question_bank` now carries three
independent roots - `asset_slug` (stills), `poster_slug`, `audio_slug` - each `not null
unique`, with a CHECK that they differ. Four uuids per row is deliberate: `id` is public,
the three roots are not, and no root is derivable from `id` or from another root. They are
not meant to agree.

Because the bucket is `public = true`, reads by key **bypass RLS entirely** - this was
measured, not assumed. Key unguessability is the only thing protecting an object, so 122
bits per root is the control.

**2. Asset keys reach a client only through `get_current_round`.**

```
get_current_round(p_room_id uuid) returns jsonb
{ state, ordinal, ends_at, audio_enabled,
  assets: { stills: [key, ...], audio?: key } }
```

`security definer`, `stable`, granted to `authenticated` only. It re-checks
`is_room_member` rather than trusting the caller and returns **one** round.

It strips two things, for two different reasons:

- **`poster` always.** This is correctness, not caution. The poster is harvested from
  the frames the OCR filter *rejected for containing text* - the single most spoiling
  frame in the sequence is exactly the frame the reveal wants. Shipping it during play
  hands over the answer in a form no fuzzy-matching rule can intercept.
- **`audio` when `audio_enabled` is false.** This is an egress control, not a security
  control. The bucket is public, so a determined player could fetch it anyway; the point
  is that a client-side bug must not be able to spend the bandwidth the toggle exists to
  save.

### Functions

`normalise_title`, `grade_guess`, `create_room`, `join_room`, `start_game`,
`advance_round`, `get_current_round`, `question_asset_keys`, `ingest_question`,
`emit_room_event`, `is_room_member`.

---

## 5. Environment hazards - read this or lose hours

### Tools that are NOT installed

`tesseract`, `ffmpeg`, `ffprobe`, `magick`, `jq`, `cv2`, `pytesseract`.

**`convert.exe` is on PATH but it is the Windows filesystem conversion tool, not
ImageMagick.** Calling it expecting ImageMagick will do something unrelated.

### Tools that ARE available

- `python` at `D:\python\python.exe`. `PIL` and `numpy` are installed.
- `gh` at `D:\gh\bin\gh.exe`.
- `bash` at `C:\WINDOWS\system32\bash.exe`.
- `git`.

### PowerShell 5.1 traps

The shell is Windows PowerShell 5.1. All of these have already cost time:

- **`Set-Content -Encoding UTF8` always writes a BOM.** Never use it for a file you will
  pass to `git commit -F` - the BOM ends up as the first character of the commit subject
  line. This already happened once, in commit `934327a`, whose subject begins with an
  invisible BOM. It was not force-pushed and is left alone.
  Use the `write` tool instead, or
  `[System.IO.File]::WriteAllText(path, text, New-Object System.Text.UTF8Encoding($false))`.
- **`Get-Content -Raw` without `-Encoding UTF8` decodes BOM-less UTF-8 as cp1252**,
  silently mangling every non-ASCII character.
- **No `<<<` heredoc.**
- **`$$` inside an inline `python -c` invocation gets mangled by PowerShell.** Write a
  script file into `.tmp/` and run that instead. Dollar-quoted SQL (`$$ ... $$`) must
  never be passed inline.
- **`.Count` on a bare `PSCustomObject` returns `$null`**, not 1.
- `&&` does not chain. Use `cmd1; if ($?) { cmd2 }`.
- The `write` tool refuses to overwrite an existing path. `Remove-Item <path> -Force`
  first, or use `edit`.

### Supabase / Management API traps

- **Multi-statement queries run as ONE transaction.** One bad statement rolls back the
  entire migration. This is good for safety and means you get all-or-nothing.
- **`storage.protect_delete()` rejects any direct `DELETE` from `storage.buckets`** with
  `ERROR: 42501`. `INSERT` into it is fine. Removing a bucket is a Storage API call
  (`DELETE /storage/v1/bucket/{id}`), which needs the service-role key.
- The service-role key is **only in GitHub Actions secrets**, not in `.env.local`. You
  cannot make service-role calls from the laptop.

### GitHub CLI traps

- `gh run view --json X -q '...'` fails in this setup. Use
  `gh api repos/{owner}/{repo}/actions/runs/{id}` instead. The `/jobs` sub-resource is
  the accurate one for step-level status.
- PyYAML raises `KeyError: 'on'` when parsing workflow files. This is harmless - `on` is
  parsed as the boolean `True`. Do not "fix" it.

### AnimeThemes traps

- `basename` from the API **includes the file extension**. Strip it:
  `stem="${basename%.webm}"`.
- Use the project's User-Agent:
  `GuessTheAnime-curate/1.0 (+https://github.com/Sayandeep1013/Rein-Bot)`.

### Editing the docs

`doc/*.md` files contain em-dash `U+2014`, `U+00B7`, `U+2192` and section-sign
characters. The `edit` tool's exact matching breaks on these easily.

**Use a Python script in `.tmp/` with an assertion per replacement**, like
`.tmp/dm-0010.py`. Pattern that works:

```python
c = s.count(old)
assert c == 1, 'MISS %s: found %d' % (label, c)
s = s.replace(old, new, 1)
```

Match em-dashes as `"\u2014"` in the Python source. Always `io.open(..., encoding='utf-8')`
and write back with `newline=''`.

---

## 6. Command recipes

### Run SQL against the live database

`.tmp/q.ps1` is a reusable runner. It reads `SUPABASE_ACCESS_TOKEN` from `.env.local` and
never echoes it.

```powershell
cd D:\Projects\GuessTheAnime
& powershell -NoProfile -ExecutionPolicy Bypass -File .tmp\q.ps1 -File .tmp\yourquery.sql
```

It POSTs to
`https://api.supabase.com/v1/projects/mxkqivivqultfuattuin/database/query`.
Prints `=== OK ===` or the error. Note `.tmp/` is scratch - if `q.ps1` is missing,
recreate it from this description.

### Apply a migration

Same mechanism. `.tmp/apply0010.ps1` is the worked example. Before applying, check
dollar-quote balance with a script like `.tmp/check0010.py` - an unbalanced `$$` produces
a confusing syntax error far from the real problem.

Migrations live in `supabase/migrations/` and are named
`YYYYMMDDNNNNNN_description.sql`. See `supabase/migrations/README.md` for the apply
mechanism and the non-ASCII/BOM hazards.

### Trigger the curation workflow

```powershell
& D:\gh\bin\gh.exe workflow run curate.yml -f dry_run=true -f limit=10
& D:\gh\bin\gh.exe api repos/Sayandeep1013/Rein-Bot/actions/runs
```

---

## 7. Decisions already settled - do not reopen

The user has said "the decisions are okay". Each of these has reasoning recorded in the
docs. Reversing one means reading that reasoning first.

| Decision | Why |
| --- | --- |
| Stills, not video | A video window is contiguous. `-ss 5 -t 20` takes whatever is in the span, and OP title cards routinely land in the first ~15 s. You cannot exclude a card at 0:12 without losing the surrounding footage. Stills are chosen independently, so each is vetted alone. |
| The title card is kept as the poster | It is a liability during play and the ideal image on reveal. The OCR filter already identifies it, so it costs nothing to harvest. |
| three independent slugs, not `id`, root the keys | See section 4. |
| Delivery via RPC, not a table read | See section 4 and the rejected list below. |
| `audio_enabled boolean`, not a mode enum | Matches the flat-column style of `rooms` and the toggle the host actually sees. A speculative third format is one more column later, rather than an enum whose values must be interpreted everywhere today. |
| Bucket limits tightened, not widened | `video/webm` removed outright, so the one upload the design forbids is now impossible. 5 MB dropped to 512 KB since the largest object is ~160 KB. |
| Renamed `clips` to `media` while empty | Free at 0 objects, a ~680-object copy later. |
| `nc: true` kept despite being disproved | Not for safety - it does not provide any. Credit-free sources carry less on-screen text overall, so they yield more usable frames per sequence. |
| `size` is a tiebreak, never a filter | Credit-free variants are the *larger* population (~46.7 MB median vs 26.1 MB unfiltered), so "pick the smallest" systematically selects against `nc: true`. |
| JPEG-bytes vs per-theme median for frame quality | Needs no tooling beyond the encoder already present. Per-theme because one sampled theme's frames all sit below the global median, so a global cut would over-reject dark shows. |
| Winner-takes-all scoring | Resolved B-22. A correct-but-second guess scoring 0 is intended. |

### Approaches already tried and rejected - do not retry

- **A brightness or `ffmpeg blackframe` frame filter.** Measured on 40 real frames: the
  worst frame in the set, a flat grey card, has mean luma **180.0** and ranks **39th of
  40** on brightness. A brightness filter scores the worst frame as one of the best. Its
  real signature is luma std 0.2, mean gradient 0.01, 1702 bytes = 19% of its theme's
  median. Luma std alone also fails - a bimodal flat frame measured 3rd-highest std in
  the set while sitting at 48% of median.
- **An `ordinal <= current_round` RLS predicate** as the fix for the content leak. It
  makes a correctness-critical security property depend on a policy expression that must
  stay right through every future change to round progression, and it still exposes the
  current round's keys to a member who is merely spectating. Dropping the column removes
  the data instead.
- **Putting asset keys in the ROUND_START broadcast.** `emit_room_event` publishes with
  `realtime.send(..., false)`, a public channel keyed by a 4-character room code - a
  keyspace of about 1 million.
- **Deriving keys from `question_bank.id`.** Recreates the leak; see section 4.
- **Perceptual hashing to deduplicate frames.** Thirds already enforce temporal
  distance; a hash threshold is one more tuned constant with no measured basis.
- **Hardcoding `nc:true` in the manifest query**, and **the User-Agent hypothesis** for
  a download failure. Both were wrong diagnoses.
- **`sleep 1` to `sleep 5`** as a fix - it was a no-op for the actual failure.

### Delegation does not work in this environment

Four specialist subagent invocations across two agent types returned **empty or
unusable** output: two `oracle` calls (failed after 7m43s and 2m10s, the second with
every fact inlined and file reading forbidden), and two `librarian` calls. The top-50
seed list was ultimately authored by hand into `doc/SEED-LIST.md`; the GitHub Pages
limits were answered with `webfetch`.

**Decide directly. Do not delegate.** If you do try, note that `task(task_id=...)`
requires the session id (`ses_...`), not the background handle (`bg_...`).

---

## 8. What to do next, in order

### Step 1: Rewrite `.github/workflows/curate.yml`

This is the immediate next task and the biggest one. The spec is
**`doc/GAME-DESIGN.md` section 5.2**, which was written specifically so you can implement
from the doc rather than re-deriving it. Read it first.

Shape:

1. `apt-get install tesseract-ocr tesseract-ocr-jpn` (plus ffmpeg, already installed on
   the runner).
2. **Download the source once.** It is the expensive step (~46.7 MB median); everything
   else derives from that one file. Do not re-download per asset.
3. Extract ~20 s of audio from the musical body, encode Opus, target ~160 KB.
4. Extract ~60 candidate frames, evenly spaced, **skipping the first and last ~2 s** so
   fades and hard cuts are excluded.
5. **Detail filter:** encode each candidate at fixed quality, reject any below **45% of
   that theme's median byte size**. At 45% this rejected 3 of 40 in the sample and left
   every one of the ten themes with at least 2 survivors.
6. **OCR filter:** `tesseract --psm 11 -l eng+jpn` per frame, reject on any text hit.
   **Tune to over-reject.** A false positive costs one frame out of sixty; a false
   negative ships the answer.
7. **Spread:** split survivors into three equal spans by timestamp, take the
   highest-detail survivor from each. Fewer than 2 survivors total means **skip the
   theme** - do not degrade to one still.
8. **Poster:** take it from the frames rejected in step 6 for containing text.
9. **Upload all five objects** to `media` under keys from three fresh uuids (one per asset
   class), **then** call `ingest_question`. Objects first, always: a row pointing at bytes
   that never arrived is worse than an orphaned upload, and with five objects that window
   is five times wider.

`ingest_question` v3 payload takes `asset_slug`, `poster_slug`, `audio_slug`,
`still_count`, `audio_seconds`, `bytes_total`. It stays idempotent on `asset_slug` alone,
so a batch that dies partway can be retried. Its named failures are `MISSING_ASSET_SLUG`,
`MISSING_POSTER_SLUG`, `MISSING_AUDIO_SLUG`, `SLUGS_NOT_DISTINCT`, `INSUFFICIENT_STILLS`
and `NO_TITLES (slug %)`. All four guards have been exercised against the live database in
SQL; **none has been exercised over HTTP yet.**

Validate the YAML after every edit. The previous version needed three separate bug fixes.

### Step 2: Dry-run 10 themes and inspect for OCR FALSE NEGATIVES

Not for crashes. **Look at every surviving still.** If any shows the title, B-28's
fallback ladder applies: bias selection toward endings (0 of 4 EDs leaked a title vs 5 of
6 OPs), or sample from the back half of the sequence where title cards are rare, or gate
low-confidence themes into a manual review list rather than the question bank.

Note that the existing artifact tiles sample only 4 frames of roughly 600, so **the four
clips that looked clean are not actually cleared.**

### Step 3: Populate for real

Run with `dry_run=false` for all 136 themes. Expect ~38 MB stored. Watch for the retry
ladder actually firing for the first time.

### Step 4: A single-file HTML page against the live backend

Smallest thing that proves the untested paths: anon sign-in, `create_room`, `join_room`,
`start_game`, `get_current_round`, fetch a still from the public bucket, submit a guess
through `grade_guess`. This is the first time Storage reads and RPC-over-HTTP will ever
have run.

### Step 5: The real UI, then Pages deploy

Lobby, play, reveal, scoreboard, mobile layout. Relative paths only. Then a Pages deploy
workflow, then a two-browser multiplayer test, then measure real egress against the
arithmetic below.

### Leftover doc debt (medium priority, safe to batch)

- `doc/GAME-DESIGN.md` sections 1.1, 2 (round timeline) and 2.1.1 (threat model) still
  describe video. The threat model also needs a note that reverse image search and
  trace.moe get marginally easier with clean held stills - the frames chosen for detail
  are the best possible search inputs. The existing reasoning (speed bonus beats search
  time) mostly carries over.
- The blockquote in section 5.1 still says clips are re-encoded to ~1 MB at step 6. That
  step no longer exists.
- `doc/ARCHITECTURE.md` asset flow, and `doc/RESEARCH.md` section 4.7 egress arithmetic,
  both need the two-mode numbers below.

---

## 9. The numbers

The user's stated ceiling: "i have upto 5gb of egress limit .. so stay in that".

| Mode | Per round per player | Per 10-round game (8 players) | Games per month in 5 GB |
| --- | --- | --- | --- |
| stills-only | ~120 KB | ~10 MB | **~530** |
| audio + stills | ~280 KB | ~22 MB | **~220** |

Storage for all 136 questions: **~38 MB**.

**5469 MB in `pipeline/manifest.json` is AnimeThemes-to-Actions transfer, not Supabase
egress.** Do not confuse the two; it caused a scare once already.

Difficulty tier 1 holds only **13** questions, so a 20-round room restricted to
difficulty 1 correctly fails with `INSUFFICIENT_CONTENT`. That is intended behaviour, not
a bug.

---

## 10. Verified vs unverified - be honest about this

### Proven behaviourally against the live database

- `round_count=5` persists and produces **exactly 5 rounds** (this was B-27: `create_room`
  validated three settings then inserted none of them, leaving every room on defaults).
- `audio_enabled=false` persists.
- `get_current_round` returns ordinal 1 with 3 stills and **neither poster nor audio**.
- Zero residue after the test transaction rolled back.
- `clip_key` is absent from every table.
- `ingest_question` v1 accepted a real payload including CJK titles.
- uuid determinism; bucket config; all policies.

### Never executed even once

Storage upload. `ingest_question` over HTTP. The retry/backoff ladder. Any frontend code.
Any real egress measurement. OCR against a stylised anime logo.

---

## 11. Reference

- Supabase project ref: **`mxkqivivqultfuattuin`**
- GitHub repo: **`Sayandeep1013/Rein-Bot`**
- Pages URL: `https://sayandeep1013.github.io/Rein-Bot/`
- `.env.local` contains **only** `SUPABASE_ACCESS_TOKEN`
- GitHub Actions secret `SUPABASE_SERVICE_ROLE_KEY` is set (the user added it manually)
- Management API: `POST https://api.supabase.com/v1/projects/{ref}/database/query`
- AnimeThemes GraphQL: `POST https://graphql.animethemes.moe/`
- Video CDN: `https://v.animethemes.moe/{basename}`
- Recent commits: `92e0761` then `c77e239` (migration 0010 + docs) then `b86ca2f`
  (section 5.2 pipeline spec)
- Last green dry run: `32590411786`

### Doc map

| File | Lines | What it is |
| --- | --- | --- |
| `CLAUDE.md` | - | The hard rules. Read it. |
| `doc/HANDOFF.md` | - | This file. |
| `doc/DATA-MODEL.md` | 878 | **Authoritative** for schema, functions, RLS, storage. Section 6.6 is the `get_current_round` contract and the rejected-alternatives argument. |
| `doc/GAME-DESIGN.md` | 887 | Game rules and the curation pipeline. **Section 5.2 is the spec for your next task.** Sections 1.1, 2, 2.1.1 are stale. |
| `doc/BLOCKERS.md` | 741 | Open and resolved blockers. The resolution log at the end covers B-25, B-27, B-27a and **B-28**. |
| `doc/RESEARCH.md` | 1275 | Source research. Section 4.10 is the frame-quality measurements. Section 4.7 egress needs updating. |
| `doc/ARCHITECTURE.md` | - | System shape. Asset flow is stale. |
| `doc/PROGRESS.md` | 513 | Dated history. **You must append to this.** |
| `doc/SEED-LIST.md` | - | The hand-authored top-50 anime list. |
| `supabase/migrations/README.md` | - | Apply mechanism and encoding hazards. |

Migration `supabase/migrations/20260823000010_still_assets.sql` (~605 lines) is the best
single artefact to read for why the content model looks the way it does. It contains a
guard DO-block that refuses to run if `question_bank` or the bucket is non-empty, which
turns "ran this too late" into a loud failure rather than silent divergence.
