# Blockers Log

Running list of things that could not be completed when first attempted, so they
can be retried rather than silently dropped. Entries move to **Resolved** once
cleared.

## Open

### Triage index — added 2026-08-22

`## Open` below is a chronological log, not a to-do list: some entries are closed but
never moved, and others are permanent constraints that will never clear. Counting the
headings therefore overstates how much is outstanding. The real split:

| | Entries | Meaning |
| --- | --- | --- |
| **Actionable — genuinely blocking** | **B-11** (item 2 only), **B-13**, **B-16**, **B-28** | Needs work or a decision before launch. |
| **Needs one verification step** | **B-19** | Mitigated already; only needs an opencode restart to confirm. |
| **Permanent constraints — not clearable** | B-9, B-10 | Provider behaviour. Keep for reference; never "fix". |
| **Closed, left in place** | B-4, B-14, B-15, B-20, B-21, B-25, B-26, B-27, **B-29** | Resolved or decided; retained here for the reasoning trail. |

So the honest count is **four actionable items**, and as of 2026-08-23 **none of them is waiting on the user**: B-21 was resolved on 2026-08-22 once the dashboard showed 0% egress, and B-25 was decided on 2026-08-23 (three progressive stills, audio optional per room, no video anywhere). B-27 was opened and resolved the same day.

**B-28 is now the single riskiest open item**, and it moved from "unverified premise" through
*partially measured* and **measured insufficient** to **rule chosen, not yet shipped**. Two
things changed on 2026-08-23. First, a re-eyeball of the suspect pool found **three of five
labels were wrong** — including one frame previously written off as an "uncatchable leak" that
is simply clean — so the ground truth is **4 positives, 37 clean**, and the rule that was one
step from production had been fitted to bad labels. Second, with corrected labels the
**glyph-size hypothesis is falsified**: the tallest token in 16,038 is a hallucination on a hair
curve in a clean frame. The replacement is a **two-feature union** — typographic coherence plus a
confidence-free count of large boxes — measured at **4 of 4 known-bad caught, 0 missed, 0
promoted, 5 clean frames lost, yield intact at 3 stills per theme**. It is not yet implemented in
the pipeline, and runs 3/4 still ship 2 confirmed leaks, so B-28 stays open; what remains is a
code change plus eyeballing the 7 frames the new rule promotes. **B-29** was opened and closed
the same day (poster key derivable from the still keys a player already holds — migration 0011).

The single hardest blocker remains **B-11 item 2** — the hand-built seed list of titles.
It gates the entire curation pipeline, no amount of engineering removes it, and it is the
one item that needs the user's own taste rather than a decision I can make.

### B-11 — Game design partially decided; secondary decisions still open
- **Status 2026-08-21:** The four load-bearing decisions are **made** and recorded
  in `doc/GAME-DESIGN.md` §1: muted-then-revealed **video**, **free-text fuzzy**
  answers, **realtime multiplayer rooms**, **curated pool**. `doc/GAME-DESIGN.md` is
  written.
- **Still open** (`doc/GAME-DESIGN.md` §8), in blocking order:
  1. ~~**Media delivery — Option A (hot-link) vs Option B (preprocess).**~~
     **DECIDED 2026-08-22: Option B, preprocessed into Supabase Storage, clips
     re-encoded to ~1 MB.** Option A leaks the answer through the filename
     (`KimiSen-OP1-NCBD1080.webm`), so B was close to forced. The storage target
     changed from R2 to Supabase Storage when the stack was mandated to
     Supabase (with GitHub Pages serving the static frontend); see B-13. No longer
blocks `doc/ARCHITECTURE.md`.
  2. **Curation source** — hand-built seed list of 100–500 titles the group knows,
     vs a public popularity list. AniList is unavailable for this (its terms
     prohibit mass collection). *Blocks the curation pipeline.*
  3. Transcode location — GitHub Actions assumed; see B-12.
  4. Season-lenient matches: full or partial credit.
  5. Streak multiplier: recommend no.
  6. ~~Round/game length — 20 s / 10 rounds assumed.~~
     **DECIDED 2026-08-22: round count is player-selectable 3–20 at room creation,
     ~28 s per round (20 s clip + 8 s reveal).** Replaces the hardcoded 10-round
     assumption throughout. Consequence worth keeping visible: total wall-clock is
     `rounds × 28 s` → 84 s / 280 s / **560 s** at 3 / 10 / 20 rounds, which exceeds
     the Edge Function 150 s ceiling above ~5 rounds and therefore **rules out any
     single-invocation game loop**. See `doc/ARCHITECTURE.md` §7.
  7. Persistence — leaderboard or match history? The only item that could
     reintroduce a datastore question.
  8. Mobile or desktop first — layout only.
  9. **Difficulty tiering — must be computed, not fetched.** The user asked for a
     difficulty meter "if the api provides it". Live introspection of the AnimeThemes
     `Anime` type confirms it provides **no difficulty and no popularity field** of any
     kind, so difficulty has to be derived locally at curation time and stored. Schema
     support exists (`doc/DATA-MODEL.md` §5); the **weighting formula is deliberately
     unspecified** pending playtesting. Does not block the schema, which commits only
     to a stored, filterable, recomputable integer.
- **Impact:** Items 1 and 6 are now **decided**, and item 9 is scoped. Item 2 still
  blocks the curation pipeline and is the one genuine blocker left in this entry.
  Items 3–8 do not block writing; they can be defaulted and revisited. Item 3 is
  now settled by B-12 below.

### B-9 — AnimeThemes CDN sends no CORS headers
- **What:** Live requests to `v.animethemes.moe` and `a.animethemes.moe` with an
  `Origin` header returned **no `Access-Control-Allow-Origin`** at all.
- **Impact:** **Moderate, and it constrains game design.** Plain `<audio>` /
  `<video>` playback is unaffected. But `fetch()` on the bytes,
  `crossorigin="anonymous"`, canvas frame extraction, and WebAudio
  `decodeAudioData` are all blocked. Any blurred-frame-reveal or waveform-visualiser
  mode needs curation-time preprocessing into our own Supabase Storage bucket.
- **How to clear:** Not clearable — it is their server's behaviour, not a gap in
  our knowledge. Treat as a fixed design constraint. Recorded in `doc/RESEARCH.md`
  §4.6. Decide the affected game modes accordingly.

### B-10 — No robots/fair-use policy found for the AnimeThemes API or CDN
- **What:** The site ToS has no scraping, hot-linking or automation clause, and no
  separate API fair-use policy was found.
- **Why it matters:** Reduced by the Option B decision. We no longer hot-link their
  CDN at play time — each source video is fetched **once at curation time** and
  re-encoded into our own bucket. Their reserved right to disable content
  "burdensome to our systems" without notice therefore applies to a one-off
  ~500-file crawl, not to per-round traffic.
- **How to clear:** Ask in the AnimeThemes Discord `#api` channel what request
  volume they consider polite for a one-time curation crawl, and whether attribution
  is expected.
- **Impact:** Low. Curation is a single bounded pass (~500 files), rate-limitable
  and resumable. Play-time traffic never touches their infrastructure.

### B-4 — Two trace.moe details still unverified · NO LONGER LOAD-BEARING
- **What:** (a) exact rate-limit response header names; (b) how an `x-trace-key`
  is obtained.
- **Status change 2026-08-21:** trace.moe has been removed from the runtime design
  entirely (`doc/RESEARCH.md` §6). These two gaps now affect only the optional
  curation-time labelling path, which the current design does not require.
- **Impact:** Effectively none. Retain the entry only so the gap is not
  rediscovered later as if it were new.

