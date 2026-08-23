# ReIN Bot — Game Design

Status: **first draft, 2026-08-21.** Decisions in §1 are confirmed by the user.
Everything else is proposed and open to revision. No code exists yet.

Numbers cited as verified come from `doc/RESEARCH.md`; blockers referenced as `B-n`
come from `doc/BLOCKERS.md`.

---

## 1. Confirmed decisions

| # | Decision | Choice |
| --- | --- | --- |
| 1 | What the player gets each round | **2–3 progressively revealed still frames, text-free; audio optional per room** (revised 2026-08-23, §3) |
| 2 | How the player answers | **Free text with fuzzy matching** |
| 3 | Player model | **Realtime multiplayer rooms** |
| 4 | Content pool | **Curated pool from a popularity cut** |

These four together settle the architecture. Content comes from AnimeThemes.moe
(`doc/RESEARCH.md` §4); trace.moe and AniList are both out (`doc/RESEARCH.md` §6).

### 1.1 One consequence worth stating plainly

Video was chosen over audio knowing the raw files are roughly 15× heavier
(`doc/RESEARCH.md` §4.6). That is a fair call for a private game, but it makes **media
delivery** the one architectural decision of consequence, not a detail. §3 sets out the
options and records the decision: preprocessed ~1 MB clips in Supabase Storage.

That lands at **roughly a third** of the bandwidth the prior design's default —
**hot-linked** audio-only — would have used (80 MB vs ~240 MB per game,
`doc/RESEARCH.md` §4.7). So the choice costs nothing on bandwidth once the curation step
exists, and the curation step exists anyway because of decision 4.

*Two clarifications, because an earlier draft was loose here. First, it said the
recommended option lands at "roughly the same bandwidth as audio-only"; it is
substantially better than that. Second, the win comes from **preprocessing, not from
choosing video** — a 1 MB clip beats a hot-linked ~3 MB OGG. Preprocessed 20 s* audio
*clips would be lighter still (~19 MB/game); video costs ~4× that, which is the real
price of the video decision and is affordable (§3).*

---

## 2. The round, end to end

A room holds 2–8 players. A game runs **3–20 rounds**, chosen by the host at
room creation; **10 is the default**.

```
LOBBY ──► ROUND_PLAYING ──► ROUND_REVEAL ──► (next round) ──► GAME_OVER
             ~20 s              ~8 s
```

**ROUND_PLAYING.** Every client plays the same clip, **muted**, starting at the
same wall-clock instant. Players type guesses freely. A player may submit more
than once; only the first correct submission scores. Submissions are graded
server-side (§4) — the client never holds the answer.

**ROUND_REVEAL.** Audio unmutes and the clip continues; the title, cover art, song
name and year appear, along with who got it and how fast. Reveal is also where
players see the answer they *almost* had, which matters for fuzzy matching
credibility.

**Muting during play is a design requirement, not a nicety.** The song is a much
stronger clue than the visuals for most players, and unmuting at reveal is what
makes the round feel resolved.

### 2.1 Why the answer cannot live on the client

The clip URL is derived from AnimeThemes' `Video.basename`, and basenames are
human-readable — `KimiSen-OP1-NCBD1080.webm` contains the answer. Any design that
hands the raw AnimeThemes URL to the browser during play **leaks the answer in
devtools, or even in the network panel's URL column.**

This is decisive for §3: clips must be served from a URL that does not encode the
title. An opaque key is required during ROUND_PLAYING.

#### 2.1.1 Threat model — what this design does and does not defend against

The game is private and friends-only, so the goal is **removing casual and accidental
leaks, not defeating a determined attacker.** Being explicit about the line:

**Defended — closed by design:**

| Vector | Closed by |
| --- | --- |
| Reading the title from the media URL | Opaque keys (§3) |
| Reading the answer from network JSON | Answer never sent to clients during play. `question_bank` and `question_titles` carry **no `anon` / `authenticated` grant at all**, and `rounds` stores only a denormalised `clip_key` — so no client-reachable table has an answer column that would need hiding (§4.4.2) |
| Reading the candidate set to brute-force it | Candidate set built and compared server-side only (§4.1) |
| Title burned into the picture | Mandatory `nc: true` variant, plus a visual spot-check (`doc/RESEARCH.md` §4.8, §5.2 step 4) |
| Faking a fast answer for the speed bonus | Server stamps `submitted_at = now()`; client timestamps are not accepted (§6.3) |
| Guessing before the round starts | Grading rejects submissions outside the round's `[started_at, ends_at]` |
| Reading the answer early from the reveal payload | Reveal data is broadcast at ROUND_REVEAL, not preloaded with the clip |

> **Verification status of this table · 2026-08-22.** Every mechanism this table relies
> on has now been checked against primary docs and production code (§4.4.1–§4.4.3, §6.3),
> and **not one survived review unchanged**. One row was found outright broken: "Reading
> the answer from network JSON" rested on a grant model that was a no-op and would have
> exposed the answer to every client. The other three were directionally right but each
> omitted a step that was load-bearing for the guarantee it claimed — a `search_path`
> setting, a dashboard toggle, and a constraint on which column the round-advance guard
> may test. All are now documented. Read this table as *"defended once §4.4 and §6.3 are
> implemented exactly as written"* — the details are not incidental, and it is not a
> description of anything that exists yet. Remaining known gap: **B-18** (whether
> pg_graphql honours the same column grants as PostgREST, i.e. whether row 4 has a
> second unguarded door).

**Not defended — accepted residual risk:**

- **Reverse image search.** A player can screenshot the muted clip and put it through
  Google Lens, SauceNAO, trace.moe or IQDB. Anime OP/ED frames are extremely well
  indexed, so this will usually succeed. **This is unfixable in principle** — the whole
  game is showing the player the frames. Mitigations are social and structural, not
  technical: the 20 s window is short enough that searching costs more than the speed
  bonus is worth, the speed bonus rewards instant recognition over research, and it is a
  private game among friends where cheating has no prize. *Ironically the most effective
  cheat here is the very API §1 of `doc/RESEARCH.md` investigated and rejected as a content
  source.*
- **Shoulder-surfing / out-of-band collusion.** Two players in the same room, or in a
  side chat, can share answers. Out of scope.
- **Audio fingerprinting at reveal.** Once audio unmutes the round is already scored, so
  this has no value.
- **Prefetch inspection.** Clips are prefetched during the *previous* round's reveal
  (§6.3), so a player can obtain round N+1's clip bytes ~8 s early and reverse-image-search
  it before the round starts. This is a real head start and follows directly from the
  prefetch optimisation. **Accepted** — the alternative is buffering stalls, which harm
  every honest player to inconvenience a cheater. Note it as a known trade rather than
  pretending prefetch is free.

**Consequence for scoring:** because reverse image search cannot be prevented, the speed
bonus (§6.2) is doing double duty — it is the fun mechanic *and* the main anti-cheat
pressure. That is a further argument against the streak multiplier, which would amplify
the advantage a patient cheater gains.