### B-13 — Supabase behaviour on **egress** overage (Free) not verified
- **What:** Free gives **5 GB uncached + 5 GB cached** egress, pooled across
  *"Database, Auth, Storage, Edge Functions, Realtime and Log Drains"*. What
  actually happens on exceeding it — throttle, hard block, or forced upgrade — was
  not found in the docs. Verified by contrast: **database** overage causes
  read-only mode (*"your database can go into read-only mode which can prevent you
  inserting and deleting data"*). The Vercel half of this no longer applies - the
frontend is on GitHub Pages, whose bandwidth limit is soft (B-15). Historically,
**Vercel** locked the offending feature for
  30 days. Supabase's egress equivalent is unknown.
- **Why it matters:** Media is ~98% of our egress draw, and the ceiling is
  ~62 games/month at the chosen ~1 MB clip size. If overage is a hard block, the
  game dies mid-billing-cycle with no graceful degradation.
- **Search attempted 2026-08-22 — negative result, and honestly characterised:**
  Retrieved *Manage Egress usage* and *Billing FAQ*. Both document **what is
  metered** and **how it is billed**, and neither states Free-plan
  exceeded-quota behaviour within the portion retrievable. Targeted searches for
  spend-cap / restriction wording returned the same two pages.
  **This is not evidence the docs are silent** — both pages truncated past the
  retrieval limit before their closing sections, so the answer may sit in material
  that simply was not read. Recording the distinction so a later reader does not
  mistake a tooling limit for a documentation gap.
- **How to clear:** Read *Manage Egress usage* and *Billing FAQ* to their end
  (browser, or fetch in sections), then the pricing page's Free-plan column; if all
  three are genuinely silent, ask Supabase support and quote the answer here.
- **Impact:** **Moderate.** Does not block writing `doc/ARCHITECTURE.md`, but it is the
  single largest unknown in the chosen stack and must be settled before any public
  launch.

### B-14 - Monetisation is permanently foreclosed - CLOSED 2026-08-22, re-based 2026-08-22
- **Originally:** Vercel Hobby is non-commercial only. Verbatim: *"Hobby teams are
  restricted to non-commercial personal use only. All commercial usage of the platform
  requires either a Pro or Enterprise plan."* And: *"Asking for Donations fall under
  commercial usage."*
- **Resolution:** User confirmed on 2026-08-22 that the project will carry **zero
  monetisation forever** - no Ko-fi, no GitHub Sponsors, no ads, no donate link.
- **Re-based the same day (frontend moved to GitHub Pages).** The Vercel clause no
  longer applies to us at all. GitHub Pages is materially more permissive: it forbids
  only sites *"primarily directed at either facilitating commercial transactions or
  providing commercial software as a service (SaaS)"* - which a free party game is not.
  This blocker was one of the two reasons for the move (`doc/RESEARCH.md` 3.9).
- **Standing constraint (do not rediscover, and do not assume the host change lifted
  it):** monetisation is still foreclosed, now by the **content licence rather than the
  host**. **AnimeThemes' terms forbid commercial use** (`doc/RESEARCH.md` 4.9). Every
  clip in `question_bank` comes from AnimeThemes, so the ban follows the content, not
  the deployment target. Moving hosts again would not unlock it; only dropping
  AnimeThemes as the content source would, and that would end the project.
- **Impact:** None as a hosting risk. Retained as a permanent product constraint whose
  source is now upstream and unavoidable.

### B-15 - Vercel Hobby function overage locks the feature for 30 days - CLOSED 2026-08-22 (moot)
- **What:** Hobby had **no overage billing**. Exceeding a limit locked that feature for
  **30 days** (Web Analytics after 7). Relevant ceilings were 1,000,000 function
  invocations, Fast Data Transfer up to 100 GB, Fast Origin Transfer 10 GB, Active CPU
  4 CPU-hrs, Provisioned Memory 360 GB-hrs.
- **Resolution: moot.** The frontend moved to **GitHub Pages** on 2026-08-22
  (`doc/RESEARCH.md` 3.9). There are no functions to lock, because there is no Vercel.
  The design had already refused to put media or game logic behind Vercel functions, so
  nothing was lost in the move.
- **What replaces it, and it is better:** Pages' bandwidth ceiling is **100 GB/month and
  explicitly a *soft* limit**. Over-quota behaviour is verbatim *"we may not be able to
  serve your site, or you may receive a polite email from GitHub Support suggesting
  strategies for reducing your site's impact"* - a conversation, not a 30-day lockout.
  Pages also serves **no video** (clips come from Supabase Storage), so the site itself
  is well under 1 MB and the bandwidth limit is not the binding constraint. **Supabase
  egress (B-13) is the only real media budget.**
- **Impact:** None. Closed as moot.

### B-16 — Supabase 7-day inactivity pause: mitigation is documented but soft
- **What:** Free projects pause after 7 days of inactivity. The docs indicate a few
  database requests per day prevents it, a warning email arrives ~1 week ahead, and
  one-click restore within 90 days preserves data.
- **Why it matters:** `doc/RESEARCH.md` §3.5 originally called this *"disqualifying"*.
  It is now downgraded to manageable via a daily keepalive ping (GitHub Actions cron
  on a public repo, free). But the docs hedge — *"typically … is enough"* — so the
  mitigation is not contractually guaranteed.
- **How to clear:** Run the keepalive for a full month and confirm no pause. Only
  provable empirically.
- **Impact:** Low but non-zero. Failure mode is recoverable (restore preserves
  data), just disruptive.

### B-20 — AnimeThemes `nc` does NOT mean spoiler-free — ANSWERED 2026-08-22, and the answer is bad
- **ANSWERED 2026-08-22 by looking at real output.** Ran `curate` as a dry run over the
  first 10 themes (run `32590411786`, `ok=0 skipped=10 failed=0`) and inspected the 2x2
  thumbnail tiles. **Five of the ten clips show the anime's own title logo, in Latin
  script, inside the 20-second window:**

  | Clip | Leak |
  | --- | --- |
  | `ShingekiNoKyojin-OP1` | title logo + romanised `attack on titan`, 2 of 4 sampled frames |
  | `ShingekiNoKyojin-OP2` | none seen |
  | `ShingekiNoKyojin-ED1` | none seen |
  | `ShingekiNoKyojin-ED2` | none seen |
  | `DeathNote-OP1` | `DEATH NOTE` logo, 2 of 4 |
  | `DeathNote-OP2` | `DEATH NOTE` logo, 1 of 4 |
  | `DeathNote-ED1` | none seen |
  | `DeathNote-ED2` | none seen |
  | `FullmetalAlchemistBrotherhood-OP1` | title logo + `FULLMETAL ALCHEMIST`, 1 of 4 |
  | `FullmetalAlchemistBrotherhood-OP2` | title logo + `FULLMETAL ALCHEMIST`, 1 of 4 |

  **5 of 6 openings leak. 0 of 4 endings leak.** All ten passed the
  `nc: true, subbed: false, overlap: NONE` filter, so the filter is not defective - the
  assumption behind it was.

- **Why the filter could never have caught this.** `nc` means *creditless*: it strips the
  **staff credit text** overlaid on the sequence. The **show's own title card is part of
  the animation**, not an overlay, so a creditless master keeps it by design. There was
  never a flag that would have excluded it. The romanised line under the logo
  (`attack on titan`, `FULLMETAL ALCHEMIST`) is likewise baked into the art, which is why
  `subbed: false` does not help either - that flag is about translation subtitles.

- **The measurement understates the problem.** The tile samples **4 frames out of roughly
  600**. "None seen" therefore means "no title at these four instants", not "clean". A
  logo held for two seconds between sample points is invisible to this check, so the true
  leak rate is **at least** 50% and probably higher. Do not treat the four "none seen"
  rows as cleared.

- **It also lands squarely in our window.** The pipeline cuts `-ss 5 -t 20`, i.e. source
  seconds 5-25, and anime openings conventionally place the title card in the first ~15
  seconds. The window was chosen to skip the cold open; it happens to centre the logo.

- **Consequence:** the premise that "the filters are the only thing standing between the
  catalogue and that outcome" is now settled - **they are not sufficient**, and no
  catalogue metadata would make them sufficient. Any fix has to act on the pixels or on
  the audio, which is a **product decision**, not a filter tweak. Tracked as **B-25**.
- **What:** The variant filter chain in `doc/GAME-DESIGN.md` §5 selects clips by
  `nc: true`, `subbed: false`, `overlap: NONE`. The **field names and filter
  behaviour are verified live**; what is **not** verified is whether `nc: false`
  reliably implies visible on-screen credits, and whether `overlap: NONE` reliably
  implies no episode footage bleeding over the sequence. Both are being trusted as
  proxies for "this frame does not spoil the answer".
- **Why it matters:** A single mislabelled clip that burns the anime's title on
  screen turns a round into a free point for whoever reads fastest. The filters are
  the *only* thing standing between the catalogue and that outcome — there is no
  human review step in the pipeline as designed.
- **Second unknown, same check — ANSWERED 2026-08-22 for the current scope:** how many
  titles actually **survive** the full chain. `nc: true` alone discards a large share of
  entries, and the survivors skew to the largest 1080p BD rips — the `nc: true` median is
  **~46.7 MB** against a **26.1 MB** median (mean 31.9 MB) across an *unfiltered* 100-video
  sample, so credit-free really is the heavier population, by roughly **1.8x**.
  `pipeline/manifest.json` has now run the real chain over the seed list: **46 of 50 anime
  survive, yielding 136 themes** at 5469 MB of source (~40 MB/theme, consistent with the
  heavier-population finding). Four anime were lost outright, three of them films. So the
  filter is survivable at this scale — but note the pool is 136, not the ~500 assumed in
  §5, because the cap of 4 themes per anime was chosen deliberately for answer variety.
  Difficulty tier 1 holds only 13 questions, which is the thinning this entry predicted,
  accepted by the user and deferred to playtest.
- **How to clear:** Step (2) is done, see above. Step (1) — eyeball frames for burned-in
  text — now has a mechanism rather than a manual chore: `.github/workflows/curate.yml`
  emits, for every clip it processes, a 2x2 tile of frames sampled every 5 s **from the
  finished clip** rather than the source, so the tiles show exactly what a player sees. A
  single frame was rejected as insufficient because a title card may only be up briefly.
  Run the workflow with `dry_run: true` and inspect the `curate-*` artifact; nothing is
  written to the database until the tiles look clean.
- **Impact:** **Moderate.** Failure mode is a degraded game rather than a broken one,
  but it is discovered at play time, in front of players, which is the worst place.
  The `dry_run` default of **true** exists specifically so this is discovered in an
  artifact instead.

### B-25 — How to stop the clip showing the answer — **DECIDED 2026-08-23**
- **What:** following from B-20, at least half of all opening clips render the anime's
  title on screen during the played window. A round in which the answer is legible is not
  a round. Something must change about what the player is shown.
- **Decision (owner, 2026-08-23):** **no video is stored or served, ever.** A round shows
  **three still frames**, revealed progressively, and **audio is optional per room**:

  | Mode | While guessing | On reveal |
  | --- | --- | --- |
  | **Frames only** | 3 stills at 0 s / ~7 s / ~14 s | poster + title |
  | **Audio + frames** | the same 3 stills, plus the song | poster + title |

  The host chooses with an audio toggle at room creation. The mode is fixed for the room:
  it must not change mid-game, or scores from different rounds are not comparable.
- **Why stills succeed where every option below failed:** a video window is **contiguous**,
  so if the title card sits at 0:12 there is no way to exclude it without losing the window.
  Stills are chosen **independently** — sample ~50 candidate frames across the whole
  sequence, OCR every one, discard every frame carrying text, keep the cleanest three. The
  constraint that made video unfixable simply does not apply to frames.
- **The reveal gets the leak for free:** the frames that spoil a round — the ones showing
  the title card — are the *ideal* reveal image once the answer is known. The title card
  is a liability while guessing and an asset immediately afterwards.
- **Cost correction, recorded because the first version of this entry was wrong:** an
  earlier draft claimed audio-only was ~13x cheaper and would turn ~30 games/month into
  ~390. That was wrong as written: it also assumed **video on reveal**, which costs the full
  2.09 MB and cancels the whole saving. The honest arithmetic under the decision:

  | Mode | Per round per player | Per 4p / 20-round game | Games/month on 5 GB |
  | --- | --- | --- | --- |
  | Frames only | ~120 KB | ~10 MB | **~530** |
  | Audio + frames | ~280 KB | ~22 MB | **~220** |
  | *(rejected)* always video on reveal | 2.25 MB | ~180 MB | ~27 |

  Storage for all 136 questions drops from ~284 MB of video to about **38 MB**.
- **One download still produces everything.** The ~40 MB source fetch is the expensive part
  and is paid once per theme, so audio, candidate frames and the poster all come out of the
  same download. Adding stills did not add a network cost to curation.
- **What this costs instead:** the frame filtering is real engineering — rejecting text
  needs `tesseract`, and rejecting *useless* frames (near-black, cross-fades, motion blur,
  near-duplicates) needs a detail heuristic on top. A question that yields too few clean
  frames must be rejectable at ingest the way `NO_TITLES` already is.
- **Superseded options,** kept because the reasoning is why the decision looks like this:

  | Option | Effect | Cost |
  | --- | --- | --- |
  | **Audio only while guessing, video on reveal** | Removes the leak completely, for every clip, permanently | Changes the game from visual to aural |
  | **OCR a clean window per clip** | Keeps video; automatable with `tesseract` in CI | Fails where no clean 20 s window exists, so it needs a fallback anyway |
  | **Endings instead of openings** | 0 of 4 leaked in the sample | Halves the pool, and endings are far less recognisable |
  | **Shift the cut later** | Trivial to implement | Title timing varies per show, and many sequences show the logo again at the end |
  | **Mask or crop the logo region** | Keeps video | Logo position varies per show; not automatable |
  | **Human review of all 136** | Highest quality | 136 manual reviews, and it does not scale to a larger pool |

- **Every row above assumed video had to survive in some form.** Dropping video did not
  resolve that trade, it dissolved it.

### B-26 — Clip size runs closer to the 5 MB bucket cap than assumed — **CLOSED 2026-08-23 (moot)**
- **What:** measured sizes across the 10-clip dry run: mean **2,189,494 bytes (2.09 MB)**,
  min **985,327**, max **4,924,415 (4.70 MB)**. The bucket cap set in migration 0009 is
  **5,242,880**. The largest clip sits at **93.9% of the cap**, with 318 KB of headroom.
- **Closed because B-25 removed video entirely.** The largest object a question now owns is
  the ~160 KB audio track, and stills are ~30 KB each, so against the 5,242,880-byte cap
  the worst case is roughly **3%** utilisation. The unbounded-bitrate hazard cannot fire
  because nothing encodes video any more.
- **The cap stays as written.** It costs nothing and is now a generous guard rather than a
  live constraint. What *must* change is `allowed_mime_types`, which migration 0009 pinned
  to `{video/webm}`: audio and JPEG uploads would be rejected outright. Widening it is
  folded into migration 0010, and it is a genuine prerequisite — without it the new
  pipeline fails on its first upload.

### B-27 — `create_room` never persists the host's settings, so `advance_round` reads defaults — OPEN, fix drafted
- **What:** `create_room` validates `round_count`, `difficulty_min` and `difficulty_max`
  into local variables, then its INSERT writes **only `code`** (migration 0005, L292). The
  three settings are used once to pre-select questions and then discarded. `round_count` is
  written **nowhere** in any migration, yet `advance_round` reads it back off the room row
  at L535 to decide when the game is over — so it always reads the column default, 10.
- **Consequences, by what the host picks:**

  | Host picks | Behaviour |
  | --- | --- |
  | **10** (the default) | correct, by coincidence |
  | **3—9** | `v_round > v_count` never trips at the real final round. Rounds past the last have no row, so the round stamp updates nothing and players sit through empty rounds until round 11 |
  | **11—20** | `GAME_OVER` fires at round 11 and every remaining round is silently discarded |

- **Why it went unnoticed:** the design default and the column default are both 10, so the
  only round count anyone would exercise casually is the one that happens to work. Neither
  value is wrong in isolation; the write that should connect them is missing.
- **Why it blocks B-25 rather than merely coexisting with it:** the audio toggle *is* a room
  setting. Clients read `audio_enabled` off the room row to decide whether to fetch the audio
  object at all. Shipping the toggle through a path that drops settings would make it a
  silent no-op — frames-only rooms would still pay for audio, which is exactly the egress
  guarantee the decision was chosen for.
- **Fix:** write the columns in `create_room`'s INSERT rather than adding a follow-up UPDATE,
  so the room row is correct atomically and cannot be observed half-configured. Being
  reviewed together with the asset-key design before it goes into migration 0010.

### B-21 — Free-tier egress is org-shared, and consumption cannot be read — **RESOLVED 2026-08-22**
- ~~**What:**~~ **What was:** `doc/ARCHITECTURE.md` §10 originally budgeted the full **5 GB** egress
  allowance to ReIN Bot. It is billed at the **organization** level, and org
  `ujnsnnblxvyhirfjklik` ("Personal Projects", plan `free`) contains a **second
  active project, `Mubitracker`** (`deslckxkuvbfugdxibdn`). Both are
  `ACTIVE_HEALTHY`; Free permits exactly 2 active projects and both slots are used.
  §10 has been corrected, but the corrected formula now has an **unknown numerator**.
- ~~**Why it matters:**~~ **Why it mattered:** Media is ~98% of this game's egress, so egress is the binding
  constraint on how many games per month are playable. A busy co-tenant can halve
  capacity — at 20 rounds that is the difference between ~31 and ~15 games/month.
  Worse, restriction is enforced org-wide: **Mubitracker exhausting the quota takes
  ReIN Bot offline**, and nothing in ReIN Bot's own design can prevent that.
- ~~**Blocked, not merely unattempted:**~~ The API endpoints still return 404, so the figure was read by a human:
  **user reports 0% egress consumed (2026-08-22)** — Mubitracker has used effectively
  nothing, so the games/month formula runs at the **full 5 GB numerator** (the
  "@ full 5 GB" column of the §10.2 table is the live number, not the optimistic one).
- **Residual risk, accepted for launch:** consumption is a point-in-time reading, not a
  contract. Mubitracker can still start consuming later; org-wide restriction means it
  could still take ReIN Bot offline. The structural fix (**move ReIN Bot to its own
  organization**) remains recommended pre-launch but no longer blocks anything. The two
  inferred claims in §10.2 (org-level aggregation; second org = second allowance) stay
  unverified and moot while co-tenant usage is zero.
- **Impact:** ~~High on capacity planning~~ **Closed.** Default round count may use the full-allowance column.

### B-19 — Supabase MCP was bound to the wrong project
- **What:** The globally-configured Supabase MCP server pointed at
  `--project-ref=deslckxkuvbfugdxibdn` (**Mubitracker**), so every MCP call in this
  session read a different project's database. Not a credentials problem — same
  account, wrong project. It was caught because `supabase_get_project_url` returned an
  unfamiliar ref, and because the "empty" schema it reported contained tables
  (`media_rejected`, `tmdb_rate_limit`) that this project has never had.
- **Why it matters:** Verification silently ran against the wrong database. Had this
  gone unnoticed, "the schema is empty" and any later migration would have been true
  of, and applied to, the wrong project.
- **Mitigation applied 2026-08-22:** verification was completed **without the MCP**,
  via the Management API over HTTPS (`/v1/projects/{ref}/database/query`), which needs
  no config change and no restart. Separately, project-local `opencode.json` now
  overrides the `supabase` MCP key with the correct ref and `--read-only`. `CLAUDE.md`
  forbids editing laptop-wide config, so the global entry was left untouched.
- **How to clear:** **Restart opencode**, then confirm `supabase_get_project_url`
  returns `https://mxkqivivqultfuattuin.supabase.co`. Until that check passes, treat
  MCP output as untrusted and prefer the Management API.
- **Open sub-question:** whether project-local `mcp` config *merges with* or *replaces*
  the global entry of the same key in opencode 1.17.8 is assumed, not verified. The
  same-key override was chosen specifically so that either behaviour yields one
  correctly-bound server rather than two conflicting ones.
- **Impact:** **Was high, now low.** No writes were ever issued against Mubitracker.

## Resolved

### B-24 — Nothing transitioned `lobby → playing`, so no game could ever start · RESOLVED 2026-08-22 (found and fixed in the same pass)
- **What:** a project-wide grep across all five documents found **no `start_game` and no
  `lobby → playing` transition of any kind.** `rooms.state` defaults to `'lobby'`,
  `current_round` defaults to `0`, and `deadline` is `NULL` in the lobby. The only function
  that could plausibly have started a game was `advance_round`, whose guard is
  `state = 'playing' and now() >= deadline`.
- **Why it matters:** `now() >= NULL` evaluates to `NULL`, not `false`, so the guarded
  `UPDATE` matched **zero rows forever**. No client poll and no `pg_cron` sweep could have
  broken the deadlock. The room would have sat in the lobby permanently — a total failure of
  the core loop, with no error raised anywhere, because a conditional `UPDATE` matching
  nothing is a perfectly successful statement.
- **Why the first review pass missed it:** every section was locally correct. §4.1's
  defaults are correct for a lobby, §6.4's guard is correct for an in-progress game, and
  §6.3's `create_room` is correct in leaving the room in the lobby. The defect lived only in
  the *absence* of a function, and absences do not appear when reviewing what is written.
  It surfaced only because fixing B-23 required asking "who writes `started_at` for round
  **1**?" — a question B-23 itself never forced.
- **How it was cleared:** added `doc/DATA-MODEL.md` §6.5 `start_game(p_room_id uuid)` — guard
  `state = 'lobby'`, writes `state = 'playing'`, `current_round = 1`,
  `deadline = now() + round_duration`, `returning deadline into v_deadline`,
  `if not found then return; end if;`, then stamps round ordinal 1 and broadcasts
  `ROUND_START`.
- **Load-bearing detail:** `start_game` is a separate function rather than a branch inside
  `advance_round` because the two need *different* guards, and under B-17's argument only a
  guard on a column the same statement mutates is safe against concurrent callers.
  `state = 'lobby' → 'playing'` satisfies that; `state = 'playing'` would not, which is
  precisely why `advance_round` has to guard on `deadline` instead. The same property makes
  `start_game` double-click-safe for the host at no extra cost.
- **Impact:** **Was critical, now none.** Same severity as B-23 and the same discovery
  window: trivially cheap in design, and after implementation it presents as "the start
  button does nothing", which points suspicion at the client rather than at a `NULL`
  comparison in a `WHERE` clause.

### B-23 — `rounds.started_at` / `ends_at` were never written, so grading rejected everything · RESOLVED 2026-08-22 (fixed in-spec)
- **What:** `doc/DATA-MODEL.md` §4.3 declared `rounds.started_at` and `rounds.ends_at` as
  **nullable**, and **no function in §6 ever wrote them.** `advance_round` (§6.4) updated
  only `rooms` — `current_round` and `deadline`. `create_room` inserted the round rows with
  their questions chosen up front, timestamps unset. Both columns therefore stayed `NULL`
  for the life of the game.
- **Why it mattered:** `grade_guess` step 2 rejects a guess "if `now()` is outside
  `[started_at, ends_at]`". Against `NULL` that comparison is never true, so **every guess
  in every round was rejected.** Not a degradation — a game that could not be played. It was
  invisible in review because each document was locally coherent: the columns existed, the
  grading rule was correct, the advance was correct. Only the *join* between them was
  missing.
- **How it was cleared:** `advance_round` (§6.4) rewritten to
  `returning current_round, deadline, round_count into v_round, v_deadline, v_count`,
  followed by an `if not found then return; end if;` gate, a game-over branch
  (`state = 'over'`, `deadline = null`), and then
  `update public.rounds set started_at = now(), ends_at = v_deadline where room_id = … and ordinal = v_round`.
  Round 1 is stamped by `start_game` (§6.5, see B-24). The two warning blockquotes in
  `doc/DATA-MODEL.md` §4.3 and `doc/ARCHITECTURE.md` §7 were replaced with resolved notes that keep
  the failure mode on record.
- **Two load-bearing properties of the fix:**
  1. **The stamp is gated.** Eight players may call `advance_round` at once and exactly one
     affects a row; an ungated stamp would let the seven losers re-write
     `started_at = now()`, sliding the window forward on every call — the same class of bug
     B-17 closed, reintroduced one statement later. The reveal broadcast sits behind the
     same gate, or one transition emits eight reveals. The `pg_cron` liveness sweep calls
     this function and so inherits both properties.
  2. **`ends_at` reuses `v_deadline` instead of recomputing `now() + round_duration`.** Two
     evaluations differ by the function's own runtime. That is enough for a guess landing in
     the sliver between them to be graded against a window that disagrees with the one
     published to clients.
- **Related defect, resolved with it:** the two-source-of-truth problem. `rooms.deadline` and
  `rounds.ends_at` both encode when the round ends, and **neither can be removed** —
  `rooms.deadline` must stay because B-17's idempotency requires the guard to test a column
  the advancing `UPDATE` itself mutates, and `rounds.ends_at` is what grading reads without
  a second lookup. The duplication is now governed by a stated invariant in §4.3
  (`rounds.ends_at = rooms.deadline` for the current round) which both writers satisfy
  structurally, by construction, rather than by discipline.
- **Impact:** **Was critical, now none.** Cheap to fix in design; after implementation it
  would have presented as "no guess is ever accepted", pointing suspicion at grading and
  normalisation rather than at round advancement.

### B-22 — The scoring model contradicted itself: winner-takes-all vs speed bonus · RESOLVED 2026-08-22 (user decision)
- **Original concern:** `doc/DATA-MODEL.md` §6.2 step 7's exception branch wrote **`points = 0`**
  for a guess that was correct but not first — winner-takes-all — while `doc/GAME-DESIGN.md`
  §6.2 specified **100 for correct plus a speed bonus decaying 100 → 0**, so every correct
  guess scored 100–200. Neither was marked superseded; both read as authoritative. Two
  different games, and an implementer would have picked one branch and silently violated
  the other document.
- **Decision:** **winner-takes-all.** Only the first correct guess in a round scores; every
  other guess scores `0`, correct or not. The winner's total still varies with speed — 100
  plus a bonus decaying linearly 100 → 0 across the round window, so 200 for a
  first-second win and 100 for a last-second one.
- **Coupled decision, also settled:** **full credit for every correct tier.** Exact, near,
  season-lenient and prefix all score identically, so the points expression carries **no
  per-tier factor**. This closes the "season-lenient: full or partial credit" open item in
  `doc/DATA-MODEL.md` §9 at the same time, which was the whole point of deciding them together.
- **Note on the recommendation, recorded deliberately:** I argued for
  everyone-correct-scores, on the grounds that §6.2's own reasoning rejected a streak
  multiplier for making a game "unwinnable for everyone else by round 6", and
  winner-takes-all fails that same test harder. The user chose winner-takes-all anyway,
  which is consistent with the originally stated loop — "the one who gets the correct
  fastest wins". Kept here because the rejected reasoning is still sound, and a future
  reader who sees the lead problem in playtesting should know it was foreseen rather than
  missed.
- **Consequence now documented rather than merely decided:** under this model
  `one_winner_per_round` stops being bookkeeping and becomes **the scoring rule itself** —
  the unique index is the only thing preventing two players from being paid for the same
  round. That raises the stakes on `grade_guess`'s exception branch and is a second,
  independent reason `ON CONFLICT DO NOTHING` is wrong there.
- **Escape hatch if it plays badly:** consolation points for later correct guesses is a
  one-line change to the exception branch's `points` value. No schema change, no migration,
  no change to the unique index.
- **Applied at:** `doc/GAME-DESIGN.md` §6.2 (rewritten), `doc/DATA-MODEL.md` §6.2 (contradiction
  blockquote replaced by the decision), `doc/DATA-MODEL.md` §9 (two rows struck).

### B-18 — pg_graphql as a second read path to the answer column · RESOLVED 2026-08-22 (moot)
- **Original concern:** §4.4.1 gated answer disclosure through **PostgREST** via
  revoke-table-then-grant-columns. Supabase also exposes **pg_graphql** (lints
  `0026_pg_graphql_anon_table_exposed` / `0027_pg_graphql_authenticated_table_exposed`
  exist precisely because tables can be reachable over GraphQL). Whether column-level
  grants were honoured identically by pg_graphql's resolver was unknown.
- **Resolved twice over, independently:**
  1. **Empirically.** `pg_graphql` was queried against the live project and is
     **not installed** — it appears in `pg_available_extensions` with no
     `installed_version`. There is no second endpoint to leak through, so the premise
     of the blocker does not hold on this project.
  2. **By scope change.** The user directed on 2026-08-22 that the game carries **no
     secrecy layer** — *"if the players want to cheat they will"*. The column-grant
     scheme it threatened is itself **superseded** (`doc/GAME-DESIGN.md` §4.4.1). A second
     read path to a column that is no longer treated as secret is not a vulnerability.
- **Standing note:** should `pg_graphql` ever be enabled, re-read this entry first.
  The empirical half of the resolution is a fact about *current configuration*, not a
  property of the design, and configuration changes.
- **Not a regression.** It was never in scope of the original B-17 claim; it was found
  *because* B-17 was being verified properly.

### B-17 — Postgres-as-authority design · RESOLVED 2026-08-22
- **What:** The server-authoritative design — `SECURITY DEFINER` functions stamping
  `submitted_at = now()`, answers withheld from clients, round progression via
  idempotent conditional `UPDATE` backed by a `pg_cron` sweep, and broadcasts emitted
  from Postgres triggers over Realtime private channels — was authored in-session and
  **not independently reviewed**. Two Oracle consultations returned empty and were
  abandoned rather than retried; delegation failed across 7 models.
- **How it was cleared:** Verified from primary docs and production code precedent,
  **not** empirically tested — the user declined live testing against the connected
  Supabase MCP (2026-08-22) to keep the project documentation-only per `CLAUDE.md`.
  All four sub-claims are now settled:

  | Sub-claim | Outcome |
  |---|---|
  | Answer withheld via "no `SELECT` grant" | ❌ **WRONG — was a live leak.** Column grants are additive to table grants; Supabase grants `anon`/`authenticated` table-level `SELECT` on `public` by default, so the instruction was a no-op. Corrected to revoke-then-allow-list in `doc/GAME-DESIGN.md` §4.4.1 |
  | `SECURITY DEFINER` safety | ⚠️ **Verified with a required addition.** Needs `SET search_path = ''`; omitting it is a privilege-escalation vector. Documented §4.4.2. Trips Supabase lint `0028` by design — accepted, mitigated in-function |
  | Realtime private channels | ⚠️ **Verified with a missing provisioning step.** Requires disabling "Allow public access" *and* client `private: true`; either omission leaves the channel open. Also: RLS is **join-time, not per-message**, so it cannot time-gate the answer. Documented §4.4.3 |
  | Conditional `UPDATE` round advance | ⚠️ **Verified with a required condition.** `READ COMMITTED` does re-evaluate the `WHERE` clause against the updated row, so the second writer matches 0 rows — **but only because the guard column is one the same `UPDATE` mutates.** Documented `doc/GAME-DESIGN.md` §6.3 |
- **Why the flag paid off:** Not one of the four sub-claims survived review unchanged.
  One was **actively wrong** and would have published every answer through PostgREST;
  the other three were directionally right but each omitted a step that was load-bearing
  for the guarantee it claimed to provide. Flagging this was the highest-value action of
  the session.
- **Primary sources:** PostgreSQL documentation source `doc/src/sgml/mvcc.sgml` §13.2.1
  (retrieved from the `postgres/postgres` tree after the rendered docs page proved
  unreadable — nav chrome exceeded the fetch budget on every attempt, including
  `format=text`); `src/test/regress/sql/init_privs.sql` for column-grant additivity;
  Supabase Realtime authorization guide; production precedent in
  `erikdarlingdata/PerformanceMonitor` and `fastrepl/anarlog`.
- **Impact if wrong:** Was moderate, then low–moderate. The one genuinely dangerous
  sub-claim (answer disclosure) was caught and fixed; the round-advance failure mode
  would only have skipped a round, not corrupted state or leaked answers.
- **Carried forward, not closed:** the pg_graphql exposure surface (lints `0026`/`0027`)
  is a *second* possible read path to the answer column even with PostgREST locked
  down, and was never examined. Tracked as **B-18**.

### B-12 — `ffmpeg` on GitHub-hosted runners · RESOLVED 2026-08-22
Checked the runner-images installed-software list for `ubuntu-latest`. **`ffmpeg` is
NOT preinstalled.** The workflow must add an explicit install step
(`apt-get install -y ffmpeg`, or a pinned static build for reproducibility). That
step runs on the runner, not the user's machine, so the project rule that nothing
installs a background service on the laptop holds either way. Impact confirmed as
very low — it costs one step and ~15 s of job time.

### B-8 — GitHub Actions concurrency on Free · RESOLVED 2026-08-22
GitHub **Free = 20 total concurrent jobs**, of which at most **5** may be macOS.
Confirms CI is unconstrained for this design. Two related findings recorded while
checking:
- **Actions minutes are summed across jobs**, so a 20-way sharded curation matrix
  cuts *wall time* (~240 min → ~12 min, which removes the 6-hour job-timeout risk)
  but does **not** reduce minutes consumed. Only **public-repo** status makes
  standard-runner minutes free — which the project now is.
- Artifacts and Packages **share one 500 MB pool** on Free.

The second half of the original question (GitHub Pages hosting on private repos) is
moot: the frontend is on GitHub Pages (whose limits are verified in
`doc/RESEARCH.md` 3.9), and the repo is public.

### B-7 — Cloudflare Pages free bandwidth · RESOLVED 2026-08-22 (no longer applicable)
Closed as **moot, not answered.** The stack settled on Supabase plus a static host, so
Cloudflare Pages is no longer in the design. Recorded for accuracy: the question was
never resolvable from the Pages *limits* page, and the Workers *"no additional
charges for egress or bandwidth"* line sits inside the **Paid**-plan paragraph, so it
could not be cited for Free. The equivalent GitHub Pages figure **is** confirmed —
**100 GB / month** on GitHub Pages, though a soft limit rather than a hard cap
(see B-15 and doc/RESEARCH.md 3.9).

Note the original rationale in this entry was also **stale**: it claimed all heavy
media came from AnimeThemes' CDN, which the Option B decision had already
superseded.

### B-5 — AniList terms on hot-linking cover art · RESOLVED 2026-08-21
The earlier HTTP 403 did not recur; `docs.anilist.co/guide/terms-of-use` served
normally with a browser user-agent. Terms are recorded in `doc/RESEARCH.md` §5.

The finding **reversed** the earlier plan rather than confirming it: AniList
prohibits "using the AniList API as a backup or data storage service" and
"mass collection of data", which is exactly what §2's "cache aggressively"
recommendation described. Resolved by **dropping AniList from the architecture** —
AnimeThemes already returns romaji/English/native titles, synonyms, year and cover
art, and self-hosts those covers on its own R2 bucket, so the original
hot-linking question is moot.

### B-6 — Durable Objects SQLite storage pricing may have changed · RESOLVED 2026-08-21
Resolved as **not material** rather than by re-reading the page. The question bank
is text-only: a few thousand rows at roughly 300 bytes each is well under 5 MB, so
any plausible free storage allowance accommodates it.

**Superseded 2026-08-22:** Durable Objects are no longer in the design (stack
settled on Supabase), and media **is** now stored by us — preprocessed
clips live in Supabase Storage per the Option B decision. The storage sizing that
matters is tracked in `doc/GAME-DESIGN.md` §3 and B-13, not here.

### B-1 — `.claude/settings.json` could not be written · RESOLVED 2026-08-21
The harness safety classifier was intermittently unavailable, and writes into a
`.claude/` directory are safety-gated. Retried successfully. The file now sets
`defaultMode: acceptEdits`, an explicit `allow` list, `additionalDirectories: []`,
and a `deny` list covering `~/**`, the `C:` / `E:` / `F:` / `G:` / `H:` drives,
and privilege- or machine-scope commands (`sudo`, `reg`, `setx`, `powershell`,
`cmd.exe`, global npm installs, `git config --global`, `gh auth login`, `winget`,
`choco`, `scoop`).

### B-2 — trace.moe API facts unverified · RESOLVED 2026-08-21
Fetched from the rendered docs' underlying markdown (`docs/docs.md`,
`docs/limits.md`, `docs/terms.md`). All endpoints, parameters, response fields,
quota tiers, error codes, the `x-trace-key` header, the 25 MB upload cap, the
300-second preview expiry and the terms of use are recorded in `doc/RESEARCH.md`
§1. Two residual gaps are tracked as **B-4**.