---

## 3. Media delivery — **DECIDED 2026-08-22, CONTENT MODEL REVISED 2026-08-23**

**Decision: Option B — preprocess into Supabase Storage.** The transport half of this
decision stands and everything below it still applies. What each question *contains*
changed on 2026-08-23 (`doc/BLOCKERS.md` B-25), so read Option A/B as an argument about
hot-linking versus preprocessing, not about video.

**No video is stored or served, ever.** Each question is five objects: one ~160 KB Opus
audio track, two or three text-free stills, and one poster used only on reveal
(`doc/DATA-MODEL.md` §8.3). A round reveals stills progressively at roughly 0 s / 7 s /
14 s; the reveal then shows poster + title. The host chooses **stills-only** or
**audio + stills** when creating the room (`rooms.audio_enabled`).

**Why stills instead of a muted video window.** A video window is contiguous, and that is
the whole problem. `-ss 5 -t 20` takes whatever happens to be in that span, and OP title
cards routinely land inside the first ~15 s — the exact window a 20-second round wants.
There is no way to exclude a title card at 0:12 without discarding the surrounding footage
too. Stills are chosen *independently*, so each one can be vetted on its own and a spoiling
frame simply is not picked. The reveal is strictly better as well: the frame that spoils
the round is the ideal poster, so the title card graduates from liability to asset instead
of being discarded.

**Correction: `nc: true` never protected the answer.** The previous text here claimed the
credit-free variant rules in `doc/RESEARCH.md` §4.8 were mandatory because a credited video
"can burn the show's title into the picture and give the answer away". That was measured on
2026-08-23 and is false: **5 of 10** sampled clips display the title in Latin script, and
all ten satisfied `nc:true, subbed:false, overlap:NONE` (`doc/BLOCKERS.md` B-20). The split
was 5 of 6 openings versus 0 of 4 endings — the title card is an *opening* convention, not a
credits artefact, so a flag about credits was never going to catch it.

The `nc:true` constraint is kept, but for a weaker and honest reason: credit-free sources
carry less on-screen text overall, so they yield more usable frames per sequence. The thing
that actually protects the answer is per-frame OCR rejection at selection time
(`doc/RESEARCH.md` §4.10). It is the riskiest premise in the pipeline, and it is now
**measured insufficient rather than merely unverified**: the current rule shipped 2 readable
stills out of 36. A replacement rule has been calibrated offline and catches all 4 known-bad
frames with none promoted, but it is **not yet implemented in the pipeline** (§5.2.2,
`doc/BLOCKERS.md` B-28).

### Option A — hot-link AnimeThemes directly · REJECTED

Serve `https://v.animethemes.moe/{basename}.webm` straight to the browser.

- Zero storage, zero preprocessing, no curation tooling.
- **Leaks the answer via the filename (§2.1).** Fatal on its own.
  > **SUPERSEDED 2026-08-22 (finding retained).** The secrecy goal was dropped, so a
  > leaked answer is no longer disqualifying and this bullet no longer carries the
  > rejection. **Option A stays rejected anyway**, on the CORS gap below and — decisively
  > — on bandwidth: ~1.2 GB per game against a 5 GB *org-shared* monthly allowance
  > (`doc/ARCHITECTURE.md` §10.2) is about **four games per month**. Do not reopen this
  > option on the grounds that secrecy stopped mattering; the arithmetic kills it
  > independently.
- No CORS (B-9), so no blur/zoom reveal effects, ever.
- Bandwidth, using the verified median `nc: true` size of ~46.7 MB, a ~90 s theme,
  a 20 s play window and ~1.5× buffer overshoot:

  | | Per player/round | 8 players × 10 rounds (default) |
  | --- | --- | --- |
  | ~33% of 46.7 MB | ~15.4 MB | **~1.2 GB per game** |

- Load on AnimeThemes: ~800 partial fetches per game, every game, forever.

### Option B — preprocess curated clips into our own bucket · **CHOSEN**

At curation time, fetch each chosen theme once, cut a ~20 s clip, transcode, and
store it under an **opaque key**.

- **Opaque keys fix §2.1.** `clips/9f3a…webm` reveals nothing. The media URL is the
  second answer-leak after the answer field itself, so this is load-bearing, not
  cosmetic.
- **Our own bucket gives us CORS control**, which retires B-9 and unblocks blur/zoom
  reveal effects.
- Load on AnimeThemes: **500 fetches, once, ever.** Strictly kinder than Option A,
  which re-fetches per player per round. This matters — their ToS reserves the right
  to disable content that is "burdensome to our systems" (`doc/RESEARCH.md` §4.9).
- Cost: a curation pipeline (§5) and a transcode step.
- **~15× less play-time bandwidth than Option A** (80 MB vs ~1.2 GB per game), and
  **roughly a third** of the **hot-linked audio-only** mode that the prior design chose
  as its default (~240 MB/game — `doc/RESEARCH.md` §4.7, from ~3 MB per full-length OGG ×
  80 fetches). *An earlier draft of this section claimed "slightly less than
  audio-only"; that understated it.*
- Note that this is **not** the same as *preprocessed* audio clips, which would be
  lighter still (~19 MB/game — rightmost column below). Preprocessing is what does the
  work here, not the codec: once you are cutting clips anyway, video at ~1 MB beats
  hot-linked audio at ~3 MB.

### Where it is stored — Supabase Storage, not R2

The stack mandate (GitHub Pages + Supabase, `doc/RESEARCH.md` §3) rules out R2 as
the default. (It read "Vercel + Supabase" until 2026-08-22; the frontend host
changed, the R2 conclusion did not — R2 was rejected for being a third provider,
not for anything Vercel-specific.)
Supabase Storage is tighter but clears actual expected usage. Per-game media is
`rounds` (3-20, default 10) × 8 players × clip size, and Supabase's egress is a **single pool shared by
Database, Auth, Storage, Edge Functions and Realtime** (`doc/RESEARCH.md` §3.5), so the
budget below is the whole backend's, not just media's.

> **Correction 2026-08-22 — the pool is shared across *projects*, not only services.**
> The paragraph above is right that egress spans Database, Auth, Storage, Edge Functions
> and Realtime. It understates the problem: on the Free plan the allowance is billed per
> **organization**, and this project's org also contains a second active project
> (`Mubitracker`). So the numerator in every row below is not 5 GB but
> `5 GB − whatever the co-tenant consumed`, and an overage triggered by that co-tenant
> restricts ReIN Bot too. Current consumption could not be read (the usage API returns
> 404) — see `doc/ARCHITECTURE.md` §10.2 and **B-21**. Treat the figures below as an upper
> bound, not a budget.

| | R2 (not used) | Supabase @ 1.5 MB | **Supabase @ ~1 MB (chosen)** | Supabase, 20 s audio clips |
| --- | --- | --- | --- | --- |
| Library, 500 clips | 750 MB / 10 GB = **7.5%** | 750 MB / 1 GB = **75%** | **500 MB / 1 GB = 50%** | 120 MB = 12% |
| Per game (8p × 10r) | 120 MB | 120 MB | **80 MB** | 19.2 MB |
| Egress ceiling | **unmetered** | ~42 games/mo | **~62 games/mo** | ~243 games/mo |
| Headroom vs ~12–16 games/mo | no ceiling | 2.8× | **~4×** | ~16× |

Two corrections to earlier reasoning, both verified:

- **Realtime traffic is negligible, not a competing claim on the pool.** Roughly 480
  state events × 8 recipients × ~0.5 KB ≈ **~2 MB per game**, against 80 MB of media.
  Media is ~98% of egress, so the shared-pool concern is structurally real but
  numerically almost irrelevant. The ~62 figure already includes it.
- **CDN caching will not rescue the number.** With 500 clips drawn 10 at a time,
  ~15 games/month is ~150 plays across the library — most fetches are first fetches.
  The *uncached* 5 GB is the correct planning figure, which is what the table uses.

Storage note: the 1 GB quota is metered as **744 GB-Hrs, an average over the billing
period** rather than a live peak, so 500 MB held continuously is genuinely 50%.

**Why not R2 anyway.** R2 is objectively better here — 7.5% storage and no egress
ceiling at all. It was rejected because it reintroduces a third vendor and, with **no
custom domain**, needs a `*.workers.dev` Worker in front of the bucket (R2's `r2.dev`
endpoint is rate-limited and documented as not for production). ~4× headroom on the
mandated stack is sufficient today.

**The one real risk this accepts:** Supabase egress is a **hard monthly cliff**, and
what happens at the cliff is unverified (**B-13**). Exceed it on day 20 and there is
no graceful degradation. R2 has no cliff, and remains the documented escape hatch if
traffic ever becomes bursty or public (`doc/RESEARCH.md` §3.4).

**Why Option B overall.** It is the only option compatible with §2.1, it is cheaper on
every metered axis, it is politer to the upstream service, and the curation step it
requires is already implied by decision 4.

**Resolved sub-decision:** where the transcode runs. It must not install a background
service on the laptop (`CLAUDE.md`). Decision: a **GitHub Actions** workflow — cloud,
free, and consistent with the project's "testing happens in the cloud" rule.
**Verified (B-12): `ffmpeg` is NOT preinstalled on GitHub-hosted `ubuntu-latest`
runners**, so the workflow must install it explicitly (`apt-get`, or a setup action).
Budget is not a concern — the whole curation run is a few hundred minutes at most
against 2,000 free minutes/month, and public repositories are unmetered entirely
(`doc/RESEARCH.md` §3.7).

---

## 4. Fuzzy answer matching

AnimeThemes hands us a rich answer key per round, verified live: `title.romaji`,
`title.english`, `title.native`, plus `synonyms[].text` — which include real fan
abbreviations such as `Kimisen` for *Kimi to Boku no Saigo no Senjou*.

### 4.1 Accepted-answer set

For each round, build the candidate set from romaji + english + native + every
synonym. Grade a submission correct if it matches **any** candidate after
normalisation.

**Two guards are mandatory, not optional:**

1. **Discard any candidate that normalises to the empty string**, and discard empty
   submissions. Without this the game is trivially breakable — see the `title.native`
   bug in §4.2.
2. **Deduplicate the normalised set.** `title.romaji` and a synonym frequently collapse
   to the same string, which inflates nothing functionally but makes the near-match
   tier's behaviour harder to reason about.

### 4.2 Normalisation, applied to both sides

**Order matters.** Two bugs in an earlier draft of this list came purely from sequence:

1. Unicode NFKC, then lowercase.
2. Strip diacritics (`Fate/Zero` vs `Fate／Zero`, `Pokémon` vs `Pokemon`).
3. Normalise long-vowel spellings: `ou`→`o`, `uu`→`u`, `oo`→`o`, and `ō`→`o`
   (`Yuu`/`Yu`, `Tōkyō`/`Tokyo`).
4. **Strip a leading article (`the`, `a`) — while spaces still exist.**
5. Drop all non-alphanumerics, including spaces (`Re:Zero` → `rezero`,
   `K-On!` → `kon`, `BUILD-DIVIDE -#FFFFFF-` → `builddivideffffff`).
6. Strip trailing season/part markers for a *secondary* lenient pass:
   `season 2`, `2nd season`, `s2`, `part 2`, `ii`, `2`.

**Bug 1 — article stripping ran after space removal.** The earlier order dropped
spaces first, so "strip a leading `a`" could no longer tell an article from a first
letter: *Attack on Titan* → `attackontitan` → **`ttackontitan`**. Steps 4 and 5 are
therefore swapped above. Strip the article as a whole word, while word boundaries still
exist.

**Bug 2 — `title.native` normalises to the empty string.** Step 5 with an ASCII-only
class (`[^a-z0-9]`) deletes every character of 君の名は, yielding `""`. Combined with the
near-match tier in §4.3 — edit distance ≤ 1 for short strings — an empty candidate
matches **any single-character submission**, so typing `a` would be graded correct in
every round. Two fixes, apply both:

- Make step 5 **Unicode-aware**, keeping characters in the letter/number categories via the
  POSIX class `[^[:alnum:]]` rather than `a-z0-9`, so CJK survives and a Japanese-input
  player can legitimately answer in Japanese. (This bullet said `\p{L}`/`\p{N}` until
  2026-08-22; PostgreSQL's regex engine rejects Perl property escapes outright — see
  `doc/DATA-MODEL.md` §6.1 for the error and the verification that `[[:alnum:]]` is genuinely
  Unicode-aware on this project.)
- Enforce the §4.1 empty-string guard regardless, as defence in depth.

**Also note:** step 3 is aimed at romaji but runs on English titles too, where it is
occasionally destructive (*Your Name* → `yor name`). Because it is applied to both
sides it still self-matches, so this is a collision risk rather than a correctness
bug — but it is a reason to keep the near-match threshold conservative.

### 4.3 Match tiers

| Tier | Rule | Verdict |
| --- | --- | --- |
| Exact | normalised equality | correct |
| Near | `levenshtein_less_equal()` ≤ 2 for strings > 8 chars, ≤ 1 otherwise | correct |
| Season-lenient | equal after §4.2 step 6 but season differs | correct, flagged in reveal |
| Prefix | submission is a ≥ 8-char prefix of a candidate | correct |
| Otherwise | — | incorrect |

Distance thresholds scale with length so that short titles do not collapse into
each other (`Bleach` vs `Beach`). The season-lenient tier is deliberately generous:
in a party game, punishing someone for *Fate/Zero* vs *Fate/stay night* is correct,
but punishing *Monogatari S2* vs *Monogatari Second Season* is not.

#### 4.3.1 Corrected: plain Levenshtein, not Damerau–Levenshtein · VERIFIED 2026-08-22