### B-3 — Host provider free-tier limits unverified · RESOLVED 2026-08-21
Read from each provider's own documentation: Cloudflare Workers, Durable Objects,
Pages and R2; Supabase; Neon; GitHub Actions. All numbers and their consequences
are recorded in `doc/RESEARCH.md` §3. Residual gaps were tracked as **B-6**, **B-7**
and **B-8** — all three are now closed or moot.

**Note 2026-08-22:** the Cloudflare half of this research is now historical only.
The stack settled on Supabase + GitHub Pages; those providers' limits were verified
separately and are recorded in `doc/RESEARCH.md` §3.

---

## Note on the "auto mode" interruptions

Several early tool calls failed with
`claude-opus-5[1m] is temporarily unavailable, so auto mode cannot determine the
safety of <Tool>`. To be precise, these were **not** permission denials — the
harness could not reach the classifier that decides whether an unlisted call is
safe, so it failed closed.

Mitigation applied in `.claude/settings.json`: an explicit `permissions.allow`
list. A call that matches an allow rule is pre-authorised and does not need the
classifier at all. The list covers all file operations inside this folder, the
documentation domains this project reads from, and the read-only shell commands
used here. `defaultMode` is set to `acceptEdits` so in-folder file writes proceed
without prompting during unattended runs.

This substantially reduces classifier dependence but cannot eliminate it: a call
that matches neither the allow list nor the deny list still needs classification,
and will still fail if that service is down. If a new capability is needed later,
add it to the `allow` list rather than relying on auto mode to adjudicate it.

---

## Resolution log — 2026-08-23

Migration `20260823000010_still_assets.sql` was applied live to `mxkqivivqultfuattuin`,
schema-verified, and then verified behaviourally. It closes three of these items and opens
one.

### B-25 — IMPLEMENTED

Decided round format is now schema. No video column, no video MIME type, `still_count`
constrained to 2—3, `rooms.audio_enabled` for the host toggle. See
`doc/DATA-MODEL.md` §3.1 and `doc/GAME-DESIGN.md` §3.

### B-27 — RESOLVED

`create_room` validated `round_count` / `difficulty_min` / `difficulty_max` and inserted
none of them. All settings now travel in the same INSERT that generates the room code, so
a room is never observable half-configured. **Proven:** `round_count=5, audio_enabled=false`
→ persisted, exactly 5 rounds created. Full breakage analysis in `doc/DATA-MODEL.md` §6.3.

### B-27a — RESOLVED (found while fixing B-27)

**`rounds.clip_key` leaked unplayed content to every room member.**
`rounds_select_for_members` gates on `is_room_member(room_id)` alone — no
`ordinal <= current_round` predicate — and `create_room` inserts every round up front.
With `grant select on rounds`, any player could read the asset key of every *future* round
during round 1 and fetch it from the public bucket.