> An earlier draft of the Near row read **"Damerau–Levenshtein ≤ 2"**. **Postgres cannot
> provide that function**, so the tier as written was not implementable.

`fuzzystrmatch` — the only string-distance extension available to us — creates exactly
these functions (verified against `postgres/postgres:contrib/fuzzystrmatch/`):

- `levenshtein(text,text)` and `levenshtein(text,text,int,int,int)`
- `levenshtein_less_equal(text,text,int)` and `levenshtein_less_equal(text,text,int,int,int,int)`
- `soundex`, `difference`, `metaphone`, `dmetaphone`, `dmetaphone_alt`
- `daitch_mokotoff` (added in 1.1→1.2)

**No Damerau–Levenshtein exists in the set.** The decisive detail is the cost-parameterised
variant's signature: `levenshtein(text, text, ins, del, sub)` takes insertion, deletion and
substitution costs and **no transposition cost** — transposition being the single operation
that distinguishes Damerau from plain Levenshtein.

Consequence for gameplay, stated plainly: a transposition (`Naruto` → `Nartuo`) costs **2**
edits instead of 1. At the > 8-char threshold of 2 it is still graded correct, so the common
case survives. On a short title at threshold 1 a transposition is now **rejected**
(`Bleach` → `Belach` scores 2). That is a real, accepted regression, and it errs toward
false-negatives rather than false-positives — the safer direction for a scoring game.

Use `levenshtein_less_equal()`, not `levenshtein()`: it short-circuits once the threshold is
exceeded instead of computing the full matrix.

`levenshtein` raises an error on inputs longer than 255 characters, so the guess field must
be length-capped before it reaches the grader (`doc/DATA-MODEL.md` §2.1).

**DECIDED 2026-08-22 (B-22).** Season-lenient earns **full credit**, identical to an exact
match, with a "(you said S2 — it was S1)" note at reveal. Every correct tier scores the
same, so `match_tier` is reveal flavour only and never enters the points expression
(`doc/DATA-MODEL.md` §6.2).

### 4.4 Where matching runs

Server-side, in Postgres — a `SECURITY DEFINER` function (`grade_guess`, specified in
`doc/DATA-MODEL.md` §6.2) that receives the guess and returns only a verdict. The client never
receives the candidate set (§2.1).

**Decision ratified 2026-08-22.** The guess path is a Postgres function reached over
PostgREST, *not* an Edge Function. This is the single deliberate carve-out from an
otherwise Edge-Function-owned server layer, and the reason is narrow: an Edge Function
would have to check-then-write across two round trips, letting two isolates both conclude
"no winner yet" and both insert. Closing that requires the partial unique index
`one_winner_per_round` in Postgres regardless — so the extra hop buys nothing and costs
latency on the one path where latency decides who wins. Full rationale and the rejected
alternative: `doc/ARCHITECTURE.md` §5.2.

See `doc/RESEARCH.md` §3.5 and **B-17** (resolved — this section is the corrected output of
that review).

**B-18 is closed as moot.** It asked whether `pg_graphql` enforces the same column grants
as PostgREST. Two independent reasons it no longer applies: the column-grant scheme it
was about has been **dropped entirely** (§4.4.1 below), and `pg_graphql` is **verified not
installed** on the live project — so no second read path exists to bypass anything.

#### 4.4.1 Column-grant scheme · SUPERSEDED 2026-08-22 (finding retained)

> **Status: the prescription in this section has been removed from the design.** The
> Postgres finding below is retained because it is easy to get wrong and someone will
> otherwise re-invent the broken version. The scheme it recommended is no longer used.

**The finding, which still stands.** Postgres column privileges are **additive to** table
privileges, never subtractive. `postgres/postgres`'s own regression fixtures show the two
coexisting — `GRANT SELECT ON pg_proc` followed by `GRANT SELECT (prosrc) ON pg_proc` —
which is exactly why omitting a column from a column-level grant restricts nothing while a
table-level grant is still held. **There is no `REVOKE SELECT (answer)` that works.**

This matters because **Supabase grants `anon` and `authenticated` table-level privileges on
`public` by default**, relying on RLS as the gate. RLS filters *rows*, not *columns* — so any
row a player may see, they see in full.

**What was prescribed and is now dropped.** A revoke-then-allow-list sequence on
`public.rounds`:

```sql
-- NO LONGER PART OF THE DESIGN — recorded for context only
REVOKE SELECT ON public.rounds FROM anon, authenticated;
GRANT SELECT (id, room_id, clip_key, started_at, ends_at)
  ON public.rounds TO anon, authenticated;
```

It worked, and it failed closed. But it carried a mirror-image failure: the app breaks
quietly when a needed column is forgotten. `erikdarlingdata/PerformanceMonitor` documents
hitting exactly this drift *"silently for three releases"* and had to add a build-time
set-equality test to catch it. That test would have become **our** maintenance burden, on
every future migration, forever.

**What replaced it.** Two structural choices in `doc/DATA-MODEL.md` that need no grant
gymnastics at all:

1. **`rounds` has no answer column to hide.** It carries a denormalised `clip_key`
   (§4.3 of `doc/DATA-MODEL.md`), so the whole row is safe to expose and no join to content
   tables is required.
2. **`question_bank` and `question_titles` get no client grant whatsoever** — not a
   revoke-and-re-grant, just the absence of a privilege, which is the default state.

**This is worth being explicit about, because it is the rare simplification that also
removes a failure mode.** Dropping the secrecy requirement did not merely save effort — it
deleted the allow-list drift bug *and* the build-time test needed to police it. The
remaining posture is not "we protect the answer"; it is "we decline to publish the answer
key to every browser", which is ordinary schema hygiene and costs nothing to maintain.

Anyone tempted to reintroduce column-level grants here should re-read the additive-privilege
finding above first.

#### 4.4.2 `SECURITY DEFINER` hardening · VERIFIED 2026-08-22

A `SECURITY DEFINER` function without a pinned `search_path` is a privilege-
escalation vector — the caller influences name resolution and can shadow a
referenced object. The canonical fix is `SET search_path = ''` (empty, *not* a schema
list), which is what Supabase's own repository uses, and which Supabase retrofitted
onto pre-existing functions in a migration named `misc_database_fixes.sql`.

```sql
CREATE OR REPLACE FUNCTION public.grade_guess(p_round_id uuid, p_guess text)
RETURNS ...
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$ ... $$;
```

**Consequence:** with an empty `search_path`, every identifier must be fully
schema-qualified — `public.rounds`, `public.rounds%ROWTYPE`, `(SELECT auth.uid())`.
Unqualified references fail at **runtime, not at creation**, so this is a latent-bug
shape. Observed qualified throughout in production in `fastrepl/anarlog`.