No title string leaked, so nothing in the guess-grading path would have caught it. The fix
removes the data rather than guarding it: `clip_key` is dropped from both tables, keys are
computed server-side from `question_bank.asset_slug` (a second uuid, deliberately not `id`,
because `rounds.question_id` *is* client-readable), and delivery moves to
`get_current_round`, which returns one round and strips the poster always and the audio key
in stills-only rooms. Rejected alternatives, and why, in `doc/DATA-MODEL.md` §6.6.
**Proven:** `assets` contained `stills` alone — no `poster`, no `audio`.

### B-28 — OPEN · OCR reliability on stylised anime logos

**The riskiest unverified premise in the pipeline.** Frame selection is now the *only*
thing standing between a title card and the player, since `nc:true` was measured not to
protect the answer at all (B-20: 5/10 clips show the title, all ten `nc:true`). The filter
is tuned aggressively — a false positive costs one frame out of ~60, a false negative ships
the answer.

Anime title logos are the adversarial case for OCR: heavy stylisation, outlines, gradients,
rotation, overlap with artwork. Tesseract may simply not see them.

Cannot be tested locally: `tesseract`, `ffmpeg` and ImageMagick are all absent from this
machine (`convert.exe` on PATH is the Windows filesystem converter, not ImageMagick), and
the rapidocr wheel would be an out-of-project install, so the OCR step is provable only in
CI. Each experiment therefore costs a ~20-40 minute run.