**Accepted risk.** Supabase ships a security lint,
`0028_anon_security_definer_function_executable`, flagging `SECURITY DEFINER`
functions callable by `anon`. Ours *must* be player-callable, so it trips that lint
**by design**. The usual workaround — parking such functions in a `private` schema
PostgREST cannot reach, as `fastrepl/anarlog` does — is unavailable for the grading
call specifically, because the client has to invoke it. Mitigation therefore lives
inside the function: verify the caller's room membership, reject guesses outside the
open window, and rate-limit per player per round.

#### 4.4.3 Answer secrecy on the wire · VERIFIED 2026-08-22

Two findings from Supabase's Realtime authorization docs change this design:

1. **Private channels need a dashboard toggle.** RLS policies on
   `realtime.messages` govern who may broadcast to or receive from a topic, but
   enforcement only applies once **"Allow public access" is disabled** in Realtime
   Settings *and* the client instantiates the channel with `private: true`. Miss
   either and the channel is open regardless of policy. Absent from the earlier
   draft; this is a required provisioning step, not a code change.

2. **RLS is evaluated at join time, not per message.** Permissions are computed when
   the WebSocket connects and the topic is joined, then held for that connection.
   **So RLS cannot time-gate the answer** ("withhold pre-reveal, permit at reveal") —
   such a policy would silently never re-evaluate. The gate must be *what the server
   chooses to emit*, which is what this design already does: the answer appears only
   in the reveal broadcast. That approach is now confirmed as the **only** workable
   one, not a stylistic preference.

Also confirmed: Realtime does not persist anything to `realtime.messages` — it
queries the policy and rolls the transaction back — so private channels add no
storage cost. And RLS on that table is explicitly permitted, even though the
`realtime` schema otherwise rejects new tables and functions
(`permission denied for schema realtime`).

**New performance constraint.** Supabase warns that RLS complexity raises connection
time and lowers join rates. With up to 8 players joining inside a 20 s round, the
`realtime.messages` predicate must stay cheap — a single indexed membership lookup,
no joins across live game state.

---

## 5. Curation pipeline

Decision 4 requires a pool restricted to anime the group would plausibly know.
AnimeThemes' full library skews obscure, and unguessable rounds are the main way
this game stops being fun.

### 5.1 Selection

AnimeThemes exposes **neither a popularity score nor a difficulty rating** — verified by
live GraphQL introspection on 2026-08-22, where the `Anime` type returned exactly:
`id, title, format, formatLocalized, season, seasonLocalized, slug, synopsis, year,
siteUrl, createdAt, updatedAt, synonyms, animethemes, images, resources, series,
studios`. No popularity, rating, rank, view-count or difficulty field exists.

This settles the "add a difficulty meter too if the api provides it" question directly:
**it does not provide one, so difficulty has to be derived locally** (§5.4).

The `resources` field gives
`MAL` and `ANILIST` IDs, but querying AniList for popularity at scale is exactly
the "mass collection" its terms prohibit (`doc/RESEARCH.md` §5), so that route is out.

Proposed instead: **a hand-built seed list.** The user names the anime the group
would recognise — realistically 100–500 titles — and the pipeline resolves each to
an AnimeThemes `anime.slug`, then to its themes.

This is the honest option. It is manual, it takes an evening, and it produces a
pool tuned to one specific friend group, which is better than any proxy metric.

**Open:** whether to seed from a public "most popular anime" list instead, to save
that evening. Needs a source whose terms permit it — unresearched.

### 5.2 Per-theme processing

1. Query the theme's video variants.
2. Apply the §4.8 precedence: `nc: true` mandatory → `subbed: false` →
   `overlap: NONE` → smallest `size`.
3. **Skip the theme entirely if no `nc: true` variant exists.**
   > **Do not reorder this precedence to save bandwidth.** Safety and size genuinely
   > conflict here: credit-free variants are typically the *largest* files — 1080p BD
   > rips. The verified median for `nc: true` variants is **~46.7 MB** (§3), against a
   > **26.1 MB** median across an unfiltered 100-video sample — credit-free really is the
   > heavier population, by roughly 1.8x. So
   > "just pick the smallest variant" systematically selects *against* `nc: true` and is
   > actively unsafe. `size` is a **tiebreak among already-safe candidates, never a
   > filter.** The bandwidth argument is weak anyway: every clip is re-encoded to ~1 MB
   > at step 6, so source size affects only the one-off ingest download, not per-game
   > egress.
4. **Download the source once.** Everything below is derived from that one file; the
   ~46.7 MB fetch is the expensive step and must not be repeated per asset.
5. **Extract the audio** — ~20 s from the musical body, Opus, ~160 KB.
6. **Extract ~60 candidate frames**, evenly spaced, skipping the first and last ~2 s so
   fades and hard cuts are excluded.
7. **Reject low-detail frames** (§5.2.1).
8. **Reject frames containing text** (§5.2.2). This is the step that protects the answer.
9. **Choose 2–3 survivors with temporal spread** (§5.2.3). Fewer than 2 → skip the theme.
10. **Choose the poster from the text-positive rejects** — the title card is the ideal
    reveal image, and step 8 has already identified it.
11. **Upload all five objects** to the `media` bucket under keys derived from three fresh
    uuids — one per asset class — **then** write the row via `ingest_question` v3. Objects
    first: a row pointing at bytes that never arrived is worse than an orphaned upload, and
    with five objects that window is five times wider.

Step 4's old form said "spot-check a frame visually". That was never going to scale to 136
themes and, per B-20, four sampled frames out of ~600 would not have caught the title cards
anyway. Steps 7—9 replace human spot-checking with per-frame filters.

#### 5.2.1 Detail filter — JPEG bytes vs the per-theme median

Encode each candidate at a fixed quality and reject any frame whose byte size is **below 45%
of the median for that theme**. Compressed size is a proxy for visual complexity, so this
removes fades, flat colour fields and near-black frames using nothing but the encoder already
in the pipeline.

**The median must be per-theme, not global.** One sampled theme's frames all fall below the
global median; a global cut would over-reject dark shows wholesale while barely touching
bright ones.