#### Measured 2026-08-23 — run `32605150598`: the premise is half-confirmed, and the failure mode is not the one expected

Run `32605150598` dumped per-frame OCR telemetry for 647 candidates across 12 themes, and
all 36 shipped stills were then viewed by eye. Two findings:

**1. The threshold was wrong, and is now measured.** The original `chars_N` rule is
disproven — junk sums across a frame (p90 = 9, max 34) while a real title card measured 43
chars, so the distributions fully overlap. `chars_70 >= 4` skipped 8 of 10 themes in an
earlier run while still not being safe. The working discriminator is the **longest single
word**: at confidence >= 70 junk peaks at p50 = 2 / p95 = 3, and all 18 frames with
`longest_70 >= 5` were genuine text. Rule is now `longest_word >= 5 @ conf >= 70`
(§5.2.2 of `doc/GAME-DESIGN.md`).

**2. The residual leak is blindness, not mis-tuning — which is why the blocker stays open.**
3 of 36 shipped stills (8%) carry readable text; 1 is severe:

| Still | Leaked text | tesseract `longest_70` |
| --- | --- | --- |
| `AnsatsuKyoushitsu-OP1-still3` | "KOROSENSEI teacher." | 1 |
| `AnsatsuKyoushitsu-OP1-still1` | 出席番号 + character names | 1 |
| `AngelBeats-OP1-still2` | credit names | 2 |
| `BlackClover-OP1-still3` (marginal) | faint cursive | — |

Tesseract scored these 1-2, meaning it did not *read* them. **No threshold could have
caught them**, so tuning is exhausted as a remedy. (`AoNoExorcist-OP2-still1` shows
diegetic in-world signage and is deliberately not counted — only title, credit and
character-name overlays are leaks.) Leaks are also not positional: 79.5 s of a 90 s clip in
one case, 39.1 s in another, so no edge-trim heuristic would catch both.

**Action taken:** a second engine, `rapidocr-onnxruntime` (pinned `<2`, because 2.x renamed
itself and downloads weights on first use, which would put a network fetch inside the
60-frame loop). It runs on every candidate alongside tesseract, merged worst-case. A missing
wheel is a **fatal** error rather than a silent tesseract-only downgrade, since that would
invisibly restore the exact blindness the pass exists to remove; `RAPIDOCR_ENABLE=false` is
the explicit opt-out. `jpn_vert` was dropped in the same pass — across all 647 frames it
produced no high-confidence word while costing a pass per frame.

**Closure criteria set before the run:** a CI run shows rapidocr reading the three known-bad
frames above, *and* the `culprit` column attributes catches to it, *and* yield does not
collapse (the previous filter's failure mode was over-rejection, so a run that catches
everything by skipping most themes is not a pass).

**Verification method:** dry-run, `ocr_dump=true`, inspect the artifact *specifically for
false negatives* — every surviving still viewed by eye — rather than only checking the run
went green. A green run proves nothing here.

#### Measured 2026-08-23 — run `32617226964`: two criteria pass, the decisive one fails

Run `32617226964` completed SUCCESS in 18m59s — *faster* than the 21m6s tesseract-only run
despite adding a third pass, so the second engine is free in practice. Rejections fell
144 → 46 and yield held at 12/12 themes × 3 stills, so criterion 3 passes. All **14**
newly-rejected frames are attributed to `rapid` in the `culprit` column, several of them
logos tesseract could not read at all (`rapid:AngelBears(93)`, `rapid:AngelBeals(93)`,
`rapid:AngelBeas(88)` across four frames of one "Angel Beats!" logo), so criterion 2 passes
decisively. **rapidocr stays.**

Criterion 1 fails, and it was the one that mattered. Of the six known leak frames, exactly
one flipped to TEXTY. The rest are still classified CLEAN:

| Frame | run-3 verdict | Evidence |
| --- | --- | --- |
| `AnsatsuKyoushitsu-OP1` ts=14.9 | TEXTY — caught | `rapid:????21(98)` |
| `AnsatsuKyoushitsu-OP1` ts=79.5 | CLEAN | `longest=0`, culprit `-` |
| `AnsatsuKyoushitsu-OP1` ts=43.6 | CLEAN | `longest=1 orig:?(86)` |
| `AnsatsuKyoushitsu-ED1` ts=65.2 | CLEAN | `longest=1 up2x:?(77)` |
| `AngelBeats-OP1` ts=39.1 | CLEAN | `longest=2` |
| `BlackClover-OP1` ts=46.5 | CLEAN | `longest=2` |

The shipped set nevertheless looked better, and **that improvement is coincidence, not
protection.** Those frames left the shipped set because rejecting *other* frames reshuffled
the timeline-spread groups — not because the filter flagged them. All 12 themes' `still_ts`
changed, which also voids the run-2 eyeball: every shipped still is new and had to be viewed
again. Doing so found **2 leaks in 36 stills (5.6%), both newly introduced by the reshuffle**,
and between them they expose two *structural* blind spots rather than a bad threshold.

#### Why tuning is exhausted: three frames that no recorded scalar separates

| Frame | Verdict | `longest_70` | `chars_70` | `words` | `max_conf` | `longest_0` | Reality |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `AngelBeats-OP1` ts=45.1 | CLEAN | 2 | 6 | 39 | 99.5 | 5 | **leak** |
| `AnsatsuKyoushitsu-OP1` ts=78.0 | CLEAN | 2 | 6 | 29 | 89.5 | 2 | **leak** |
| `AoNoExorcist-OP1` ts=37.6 | CLEAN | 4 | 7 | 65 | 95.4 | 6 | clean |

**Blind spot A — Japanese.** `AngelBeats-OP1` ts=45.1 shows five bold character-name callouts
(岩沢 / 関根 / ひさ子 / 入江 / 遊佐). OCR read them correctly and confidently:
`top_words` = `子(99) 根(99) し(92) ひさ(90) ひさ(90) 遊佐(86)`. The rule missed it because a
Japanese name is 1–3 glyphs and **can never reach a 5-character token**. The longest-token
rule is structurally unable to see Japanese, at any threshold.

**Blind spot B — scattered typography.** `AnsatsuKyoushitsu-OP1` ts=78.0 is a green striped
background carrying huge isolated white Latin capitals (kinetic title typography; A, S, O and
M are each individually legible). `top_words` = `ン(89) W(86) LN(78) A(75) L(70) NN(64)`. Note
`longest_0 = 2`: **even with the confidence floor at zero the longest token never exceeds 2**,
because the glyphs are spatially separated and every engine segments them individually. No
confidence threshold can rescue this frame.

**And the clean frame blocks the obvious fix.** `AoNoExorcist-OP1` ts=37.6 is a wide cityscape
with no text anywhere, yet it scores `longest_70 = 4` — from `ーーーー(83)`, four katakana
long-vowel marks that are really window mullions and bridge railings, plus `トン(95)` from more
architectural detail. Lowering `OCR_MIN_WORD` from 5 to 4 would therefore reject a clean frame
*while still missing both leaks*. The Latin threshold has no downward headroom.

Every scalar currently recorded either fails to separate these three or ranks them backwards:
`longest_70` is 2 / 2 / **4**, `chars_70` is 6 / 6 / **7**, and `words` is 39 / 29 / **65** —
the clean frame wins two of the three. `max_conf` (99.5 / 89.5 / 95.4) does not separate them
either, and lowering `OCR_MIN_CONF` was already rejected because junk floods in below 70.
**The remedy must come from an axis that is not yet recorded, not from a threshold.**

**Axis under consideration: glyph size.** Title cards, credits and name callouts are
typographically large, while the false-positive material (mullions, railings, foliage, fabric
folds) is small. A height-gated rule — a token counts only if its bounding box is a large
enough fraction of frame height — would be indifferent to both language and token length,
catching both blind spots while dismissing the cityscape. The geometry was already free:
`ocr_words` parsed tesseract's 12-column TSV and discarded `col[9]` (height), and `rapid_words`
discarded `det[0]` (the detection box) entirely.

#### Instrumented 2026-08-23 — geometry now recorded, shipping rule deliberately unchanged

The telemetry is implemented and unit-tested; **no threshold moved**. Both engines now return
`(words, tokens)` instead of `words`, and `text_filter` writes a second artifact per theme,
`tokens-<stem>.tsv`, with one row per token per pass and these 14 columns:

```
ts  verdict  pass  conf  h_px  hrot_px  w_px  top_px  img_w  img_h  line_ntok  len  text  raw
```

Design points that the next calibration depends on, each chosen deliberately:

- **Raw pixels, never pre-divided fractions.** Normalisation — including undoing the 2×
  upscale pass — can then be changed offline without spending another run.
- **`img_w` / `img_h` come from tesseract's level-1 page row** (`col[8]`, `col[9]`), not from
  PIL and not from ~60 `ffprobe` calls per theme. They are backfilled onto every token *after*
  the parse loop, because the page row is only conventionally first; a late one would otherwise
  leave rows that cannot be normalised. rapidocr does not report image size, so it writes `0`
  sentinels which `ocr_frame` backfills from the **`orig`** pass of the same file — never from
  `up2x`, whose page box is 2× and would silently halve every rapid fraction.
- **Two heights for rapidocr.** `h_px` is the axis-aligned box height; `hrot_px` is the mean of
  the two side edges. They disagree on rotated text — 70 px versus 22 px in the unit tests — so
  the artifact, not a guess, decides which one gates.
- **`line_ntok`** records that rapidocr boxes are line-level, so a height is shared by every
  token on that line rather than measured per token.
- **Written `encoding="ascii"` through an `_ascii()` escaper** (backslashes doubled first, so
  escaping stays reversible), because the console is cp1252 and a raw CJK write would either
  crash or corrupt. A non-ASCII leak now fails loudly instead of silently, and no downstream
  reader has to guess an encoding. `len` counts glyphs before escaping.
- **Geometry degrades to zeros and never raises.** The text half of the return value is the
  safety filter; it must survive a malformed box.

The safety argument for shipping this without a re-eyeball is a **mirror invariance**:
`[(t["conf"], t["text"]) for t in tokens] == words` is asserted on *every* one of the 48 checks
in `tools/pipeline/test_curate_contract.py`, so the geometry rows provably describe the same tokens the verdict was
computed from. The metric path is byte-identical, so **run N+1 must ship exactly the same 36
stills as run `32617226964`** — verified with `.tmp/cmp-ship.py` — which is what makes the
already-eyeballed 36 (2 leaks, 34 clean) usable as labelled ground truth for choosing the
threshold offline.

Writing the tests found one real bug: the `RAPIDOCR_ENABLE=false` opt-out still returned a bare
`[]` after the widening, which would have broken the documented fallback ladder below the first
time anyone used it.

**Closes when** ~~a CI run rejects both leak frames in the table above while keeping
`AoNoExorcist-OP1` ts=37.6, *and* all 36 shipped stills survive an eyeball, *and* yield stays
at 3 stills for every theme.~~ **Superseded by the calibration below** — the label audit found
*four* positives, not two, so "both leak frames" no longer names the ground truth. Attribution
and runtime are no longer at issue.

**Order of operations from here:** ~~run the instrumented pipeline on the same 12 themes → prove
the shipped set is identical → choose the height threshold offline against the labelled 36 →
only then spend a run on a behaviour-changing rule.~~ **Done — all three steps completed**; see
below for what the offline calibration actually found.

#### Calibrated 2026-08-23 — the height axis is falsified, the replacement is a two-feature union

Run `32620787219` shipped a set **bit-identical** to run `32617226964` (per-frame diffs 0,
`VERDICT: IDENTICAL`, with a negative control firing 3557 diffs to prove the comparator
discriminates). That made the eyeballed stills usable as labelled ground truth, and the
threshold was then chosen offline in `.tmp/tokens.py` against 621 frames / 16,038 tokens.

**1. The ground truth was wrong, and checking it first saved the design.** Before fitting
anything, all five run-2 pool frames were re-eyeballed. **Three of the five were mislabelled.**

| frame | old label | verified reality |
| --- | --- | --- |
| `AngelBeats-OP1` ts=39.1 | suspected | **real leak** |
| `AnsatsuKyoushitsu-OP1` ts=79.5 | suspected | **real leak** |
| `AnsatsuKyoushitsu-OP1` ts=43.6 | suspected | clean |
| `AnsatsuKyoushitsu-ED1` ts=65.2 | suspected | clean |
| `BlackClover-OP1` ts=46.5 | "uncatchable leak" | clean |

Corrected ground truth: **4 positives, 37 clean.** The discarded "uncatchable leak" had been
about to justify loosening the rule; a rule fitted to the old labels was one step from
production. *Verify a label before designing around it.*

**2. Single-token peak height is falsified.** The tallest token in all 16,038 — `と` at
**0.6865** of frame height, conf 79.7 — is a hallucination on a **hair curve** in a frame that
is clean. Sweeping `h_px` on corrected labels returns `NOT SEPARABLE`: tallest clean 0.6687
sits above the shortest leak, and 79.5's peak is **0.0000**. The same holds for `hrot_px`,
`w_px` and `top_px` at every confidence floor. The glyph-size hypothesis recorded above is
therefore **retired**, and its sweep is deliberately kept in the harness, labelled, so the next
reader cannot re-derive the same broken threshold.

**3. Cross-pass duplicates are not corroboration.** The same physical box found by both the
`orig` and `up2x` passes is *one* observation. `dedupe()` normalises each box by its own row's
`img_w`/`img_h`, **never merges two boxes from the same pass**, and keeps the highest-confidence
member. This single change is what made a coherence feature viable: frame 43.6 fell from
**0.9918 — the highest-scoring frame of all 41, and clean** — to 0.0000, while leak 45.1's
winning cluster re-centred onto the *real* title band (median height 0.1083 → 0.1396).

**4. Two features, neither sufficient alone.** Each was swept independently and each correctly
**refused to emit a threshold**:

| feature | what it measures | catches | blind to |
| --- | --- | --- | --- |
| `coh` | typographic coherence: `median_h × √n × median((conf/100)²)`, ×1.5 when box tops are tight | titles the engine **read** (45.1, 39.1) | stylised logos |
| `bigbox` | count of deduped boxes ≥ 0.28 of frame height, **no confidence floor** | logos the engine **misread** (78.0, 79.5) | small confident text |

They fail on *different* frames, which is the entire reason the union works.

**5. Why `bigbox` deliberately has no confidence floor.** A stylised logo is confidently
**misread**, not confidently read: frame 79.5 tops out at conf **58.6** and scores 0.0000 on
every confidence-weighted feature. `bigbox` is a *segmentation* signal, not a reading.
Confidence enters `coh` as a continuous weight `(conf/100)^k`, never as a second hard floor —
the exact-70.0 cliff already showed what a hard floor costs.

**6. The shipping rule.** Expressed as one normalised scalar so `sweep`, `yield_check` and
`simulate` consume it unchanged:

```
reject when   max( coh / 0.21 ,  bigbox / 3 )  >=  1.0
```

**7. Why `bigbox >= 3` and not 4 — the reason is mechanical, not margin-chasing.** Frame 79.5
has four large boxes, but one is a degenerate full-frame **1.0 × 1.0** box at conf 28.1 — a
detector artifact, not a glyph. Its three *real* boxes are 0.876 / 0.568 / 0.378. So a
threshold of 4 catches that confirmed leak **only by counting the artifact**, and would miss it
the moment an engine version or upscale change stopped emitting it. A threshold of 3 catches it
either way, which makes the rule **independent of the artifact question**. Measured price: 5
clean frames lost instead of 3.

**8. Measured result** (`conf>=70`, `coh_t=0.21`, `big_t=3`):

- **4 of 4 known-bad frames caught, 0 missed**, 5 clean frames lost.
- **0 known-bad frames promoted** into the ship set — the regression a keep/drop count cannot
  see, because removing a leak lets `spread()` promote a different frame.
- **Every theme still yields 3 stills**; worst-theme survivor count 33 (`AnsatsuKyoushitsu-OP1`).
- Both previously-shipped leaks (45.1, 78.0) no longer ship.

**9. The union is not separable either, and that is not a bug to tune away.** Three clean
frames carry ≥4 large boxes; one clean frame sits at coherence 0.1747 against a leak at 0.2573.
Once a feature set is provably non-separable, the question stops being *"is it separable"* and
becomes *"what does it cost"* — which is what the yield and ship simulation answer.

**10. A lookup miss must never render as "clean".** The audit table initially scored all 41
frames 0.0000: the label lists hold **float** timestamps while the frame index is keyed by
`"%.1f"` **strings**, so `.get(key, [])` missed every row and its empty-list default read as
innocent. It now raises `RuntimeError` instead. This is the one failure mode a leak filter
cannot be allowed to have, and it was caught only by cross-checking against known scores.

**11. Rejected by measurement — cluster-size relaxation for large type.** Advice to relax the
minimum cluster size to 2 when median glyph height is large was implemented, measured, and
**deleted**: it readmitted the 43.6 hair-curve pair and made that clean frame the top-scoring
frame in the set. The reason is recorded inline in the harness so it is not retried.

**Still unverified — 10 frames the new rule promotes that no one has looked at.** Three were
recovered from run-2 artifacts and eyeballed **clean**: `AngelBeats-ED1` 20.6 (characters at
sunset, no text), `AngelBeats-OP1` 88.1 (night cityscape — also the source of this theme's
hallucinated glyph tokens: grids of city lights), `AoNoExorcist-ED1` 86.6 (glowing blade, no
legible text). **Seven have no JPEG on disk** and are the real cost of shipping this rule:
`AngelBeats-ED1` 67.9, `AngelBeats-OP1` 37.6, `AnsatsuKyoushitsu-OP1` 66.5, `AoNoExorcist-ED2`
54.9, `AoNoExorcist-OP1` 57.0, `AoNoExorcist-OP2` 47.5, `BlackClover-OP1` 57.9.

**Closes when** ~~the rule is implemented in `tools/pipeline/curate_theme.py`, a CI run with
uploads confirms `simulate()`'s predicted ship set frame-for-frame, and **all seven** unverified
picks survive an eyeball — with yield still at 3 stills per theme.~~ *(Superseded — the
implementation half is done; see below.)*

#### Implemented 2026-08-23 — the calibrated rule is now the shipped rule, and that is proven rather than assumed

The union rule and the selector are in `tools/pipeline/curate_theme.py`. Four things landed: the
four operational knobs (`OCR_COH_T` 0.21, `OCR_BIG_T` 3, `OCR_BIG_MIN_H` 0.28, `OCR_QUIET_T` 0.85,
all env-overridable); the scoring functions; the rejection itself in `text_filter`, which now also
emits a `reason` column (`word` / `union` / `both` / `-`) and counts `ocr_union_only` per theme; and
the tiered selector in `spread`.

**The port was done by renaming the data, not by rewriting the code.** A small adapter reshapes the
pipeline's token dicts into the exact key schema the calibration harness uses, so the scoring
functions are copied across character-for-character. That choice existed purely to make the
following check possible:

| Parity check on the run-4 artifact | Result |
| --- | --- |
| Frames scored by both implementations | **621** |
| Exact mismatches | **0** |
| Worst absolute delta | **0.000e+00** |
| Frames with nonzero risk / rejected by the rule | 328 / 78 |
| Negative control (`BIG_MIN_H` 0.28 → 0.05) | **589 mismatches** — the check is not inert |