**Do not use brightness or `ffmpeg blackframe` for this.** Measured over 40 real frames, the
single worst frame in the set — a flat grey card — has mean luma **180.0** and ranks
**39th of 40** on brightness, so a brightness filter would rank it as one of the *best*
frames. Its real signature is luma std **0.2**, mean gradient **0.01**, and **1702 bytes
(19% of its theme's 8894-byte median)**. Luma std alone is also insufficient: a bimodal flat
frame measured the 3rd-highest std in the set while sitting at 48% of median. Full
measurements in `doc/RESEARCH.md` §4.10.

At 45% the cut rejects 3 of 40 frames and leaves every one of the ten sampled themes with
≥2 survivors.

#### 5.2.2 Text filter — OCR, tuned to over-reject

Two OCR engines run on each surviving candidate: `tesseract --psm 11` with `eng+jpn`, and
`rapidocr-onnxruntime` (pinned `<2`). A frame is rejected when **any** pass sees a single
word of at least `OCR_MIN_WORD` characters at confidence at least `OCR_MIN_CONF`. Passes
are merged worst-case. **A false positive costs one frame out of ~60; a false negative
ships the answer**, so the asymmetry is total.

**The measured rule is `longest_word >= 5` at confidence >= 70.** Both numbers come from
647 candidate frames dumped by pipeline run `32605150598`, not from intuition:

| Metric at conf >= 70 | Junk (noise) | Real title text |
| --- | --- | --- |
| longest word | p50 = 2, p95 = 3, max 13 | 5-13 |
| total chars | p50 ~4, p90 = 9, max 34 | overlaps junk completely |

Every one of the 18 frames (2.8%) with `longest_70 >= 5` was genuine text —
`ASSASSINATION(92)`, `BLACK(94) CLOVER(96)`, `gelBeals(90)`, `Musamit(86)`.

**Character-count gating was tried first and is disproven.** `chars_N` sums junk across the
whole frame, so it both over-rejected (an early run skipped 8 of 10 themes at
`chars_70 >= 4`) and under-rejected, because a real title card measured 43 chars — squarely
inside the junk range. It is not a matter of picking a better threshold: the distributions
fully overlap. No char-count backstop is OR-ed in for the same reason.

`OCR_MIN_WORD` is floored at 2 by a workflow guard, because 1 would reject every frame
containing a single stray glyph, which is most of them.

**Measured residual after adding the second engine: 2 of 36 shipped stills still carry
readable text.** Run `32617226964` rejected 46 candidates against run `32605150598`'s
baseline, and **all 14 newly-rejected frames were credited to `rapid`** — the second engine
earns its runtime. But the count fell from 3 to 2 by coincidence, not by fix: raising
`ocr_min_conf` to 70 changed which frames survive, so the spread groups reshuffled and
different frames shipped. Of the 6 leak frames identified by eye in the earlier run, **5 are
still classified `CLEAN`**, and the reshuffle introduced 2 leaks that had not shipped before.
The earlier run's eyeball does not transfer to a later run's output.

**The rule has two structural blind spots, not two missed thresholds:**

- **A — CJK length.** A Japanese name is 1-3 glyphs, so it can never reach a 5-character
  longest word. `AngelBeats-OP1` ts=45.1 has five names read at confidence 86-99
  (岩沢 / 関根 / ひさ子 / 入江 / 遊佐) and scores `longest_70 = 2`.
- **B — scattered or kinetic Latin typography.** Isolated large glyphs are segmented
  individually, so the longest token is 2 characters *at every confidence floor including
  zero*. `AnsatsuKyoushitsu-OP1` ts=78.0 is huge white Latin capitals over green stripes and
  scores `longest_0 = 2`. No confidence floor can rescue this one.

**No scalar in the current feature set separates the counterexamples.** All three frames
below are classified `CLEAN`, and on every metric the *clean* frame ranks highest:

| frame | longest_70 | chars_70 | words | max_conf | longest_0 | reality |
| --- | --- | --- | --- | --- | --- | --- |
| `AngelBeats-OP1` ts=45.1 | 2 | 6 | 39 | 99.5 | 5 | **LEAK** |
| `AnsatsuKyoushitsu-OP1` ts=78.0 | 2 | 6 | 29 | 89.5 | 2 | **LEAK** |
| `AoNoExorcist-OP1` ts=37.6 | 4 | 7 | 65 | 95.4 | 6 | clean |

**There is also no downward headroom.** Lowering `OCR_MIN_WORD` from 5 to 4 would reject
that clean cityscape frame — its `longest_70 = 4` comes from `ーーーー`, i.e. window
mullions — while still missing both leaks.

**The glyph-size hypothesis was tested on real data and falsified.** The tallest token across
all 16,038 — 0.69 of frame height at confidence 80 — is a hallucination on a **hair curve** in a
frame with no text at all. No threshold on any height, width or position scalar separates the
sets. Two corrections came out of that work, both recorded in full in **`doc/BLOCKERS.md` B-28**:
a re-eyeball found **three of five suspect labels were wrong** (including one frame written off
as an "uncatchable leak" that is simply clean), and single-token peak height was retired.

**The chosen rule is a union of two features, either of which can reject a frame:**

- **Coherence** — not one big glyph but a *group* of them: boxes of similar height sharing a
  baseline, weighted by confidence and by how many agree. This catches title text the OCR engine
  genuinely **read**, including short CJK names that blind spot A made invisible.
- **Large-box count** — how many text regions exceed 0.28 of frame height, deliberately with
  **no confidence floor**. A stylised logo is confidently *misread*, not confidently read: the
  worst leak in the set tops out at confidence 59 and scores zero on every confidence-weighted
  measure. This is a *segmentation* signal, and it closes blind spot B.

A frame is rejected when `max(coherence / 0.21, large_boxes / 3) >= 1.0`. A precondition for
either feature to work is **de-duplicating detections across OCR passes** — the same box found
by both the original and 2× pass is one observation, not two, and counting it twice made the
worst false positive the highest-scoring frame in the set.

The large-box threshold is **3, not 4**, for a mechanical reason worth preserving: the leak it
targets has four large boxes, but one is a degenerate full-frame detection — an artifact, not a
glyph. A threshold of 4 would catch that leak *only by counting the artifact*, and would miss it
if an engine update stopped emitting it. Three catches it either way.

Measured against the corrected labels: **4 of 4 known-bad frames caught, 0 missed, 0 known-bad
frames promoted into the ship set**, at a cost of 5 clean frames — with every theme still able to
yield its 3 stills (worst theme retains 33 candidates). **This rule is priced but not yet
shipped**: it is not implemented in the pipeline, and 7 frames it newly promotes have not been
eyeballed. B-28 stays open until both are done. `jpn_vert` was dropped along the way because
across all 647 frames it produced no high-confidence word while costing a pass per frame.

One cost worth recording: raising `ocr_min_conf` to 70 cost 3 of 12 themes their poster,
which fell back to `fallback-clean-unused` (§5.2 step 10).

This is the *only* protection against a title card reaching the player, because
`nc: true` was measured not to provide any (§3): 5 of 10 sampled clips showed the Latin
title with `nc:true, subbed:false`. Leaks are not positional either — one sat at 79.5 s of a
90 s clip, another at 39.1 s — so no edge-trim heuristic substitutes for reading the frame.

#### 5.2.3 Spread — best frame from each third

Split the surviving candidates into three equal spans **by count** over their sample order and
take one from each. This guarantees the three stills come from different moments, so the
progressive reveal adds genuinely new information rather than three near duplicates of one shot.
With fewer than three survivors it falls back to two spans, and with fewer than two it yields
nothing.

Within a span the winner is the **largest encoded JPEG**, used as a cheap proxy for visual
detail — not a re-measured detail score, which the earlier wording implied. Byte size is a proxy
worth naming honestly, because it is the reason a *planned* change is pending: once the text
filter produces a continuous risk score per frame (§5.2.2) the selector should prefer the
**lowest-risk** survivor in each span and use bytes only to break ties, so that removing a leak
cannot promote the next-most-suspicious frame in its place. That regression is invisible to a
keep/drop count and is the reason the calibration harness simulates the whole ship set rather
than counting rejections.

Perceptual hashing to deduplicate is deliberately **not** used: thirds already enforce
temporal distance, and a hash threshold would be one more tuned constant with no measured
basis.

### 5.3 Question bank row

A single Postgres table (`doc/RESEARCH.md` §3.5). Read-only to clients except through the
guess-checking function; the answer-bearing columns are not exposed (§4.4).

```
id, asset_slug, poster_slug, audio_slug, still_count, audio_seconds, bytes_total,
anime_slug, title_romaji, title_english, title_native,
synonyms_json, year, season, theme_type, theme_sequence,
song_title, cover_image_url, anilist_id, mal_id, difficulty
```

`clip_key` is gone as of migration `20260823000010`. It was `r2_key` before the stack
decision, then `clip_key`, and is now nothing at all: no object key is stored on the row.
Keys are computed from the three slugs by `question_asset_keys`, so the Storage layout
exists in exactly one place and a row can never disagree with the bucket.

The three slugs are uuids *separate from `id`*, and separate from each other, because they
need different visibility: `id` is client-readable via `rounds.question_id`, so anything
derived from it is effectively public — and the poster is the title card, so it must not be
derivable from the stills a player is legitimately sent either. Migration
`20260823000011` split what had been one `asset_slug` into three roots for that reason.
`doc/DATA-MODEL.md` §3.1 has the full argument.

At ~400 bytes/row, 500 rows is ~200 KB — trivially inside any plausible free
storage allowance, which is what retired B-6.

The list above is a sketch. **`doc/DATA-MODEL.md` §3.1 is authoritative** for the real
column set, types and constraints; if the two disagree, `doc/DATA-MODEL.md` wins.

### 5.4 Difficulty — computed, not fetched

§5.1 established that AnimeThemes supplies no popularity or difficulty field. Difficulty
is therefore derived at curation time from fields it *does* supply, written to a stored
integer, and recomputed by re-running the pipeline. Schema in `doc/DATA-MODEL.md` §5.

**Signals actually available**, roughly strongest to weakest as proxies for "would this
group recognise it":

| Signal | Reasoning |
| --- | --- |
| `theme_type` (OP vs ED) | Openings are far more recognisable than endings. The single most useful signal available. |
| `theme_sequence` | OP1 is usually the iconic one; OP5 of a long-running show is not. |
| `format` | `TV` is broadly known; `OVA` / `ONA` / `MOVIE` skew niche. |
| `series` membership | Part of a franchise implies reach beyond a single cour. |
| `year` / `season` | Recency bias is real in a friend group, but cuts both ways — classics are also well known. Weak and non-monotonic. |
| `synonyms` count | Heavily-localised titles tend to be larger releases. Very weak; use as a tiebreak at most. |

**The weighting is deliberately left unspecified.** Any formula written now would be
invented, and this is exactly the kind of parameter that only playtesting can set. The
schema commits solely to *a stored, filterable, recomputable integer* — deliberately not
to how it is calculated, so the formula can change without a migration.

**The honest caveat, which matters more than the formula.** The strongest predictor of
difficulty is "does *this specific group* know this show", and no computable signal
captures it. The hand-built seed list (§5.1) already encodes that judgement far better
than any of the fields above. So difficulty here is a **relative ordering inside an
already-curated pool**, not an absolute measure — it exists to keep one game from serving
six deep-cut EDs in a row, not to gatekeep unknown anime. That job is already done by
curation.

Consequently it should drive **round composition** (spread tiers across a game's rounds)
rather than a hard filter. Whether the host can also pick a difficulty band at room
creation is an open product question, not a schema one. Tracked as B-11 item 9.

---

## 6. Rooms, identity and scoring

### 6.1 Identity — no accounts

Room code (4 chars, Crockford base32) plus a display name, held in a `rooms` row in
Postgres. No auth provider, no email, no PII, no extra free tier to budget for. A
player is a WebSocket connection plus a name; a short-lived cookie or `localStorage`
token allows reconnecting to the same seat after a refresh.

This is the right call for a friends' game and it removes an entire category of
work. It does mean no cross-session profile or lifetime stats — see §8.

### 6.2 Scoring

**DECIDED 2026-08-22 — winner-takes-all per round.** Only the **first correct** guess in
a round scores; every other guess scores `0`, correct or not. This settles B-22, where
this section and `doc/DATA-MODEL.md` §6.2 had been specifying two different games.

The winner scores **100 plus a speed bonus** decaying linearly from 100 to 0 across the
guess window: winning on the first second is worth 200, winning on the last second 100.
Wrong submissions cost nothing — free-text guessing should not be punished, or players
stop typing.

> **One inference here, cheap to override.** The decision settled *who* scores, not
> whether the winner's total varies with speed. The bonus is kept because without it every
> win is worth exactly 100, `guesses.points` degenerates into a restatement of "rounds
> won", and winning early stops being worth anything. To go flat instead, delete the
> bonus — no schema change either way.

**All correct tiers earn full credit.** Exact, near (typo inside the Levenshtein
threshold, §4.3), season-lenient and prefix all score identically, so the points
expression needs no per-tier factor. A fast sloppy near-match therefore beats a slower
exact one. That is deliberate: the game measures how fast you *recognise* the anime, not
how accurately you type it.

**Known cost of this model.** Exactly one player scores per round, so a strong player can
open a lead that is arithmetically unreachable before the final round, leaving everyone
else playing for nothing. That is the same objection which rules out a streak multiplier —
**still rejected**, since it compounds the problem rather than softening it. Accepted
deliberately because it matches the stated loop, "the one who gets the correct fastest
wins". If it plays badly with friends, the cheapest remedy is consolation points for later
correct guesses: a one-line change to the exception branch in `doc/DATA-MODEL.md` §6.2, with
no schema change and no migration.

### 6.3 Timing and fairness

**Postgres is the clock**, not the client and not a game-server process. The round's
`started_at` and `ends_at` are written server-side — as is `rooms.deadline`, which must
equal `ends_at` for the current round (`doc/DATA-MODEL.md` §4.3; written by `start_game` §6.5
for round 1 and by `advance_round` §6.4 thereafter, each taking both values from one
statement so they cannot drift — B-23, B-24) — and a guess is graded by a
`SECURITY DEFINER` function that stamps `submitted_at = now()` itself — the client
never supplies a timestamp, so an early-timestamp claim is not expressible. The speed
bonus derives from `now() - round.started_at`. A player on a slow connection is not
penalised for render lag, but the same latency asymmetry exists as with any
server-authoritative design.

Round *progression* cannot be a long-running server loop: a full game is
10 × (20 s + 8 s) = **280 s**, and Supabase Edge Functions cap at **150 s**
(`doc/RESEARCH.md` §3.5). Instead any client may attempt an idempotent conditional
`UPDATE` (`WHERE state = 'playing' AND now() >= deadline`), with a `pg_cron` sweep as a
liveness net for the case where every client has left. Consequence to accept: round
boundaries are *"at least 20 s"*, not exactly 20 s.

**Why this is safe against double-advance · VERIFIED 2026-08-22.** From PostgreSQL's
documentation source (`doc/src/sgml/mvcc.sgml`, §13.2.1 Read Committed):

> *"the would-be updater will wait for the first updating transaction to commit or roll
> back … The search condition of the command (the `WHERE` clause) is **re-evaluated** to
> see if the updated version of the row still matches the search condition. If so, the
> second updater proceeds with its operation using the updated version of the row."*

Applied here: two clients race the same `UPDATE`. The second blocks until the first
commits, then re-evaluates its `WHERE` against the *updated* row. The first writer has
already pushed `deadline` into the future, so `now() >= deadline` is now false, the row
no longer matches, and the second updates **0 rows**. It cannot double-advance.

> **⚠️ The load-bearing requirement, easy to get wrong.** This only holds because the
> guard predicate tests a column **the same `UPDATE` mutates** (`deadline`). A guard of
> merely `WHERE state = 'playing'` — where `state` is *not* changed by the statement —
> would re-evaluate to **true**, and both writers would advance the round. **The guard
> column and a mutated column must be the same column.** Any future edit to this
> statement has to preserve that property or the idempotency is silently lost.

Two caveats worth recording: this is **`READ COMMITTED`-specific** behaviour, which is
Postgres's default and what Supabase/PostgREST use — under `REPEATABLE READ` the second
writer instead receives a serialization failure and would need retry logic. And the
re-read semantics are subtle enough in practice that they have their own
frequently-cited confusion (`stackernews/stacker.news` documents the same reasoning for
payment idempotency, citing *"postgres read committed doesn't re-read updated row"*).

Clips are prefetched during ROUND_REVEAL of the previous round so playback starts
instantly and no one waits on buffering. This is why 20 s rounds work at all.

---

## 7. What this design does not need

Worth recording, because earlier drafts assumed otherwise:

- **No trace.moe** — at runtime or at curation time.
- **No AniList API calls** — AnimeThemes supplies titles, synonyms, year and
  self-hosted cover art.
- **No auth provider** — anonymous sessions only (§6.1).
- **No dedicated game-server process** — no container, no VM, no always-on Node
  process. Postgres holds authoritative state and Realtime carries the fan-out.
- **No paid tier anywhere.** Every component sits inside a verified free allowance.

Two entries were removed here after the 2026-08-22 stack decision, because they were
false:

- ~~"No external database — Durable Object SQLite is sufficient."~~ The design now
  depends on **Postgres as the authoritative datastore** (`doc/RESEARCH.md` §3.5). This is
  not a regression — it is the same state, in a different engine — but it is no longer
  true that we need no database.
- ~~"…with at least an order of magnitude of headroom."~~ **No longer true.** On the
  mandated stack the two binding quotas are Supabase Storage at **50%** of 1 GB (2×)
  and unified egress at roughly **4×** expected usage (§3). Order-of-magnitude headroom
  was a property of the Cloudflare design (R2: 7.5% storage, unmetered egress), and it
  was traded away deliberately for single-vendor simplicity. Everything still fits; the
  margin is now single-digit, and one axis has a hard cliff (**B-13**).

---

## 8. Open decisions

Ordered by how much they block.

1. ~~**§3 media delivery** — Option A or B.~~ **DECIDED 2026-08-22: Option B, into
   Supabase Storage at ~1 MB per clip.** See §3. *No longer blocking.*
2. ~~**§3 transcode location** — GitHub Actions assumed; `ffmpeg` availability
   unverified.~~ **RESOLVED (B-12): GitHub Actions is viable, but `ffmpeg` is NOT
   preinstalled on `ubuntu-latest`** — the workflow must install it explicitly. See
   `doc/RESEARCH.md` §3.7.
3. **§5.1 curation source** — hand-built seed list, or a public popularity list.
   *Blocks the curation pipeline.*
4. ~~**§4.3** — full or partial credit for season-lenient matches.~~ **DECIDED 2026-08-22
   (B-22): full credit**, for every correct tier. No per-tier factor in the points
   expression.
5. ~~**§6.2** — streak multiplier: recommend no.~~ **DECIDED 2026-08-22: no.** The
   winner-takes-all choice (B-22) strengthens the case rather than weakening it — scoring
   already concentrates in one player per round, so a multiplier would compound the lead
   problem instead of offsetting it.
6. **Round and game length — DECIDED 2026-08-22.** Player-selectable **3–20 rounds**
   at room creation, default 10, at ~28 s per round (20 s clip + 8 s reveal). Total
   wall-clock is `rounds × 28 s` → 84 s / 280 s / **560 s** at 3 / 10 / 20. The
   consequence below still holds and in fact gets worse at the top of the range: the
   game cannot run as one Edge Function invocation (150 s ceiling), which rules the
   loop out above roughly 5 rounds. Superseded text retained for context:
   ~~**Round and game length**~~ — 20 s / 10 rounds assumed throughout. Now has a second
   consequence: it sets the 280 s game length that rules out running a game as one
   Edge Function invocation (§6.3).
7. **Persistence** — nothing survives a game today. Do you want a leaderboard or
   match history? Postgres is now in the stack regardless, so this is a product
   question rather than an infrastructure one.

Newly opened by the stack decision:

8. **Server authority design — verified, B-17 closed.** Reviewed 2026-08-22 against
   primary docs and production code; **all four sub-claims are settled, and none
   survived unchanged.** One was actively wrong: the answer-column grant model was a
   no-op that would have published every answer via PostgREST — corrected in §4.4.1.
   The other three were directionally right but each missing a load-bearing step:
   `SECURITY DEFINER` needs `SET search_path = ''` (§4.4.2); Realtime private channels
   need the dashboard toggle *and* client flag, and their RLS is join-time so it cannot
   time-gate anything (§4.4.3); the round-advance guard is only idempotent because it
   tests a column the same `UPDATE` mutates (§6.3). The lesson worth carrying into
   implementation: in this design the details *are* the guarantee.
9. **Does pg_graphql bypass the answer-column grants? (B-18, new.)** §4.4.1 gates
   PostgREST. Supabase also ships pg_graphql, and dedicated lints (`0026`/`0027`) exist
   for tables exposed over it. Whether column-level grants are enforced per-field there
   is unexamined. Cheap to check, and cheap to neutralise — this design never uses the
   GraphQL endpoint, so disabling it outright is an acceptable answer.
10. **What happens at the Supabase egress cliff is unverified (B-13).** ~4× headroom is
    fine; the failure mode at 100% is not documented in our research. Searched
    2026-08-22 — negative, but the relevant pages truncated before their closing
    sections, so this is a retrieval limit rather than a proven documentation gap.
11. **Mobile or desktop first** — affects layout only, not architecture.