This matters beyond tidiness. `.tmp/cmp-sim.py`'s gate is *"reality must equal `simulate()`'s
prediction"*. If the two implementations differed by a float, that gate would be comparing against
a prediction no longer describing the shipped rule, and every number in this entry would describe
a rule that is not running. Bit-identity is what makes the rest of the evidence transferable.

**The contract suite earned its keep on the first change.** Returning the new `union_only` counter
altered `text_filter`'s arity, and the suite failed immediately with `ValueError: too many values to
unpack` at the call site rather than silently in CI two weeks later. New checks cover: the union
rule staying inert on a word-rule rejection; a risk score present on *every* candidate; the dump's
`reason` and `risk` columns; a **geometry-only** rejection end-to-end — deliberately isolated with
confidence below `ocr_min_conf` so coherence is structurally zero and only the confidence-free box
count can fire, which is `AnsatsuKyoushitsu-OP1` 79.5 in miniature; and five selector cases
including the fallback, the exact-threshold boundary, and the hard failure on an unscored candidate.

**Two mechanisms were priced and dropped**, both recorded in `doc/GAME-DESIGN.md` §5.2.2–§5.2.3:
pure risk-ranked selection (18 spans reshuffled, 17 new never-inspected frames, one span down to
55% of its bytes, **0** known-bad avoided) in favour of the tiered `0.85` rule (0 spans changed,
0 new frames, worst ratio 1.000, and three live survivors at 0.901/0.907/0.997 for it to guard);
and spatial dilation, which has nothing left to catch, no testable adjacency signal, and no safe
weight that is not also inert.

The ship set is **unchanged** under the tiered selector, so the review debt is still exactly the
same 7 frames listed above. No workflow change is needed to see them: dry runs already write all 36
stills, and `out/` is uploaded wholesale — confirmed against run 4 (`status='DRY'`, 36 stills).

**Closes when** ~~a CI run with `ocr_dump=true` reproduces `simulate()`'s predicted ship set
frame-for-frame (`.tmp/cmp-sim.py` reporting `PROMOTED 0` and `themes shipping fewer than 3: 0`)
and **all seven** newly promoted picks survive an eyeball. Until then B-28 stays open: runs 3 and 4
ship two confirmed leaks.~~ *(Superseded — the CI half passed, the eyeball half did not; see below.)*

#### Verified 2026-08-23 — run `32629295922`: the rule does exactly what it was calibrated to do, and that is how a second leak class was found

The run was a dry run over the same 12 themes with `ocr_dump=true`, 19m29s, artifact in
`.tmp/artifact5/curate-0-12-all`. **Every automated gate passed:**

| Gate | Result |
| --- | --- |
| `.tmp/cmp-sim.py` positive control (rule off must match run 4) | `disagreements: 0 — control PASSES` |
| `.tmp/cmp-sim.py` negative control (rule on must differ) | differs, as required |
| Known-bad frames promoted into the ship set | **0** |
| Themes shipping fewer than 3 stills | **0** |
| Shipped set vs `simulate()`'s prediction | **exact match, all 12 themes / 36 frames** |
| `.tmp/check5.py` three-way telemetry consistency | `inconsistencies: 0` |

Both previously confirmed leaks are gone (`AngelBeats-OP1` 45.1, `AnsatsuKyoushitsu-OP1` 78.0).
Clean population fell 599 → 535 with 64 union-only rejections; no theme dropped below 3 candidates.

**The rule is correct. The blocker does not close, because correctness was never the question —
coverage was.** The union rule promoted 10 frames that had never been looked at. Eyeballing all
ten (plus a re-check of one previously cleared frame) found **one leak of a class the rule cannot
represent**.

**The new leak: `BlackClover-OP1` @ 57.9 s** — a character-name card. Cursive Latin captions
composited over the art ("Vanessa Enoteca", "Gauche", "Charmy Pappitson", "Luck Voltia",
"Magna Swing"). Per the criterion already recorded above — *only title, credit and character-name
overlays are leaks* — this is a leak: non-diegetic production text that resolves to the answer
via one search, with no anime knowledge required. The title itself never appears.

**Why no threshold catches it, measured rather than argued** (`.tmp/shipscan.py`, priced against
all 535 clean frames):

| Discriminator | The leak | Confirmed-clean frames that score *higher* |
| --- | --- | --- |
| union `risk` | 0.5183 | **four at 0.6667**, all eyeballed clean |
| `longest_70` | 3 | indistinguishable from clean frames |
| `chars_0` (text density) | 72 — ranks **9th** | 287 (damask pattern), 253 (grunge texture) |

Lowering the risk threshold to 0.5183 to catch it costs **67 of 535 clean frames** and displaces
**four already-confirmed-clean shipped stills** to gain one — the same shape of trade already
rejected for `BIG_T=4` and for dilation. **Threshold-lowering is rejected by measurement.**
Cursive defeats both OCR engines, so no long high-confidence word is ever produced
(`longest_70 = 3` against a floor of 5, `max_conf` 93.7 on junk, `culprit rapid:den(73)`).

**A time-window exclusion is also dead** (`.tmp/cursive.py`). Frames carrying the
"engine saw shape but could not read it" signature (`longest_0 >= 5 AND longest_70 < 5 AND
chars_0 >= 40`) occur in contiguous runs of **1–4 frames, overwhelmingly 1** — scattered across
the clip, not confined to a credits sequence. There is no window to cut.

**What the same measurement did produce is a triage filter.** That signature fires on 47 of 647
candidates (7.3%) — far too noisy to reject on, since most matches are texture rather than text.
But applied *only to the ship set* it fires on **2 of 36 shipped frames, one of which is the
leak**: 1 true positive, 1 false positive (`BlackClover-OP1` 86.6, grunge), 0 false negatives.
That converts an intractable 402-frame human review across the full 134-theme run into roughly
**22 flagged frames**. Its recall is honestly unproven — it rests on a single positive.

**Also corrected in this pass.** The earlier eyeball rounds hunted *title* text specifically, so a
name card could pass them; `BlackClover-OP1-still3` was in fact already flagged "faint cursive,
verdict ?" in the run-3 table above and never resolved. The nine other newly promoted frames are
**clean**: `AngelBeats-ED1` 67.9, `AngelBeats-OP1` 37.6, `AnsatsuKyoushitsu-OP1` 66.5,
`AoNoExorcist-ED2` 54.9 and 60.7, `AoNoExorcist-OP1` 57.0, `AoNoExorcist-OP2` 47.5,
`BlackClover-OP1` 86.6. The two densest frames in the entire ship set (287 and 253 `chars_0`) are
a repeating damask motif and a grunge texture respectively — **zero text in either**, which is
precisely why density cannot be used as a discriminator.

**Closes when** the name-card class has an agreed remedy and the shipped stills for all 134 themes
have been cleared under the *full* criterion (title **and** credit **and** character-name
overlays) — not the title-only criterion the first three eyeball passes used. The rule itself
needs no further calibration; what is missing is a review gate and a way to act on it. Note that
no frame-level exclusion mechanism exists today: `manifest.json`'s `excluded` is theme-level, and
`curate_theme.py` has no per-timestamp blocklist, so acting on a rejected frame currently requires
adding one.

**Fallback if OCR still proves unreliable:** stills-only rooms lose their safety margin, so
the fallback is not "ship it anyway". Options, in order of preference: bias selection to
endings (0/4 EDs leaked a title versus 5/6 OPs), sample frames from the back half of the
sequence where title cards are rare, or gate low-confidence themes into a manual review
list rather than the question bank.

---

### B-29 — CLOSED · Poster key derivable from the still keys a player already holds

**Opened and closed 2026-08-23**, recorded because the reasoning matters more than the fix.

Migration 0010 correctly stopped keys deriving from `question_bank.id` (which every room
member can read via `rounds.question_id` for *every future round*). It rooted all five
objects in one `asset_slug` instead. That closed the `id` leak and opened a narrower one:

```
stills/{asset_slug}-1.jpg     <- sent to the player, legitimately
posters/{asset_slug}.jpg      <- the title card, i.e. the answer
```

One path segment apart. A player holding the still for the round they were being asked
could construct the answer image for that same round. `get_current_round` withholding the
poster key was therefore a statement of intent, not a control.

Two measurements made this exploitable rather than theoretical:

1. **On a `public = true` bucket, object reads by key bypass RLS entirely.** Probed
   directly: after dropping the read policy, `list` returned 0 objects but `GET` by key
   still returned 200. The policy had only ever granted *enumeration*. So no policy could
   restrict an object once its key was known.
2. Key unguessability is consequently the *only* protection.

**Fix — migration `20260823000011`:** three independent roots on `question_bank`
(`asset_slug` for stills, `poster_slug`, `audio_slug`), each `not null unique`, plus a
`question_bank_slugs_distinct` CHECK because the realistic ingest bug is one uuid reused for
all three. The 2-argument `question_asset_keys` was **dropped** rather than kept as an
overload — an overload leaves the hole one call site away. `ingest_question` v3 requires all
three and adds `MISSING_POSTER_SLUG`, `MISSING_AUDIO_SLUG`, `SLUGS_NOT_DISTINCT`. The
`"media is publicly readable"` policy was dropped outright rather than narrowed, per
measurement 1. `get_current_round`'s anon grant was revoked by name — revoking from `PUBLIC`
does not remove a grant to a named role, and `create or replace` does not reset an ACL.

Verified: migration applied twice (idempotent), ACLs re-audited, all three new guards plus a
positive round-trip exercised against the live database. **Still unproven over HTTP** — the
guards have only been exercised in SQL.

Bucket stays public and unsigned: that preserves CDN-cached repeat plays outside metered
egress and avoids a signing round-trip per asset. Independent 122-bit roots make keys
unguessable, not revocable — that trade is deliberate.

**Related, deliberately not fixed:** `advance_round` is still callable by `anon`. Out of the
approved scope for 0011 and contained by its own `now() >= deadline` check, but it is the
next thing to look at in this area.

