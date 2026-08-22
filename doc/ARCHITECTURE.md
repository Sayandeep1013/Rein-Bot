# ReIN Bot — Architecture

Status: **first draft, 2026-08-22.** No code exists yet. This document describes the
intended system, not a built one.

Numbers cited as verified come from `doc/RESEARCH.md`. Blockers referenced as `B-n` come
from `doc/BLOCKERS.md`. Game rules come from `doc/GAME-DESIGN.md`; the data schema is in
`doc/DATA-MODEL.md`.

> **§5.2 was ratified by the user on 2026-08-22.** Guess submission goes to a Postgres
> function; everything else server-shaped stays in Edge Functions. The rejected alternative
> is still recorded inside §5.2 for the reasoning trail, but it is no longer an open
> decision and no longer the one section that would change.

> **Verified against the live project on 2026-08-22.** The Supabase MCP is still bound to an
> unrelated project (`deslckxkuvbfugdxibdn`), so verification was carried out over the
> Management API instead — §10.1 records exactly what was confirmed (project identity,
> region, Postgres version, empty `public` schema, installed extension set). The misbinding
> is mitigated by a project-local `opencode.json` and needs only an opencode restart to
> confirm; until that restart, treat MCP output as untrusted. Tracked as B-19.

---

## 1. What the system has to do

Friends open a URL, one creates a room, the others join by code or link. Each round
every player sees the same muted anime opening, types a guess, and the first player
graded correct scores. After a configurable 3–20 rounds, highest score wins.

Three properties drive every decision below:

1. **The answer is graded by a server, not the browser.** Not for secrecy — the user
   has explicitly dropped that goal — but because "who was correct first" is
   meaningless if each client decides for itself.
2. **A game outlives any single compute invocation.** At the 10-round default a game runs 280 s, and 560 s at 20 rounds; only a game of five rounds or fewer fits in one invocation, since
   the Edge Function ceiling is 150 s (`doc/RESEARCH.md` §3.5). Nothing may be a
   long-running loop.
3. **Media is ~98% of resource consumption.** Every media decision is a quota
   decision.

---

## 2. Stack

| Layer | Choice | Why |
| --- | --- | --- |
| Frontend | Vercel Hobby (static + client JS) | Free, no domain needed. Edge Functions *cannot* serve HTML without a custom domain (`doc/RESEARCH.md` §3.5) |
| Realtime transport | Supabase Realtime | Only free option that survived review; 200 peak connections |
| Authority / state | Supabase Postgres | Transactional; see §4 |
| Server logic (data) | Postgres functions via PostgREST | One hop, atomic; §5.2 |
| Server logic (outside world) | Supabase Edge Functions | `fetch()`, secrets, real libraries; §5.3 |
| Media storage | Supabase Storage | Opaque keys, our own bucket |
| Transcode | GitHub Actions + ffmpeg | Edge Functions cannot run native binaries (B-12, `doc/RESEARCH.md` §3.5) |
| Content source | AnimeThemes.moe | No key, no auth, stable URLs (`doc/RESEARCH.md` §4) |

**Rejected:** Vercel Functions as room server (300 s cap vs 280 s game, billed live,
no cross-instance state — `doc/RESEARCH.md` §3.8); Cloudflare Durable Objects (stack
mandated to Vercel + Supabase); trace.moe as content source (it is a labeller, not a
source — `doc/RESEARCH.md` §1.1); AniList (terms prohibit mass collection, §5).

---

## 3. Component map

```
                    ┌─────────────────────────────┐
   one-off /         │   GitHub Actions (ffmpeg)   │
   scheduled         │   transcode → ~1 MB clips   │
                     └──────────────┬──────────────┘
                                    │ upload
┌──────────────────┐                ▼
│ AnimeThemes.moe  │◄──fetch──┬──────────────────┐
│  GraphQL + CDN   │          │  Edge Functions  │
└──────────────────┘          │  ingest, curate, │
                              │  difficulty calc │
                              └────────┬─────────┘
                                       │ writes question bank
                                       ▼
┌──────────────┐   Realtime    ┌──────────────────────────┐
│              │◄─────────────►│  Supabase Postgres       │
│  Browser     │   (transport) │  ── AUTHORITY ──         │
│  Vercel-     │               │  rooms, rounds, guesses  │
│  hosted      │──── RPC ─────►│  grade_guess()           │
│              │  (guesses,    │  advance_round()         │
│              │   room ops)   │  + pg_cron liveness      │
└──────┬───────┘               └──────────────────────────┘
       │
       │ signed/opaque URL
       ▼
┌──────────────────┐
│ Supabase Storage │
│  clip bucket     │
└──────────────────┘
```

Note what is *not* on the diagram: no persistent room server, no WebSocket server of
ours, no queue, no cache layer, no Redis. §11 explains why none is needed.

---

## 4. Authority model

**Postgres is the single source of truth.** Everything else is transport, presentation,
or a producer that writes into it.

This is worth stating precisely, because "use Edge Functions as the source of truth"
was the original instruction and the distinction is subtle:

> *Source of truth* is a property of the **database**, not of the compute layer.
> Postgres holds the truth whether validation code runs in Deno or in PL/pgSQL. The
> real question is where validation sits **relative to the data it validates** —
> because that determines whether check-and-write can be interleaved by another
> player.

Concretely, the authority rules:

| Fact | Decided by | Never trusted from |
| --- | --- | --- |
| Whether a guess is correct | `grade_guess()` in Postgres | client |
| When a guess arrived | `now()` inside the grading transaction | client clock |
| Who was first correct | partial unique index on `(round_id)` | application logic |
| Current round / deadline | `rooms` row | client |
| Score | derived from `guesses` rows | client |

**What is deliberately *not* defended.** The user has dropped secrecy as a goal
("if the players want to cheat they will"). So there is no column-grant apparatus, no
answer-withholding scheme, and B-18 is moot. The round payload simply omits the answer
because there is no reason to include it — that costs zero engineering. Server-side
grading and server timestamps are retained for **fairness and clock skew**, not
anti-cheat.

---

## 5. Compute split

### 5.1 The rule

> Touches only our own data, and must be fast or atomic → **Postgres function.**
> Touches the outside world, or needs real libraries/secrets → **Edge Function.**
> Needs a native binary → **GitHub Actions.**
> Presentation only → **client.**

### 5.2 Guess submission → Postgres function · DECIDED 2026-08-22

**Decision, ratified by the user 2026-08-22:** `grade_guess` is a `SECURITY DEFINER`
Postgres function called via PostgREST, not an Edge Function. This is the **single**
carve-out from an otherwise Edge-Function-owned server layer — §5.3 keeps everything else,
and the client still grades nothing, supplies no timestamp, and receives no answer.

**Rationale.** An Edge Function must check-then-write across two round trips, and
another player's request can interleave between them:

```
P1 isolate: read round → grade correct → "anyone won?" → no
P2 isolate: read round → grade correct → "anyone won?" → no
P1 isolate: INSERT winner
P2 isolate: INSERT winner        →  two winners for one round
```

Closing that requires a unique constraint — **which lives in Postgres**. So Postgres
enforces the actual guarantee either way, and the Edge Function has contributed only
latency. In a Postgres function the same work is one statement
(`INSERT ... ON CONFLICT DO NOTHING` against a partial unique index, with `now()`
evaluated in that transaction) and the race cannot occur.

**Secondary rationale — fairness, stated honestly.** Neither design is perfectly fair:
players in different cities have different round-trip times to a single-region database
no matter what we build. The difference is that the Edge Function path *adds a second*
source of unfairness which is noisy rather than merely unequal — cold starts hit some
requests and not others, and Edge Functions are geographically distributed while the
database is in one region, so the function→database leg varies per player. Base RTT is
unequal but stable; added edge variance is unequal *and* unpredictable. In a game
decided by human reaction differences of 100–300 ms, the unpredictable component
decides winners.

**Rejected alternative:** Edge Function as the guess endpoint. It works, and it was the
original instruction. It costs a variable-latency hop on the one path where latency
determines the winner, and it still needs the Postgres constraint for correctness.

### 5.3 What Edge Functions own

These are the cases where an Edge Function is clearly right and Postgres clearly wrong
— all of them need `fetch()`, a secret, or library code:

- **AnimeThemes ingest** — query their GraphQL API, page through results
- **Curation and difficulty computation** — §8
- **Transcode orchestration** — dispatch the GitHub Actions job, track completion
- **Storage upload** of finished clips
- Any future third-party webhook

Postgres *can* make outbound HTTP calls via `pg_net`, but it is asynchronous and
awkward; this is not a close call.

**Hard limits that shape these functions** (`doc/RESEARCH.md` §3.5): 150 s wall clock,
**2 s CPU**, 256 MB memory, no Web Worker API, **no multithreaded native libraries**.
That last one is why transcode is not here — ffmpeg cannot run in an Edge Function.

### 5.4 What Postgres functions own

- `grade_guess(round_id, guess)` — normalise, match, stamp, claim-first, score
- `advance_round(room_id)` — the idempotent conditional `UPDATE` of §7
- `create_room(settings)` — atomic unique room-code claim
- `join_room(code, display_name)`
- Score aggregation reads

### 5.5 What GitHub Actions owns

ffmpeg transcode of source video → ~480p / ~20 s / ~1 MB clip. Resolved in B-12;
concurrency on the free plan resolved in B-8.

### 5.6 What the client owns

Rendering, playback, the guess input box, optimistic UI. It holds no authority. It
does not grade, does not supply timestamps, and is not given the answer before reveal.

---

## 6. Request paths

**Create room.** Client → `create_room()` RPC → row inserted with `round_count`
(3–20), difficulty filter, `state = 'lobby'` → client subscribes to the room's
Realtime channel → shareable code/link rendered.

**Submit guess.** Client → `grade_guess()` RPC → single transaction: normalise input,
compare against the accepted-answer set (`doc/GAME-DESIGN.md` §4.1–4.3), stamp `now()`,
attempt the first-correct claim, write the `guesses` row → verdict returned to the
caller → Realtime broadcasts the scoreboard delta to the room.

One hop. The timestamp is taken inside the transaction that authorises the write, so
there is no window between deciding and recording.

**Advance round.** See §7 — no request path; any client or `pg_cron` can trigger it.

---

## 7. Round progression without a room server

This is the load-bearing constraint. At the default 20 s round + 8 s reveal, a game runs
`rounds × 28 s` — 84 s at the 3-round minimum, 280 s at 10 rounds, **560 s at the 20-round
maximum**. The Edge Function ceiling is 150 s. **No single invocation can drive a game to
completion at any setting above 5 rounds**, so progression must be stateless and idempotent
rather than a loop. Note this rules out the loop approach for most of the supported range,
not just the top of it.

**Mechanism.** Any client whose local timer expires fires `advance_round()`, which runs:

```sql
UPDATE rooms
   SET current_round = current_round + 1,
       deadline = now() + round_duration
 WHERE id = $1
   AND state = 'playing'
   AND now() >= deadline;
```

Eight clients firing this simultaneously advance the round exactly once. Verified from
PostgreSQL's own documentation (`doc/src/sgml/mvcc.sgml` §13.2.1, closed as B-17):
under `READ COMMITTED` a blocked `UPDATE` re-evaluates its `WHERE` clause against the
committed updated row, so the losing writers match zero rows.

**The caveat is not incidental.** This is only safe because the guard tests
`deadline` — a column the same statement mutates. A guard on `state` alone would
re-evaluate true and every writer would advance. Any future edit to this statement must
preserve that property.

> **B-23 and B-24 resolved 2026-08-22 — this statement is now specified completely.** It
> stamps the newly-current `rounds` row (`started_at`, and `ends_at` taken from the *same*
> `deadline` value this `UPDATE` wrote, not a second `now() + round_duration`), gated on
> `if not found then return; end if;`. Ungated, the seven losing callers would re-stamp
> `started_at` and slide the round window forward on every call, reintroducing precisely
> the bug B-17 closed. The reveal broadcast sits behind the same gate, and so does the
> `pg_cron` sweep below — it calls this same function and therefore inherits both
> properties rather than needing its own copy of them.
>
> **A second gap surfaced while fixing the first: nothing transitioned `lobby → playing`.**
> This statement cannot do it, because a lobby room has `deadline IS NULL` and
> `now() >= NULL` evaluates to `NULL`, so it matched zero rows *forever* — no client poll
> and no `pg_cron` sweep could ever have started a game. Round 1 is now stamped by
> `start_game` (`doc/DATA-MODEL.md` §6.5), whose guard is safe for a different reason than this
> one: it tests `state = 'lobby'` and writes `state = 'playing'`, so it does mutate the
> column it guards on — which is exactly why `state` is a valid guard there and an invalid
> guard here.

**Liveness net.** If every client disconnects mid-game the room would freeze, so a
`pg_cron` sweep runs the same idempotent statement periodically. `pg_cron` is available
on Free and supports sub-minute schedules (`doc/RESEARCH.md` §3.5). This also incidentally
mitigates B-16, the 7-day inactivity pause, by keeping the project minimally active.

---

## 8. Content pipeline

Runs offline, never on the hot path. Because AnimeThemes media URLs are stable with no
expiry token (`doc/RESEARCH.md` §4.5), the question bank is built once and replayed
indefinitely.

```
AnimeThemes GraphQL ──► filter/select ──► download source ──► ffmpeg
                                                                 │
                          question bank row ◄── upload ◄─────────┘
                          (+ computed difficulty)
```

### 8.1 Variant selection — safety before size

A theme usually has several video variants. Selection precedence is fixed
(`doc/RESEARCH.md` §4.8):

1. **`nc: true` mandatory** — a credited video burns the show's title logo into the
   picture and hands over the answer. A theme with no `nc: true` variant is **excluded**,
   not used with a warning.
2. `subbed: false` — subtitles can carry translated titles.
3. `overlap: NONE` preferred.
4. *Then* smallest `size`.

**This ordering costs bandwidth and that is accepted.** Credit-free variants are
typically the 1080p Blu-ray rips, i.e. the largest files — median 26.1 MB across a
100-video sample. "Pick the smallest" is actively unsafe. The transcode step is what
makes this affordable: we pay the large download once at curation and serve ~1 MB.

`doc/RESEARCH.md` §4.8 flags as **unverified** whether `nc: false` reliably implies
on-screen text; a visual spot-check during curation is required rather than trusting
the flag.

### 8.2 Available filters

Introspected live 2026-08-22 against `https://graphql.animethemes.moe/`.

`animethemeShuffle` accepts only: `type, format, year_lte, year_gte, spoiler, first,
page`.

The richer levers exist **only on the pagination endpoints** — `animethemePagination`
adds `sequence`, `sequence_lesser/greater`, `type_in`; `animePagination` adds `season`,
`season_in`, `format_in`, `where`, `sort`; `videoPagination` adds `resolution`,
`resolution_lesser/greater`, `size_lesser/greater`, `nc`, `subbed`, `uncen`, `overlap`,
`lyrics`; `animethemeentryPagination` adds `nsfw`, `spoiler`, `version`.

**Consequence:** shuffle alone cannot express our selection rules. Curating offline
into our own bank resolves this — we filter locally against our own columns and never
fight the asymmetry at runtime.

### 8.3 Difficulty

**AnimeThemes exposes no difficulty field.** The full `Anime` type is `id, title,
format, formatLocalized, season, seasonLocalized, slug, synopsis, year, siteUrl,
createdAt, updatedAt, synonyms, animethemes, images, resources, series, studios` —
no score, popularity, rank, members, or favourites. It is a themes archive, not a
ratings site.

Difficulty is therefore **our own column, computed at ingest** from available proxies:

| Proxy | Direction | Source |
| --- | --- | --- |
| `year` | older → harder | `Anime.year` |
| `type` OP vs ED | ED → markedly harder | `AnimeTheme.type` |
| `sequence` | OP5 → harder than OP1 | `AnimeTheme.sequence` |
| `format` | OVA/ONA/SPECIAL → harder than TV | `Anime.format` |

Weighting is unresolved and deliberately left open — it needs playtesting, not
theorising. Recorded in `doc/GAME-DESIGN.md` §8.

**Honest limitation:** none of these proxies measures *recognisability*, which is what
difficulty actually means here. A 2005 OP from a famous long-running series may be far
easier than a 2023 OP from an obscure ONA. Without an external popularity signal — and
AniList's terms rule out mass collection (`doc/RESEARCH.md` §5) — this stays a heuristic.
Curation from a hand-picked seed list the group actually knows is the real quality
control (B-11 item 2).

---

## 9. Realtime transport

Realtime carries **notifications, never authority**: round-start, scoreboard deltas,
reveal payloads, presence.

Three verified properties shape usage (`doc/RESEARCH.md` §3.5):

- **Messages are not persisted** → no storage cost, but also no replay. A client that
  misses a broadcast must recover by reading the `rooms` row. Every broadcast must
  therefore be reconstructible from database state.
- **RLS on `realtime.messages` is evaluated at join time, not per message.** You cannot
  time-gate a payload through RLS. This is why reveal data is *broadcast at reveal*
  rather than preloaded and gated.
- Private channels require the dashboard "Allow public access" toggle **disabled** *and*
  client `private: true`. Both, or the channel is open.

Ceiling: **200 peak connections** = ~25 concurrent 8-player rooms.

---

## 10. Quota budget

### 10.1 Live project facts · VERIFIED 2026-08-22

Confirmed against the Supabase Management API using the project PAT:

| Fact | Value |
| --- | --- |
| Project name | `ReIN Bot` |
| Project ref | `mxkqivivqultfuattuin` |
| Region | `ap-south-1` |
| Status | `ACTIVE_HEALTHY` |
| Postgres | **17.6** (reported `17.6.1.155`) |
| Organization | `ujnsnnblxvyhirfjklik` — "Personal Projects" |
| Org plan | `free` |
| `public` tables | **none** — genuinely fresh |
| Database size | ~10 MB (system baseline) |

Extension availability verified live and matches `doc/DATA-MODEL.md` §2 exactly: `unaccent` 1.1,
`fuzzystrmatch` 1.2, `pg_trgm` 1.6, `pg_cron` 1.6.4 all **available, none installed**;
`pgcrypto` 1.3 **already installed**. `pg_graphql` is **not installed** (which closes B-18).

### 10.2 Quota scoping — CORRECTED

Free-plan figures (`doc/RESEARCH.md` §3.5): egress **5 GB uncached + 5 GB cached**, storage
**1 GB**, database **500 MB**, Edge Function invocations **500,000/mo**, Realtime **2 M
messages** and **200 peak connections**.

> **Correction, 2026-08-22.** An earlier draft of this section assumed ReIN Bot had the
> full 5 GB egress allowance to itself. **It does not.** On the Free plan these
> allowances are billed at the **organization** level, and `ReIN Bot` shares organization
> `ujnsnnblxvyhirfjklik` with a second active project, **`Mubitracker`**
> (`deslckxkuvbfugdxibdn`, also `ACTIVE_HEALTHY`). Whatever Mubitracker consumes is
> subtracted from ReIN Bot's headroom.

So the formula's numerator is not a constant either:

```
games/month ≈ (5 GB − egress already consumed by Mubitracker) ÷ (rounds × players × ~1 MB)
```

| Rounds | 8-player games/mo @ full 5 GB | @ 2.5 GB (even split) |
| --- | --- | --- |
| 3 | ~208 | ~104 |
| 5 | ~125 | ~62 |
| 10 | ~62 | ~31 |
| 20 | ~31 | ~15 |

The right-hand column is not a prediction — it illustrates that a co-tenant project can
**halve** capacity. At 20 rounds and a busy co-tenant, ~15 games/month is a real
possibility, which is thin.

**This is measurable, and I could not measure it.** The Management API endpoints
`/v1/organizations/{slug}/usage` and `/v1/organizations/{slug}/billing/subscription` both
return **404**, so current consumption cannot be read programmatically with this PAT.
~~**Action required from the user:** read actual egress in the dashboard under
Organization → Usage before we commit to a round-count default. Tracked as **B-21**.~~
**RESOLVED 2026-08-22 (B-21):** the user read the dashboard — **0% egress consumed**.
Mubitracker has used effectively nothing, so the full-5 GB column below is the live
budget. Residual risk (co-tenant starts consuming later; org-wide restriction) is
accepted for launch; moving ReIN Bot to its own organization remains recommended
pre-launch hardening, not a blocker.

Two mitigations, in preference order:

1. **Move ReIN Bot into its own organization.** Free plan permits multiple orgs, each with
   its own allowance, so this restores the full 5 GB and removes the coupling entirely.
   Cheapest structural fix; do this before launch rather than after.
2. Accept the sharing and set a conservative default round count.

Also observed: **4 of 6 projects on this account are paused**, and Free permits only
**2 active projects** — currently Mubitracker and ReIN Bot. There is no spare active slot,
so option 1 needs a *new organization*, not a new project.

Two claims here are inferred from Supabase's documented Free-plan behaviour rather than
directly verified: that egress/storage aggregate per-organization while database size is
per-project, and that a second org grants a second allowance. **Confirm both before
relying on option 1.** Recorded in B-21.

### 10.3 Remaining budget notes

Assumes a full room and no cache hits, so the table above is the pessimistic bound.
Repeated plays of the same clip may land in the separate 5 GB **cached** allowance, which
would improve this — magnitude unverified, tracked in B-13.

**Storage caps the question bank** at ~1,000 clips at 1 MB — and this allowance is
org-shared too. A ~500-title curated pool fits with room to spare.

Non-binding by a wide margin: database (rooms/rounds/guesses are tiny, and the 24 h
retention sweep in `doc/DATA-MODEL.md` §8.2 keeps it flat), Edge Function invocations (ingest
is one-off; room creation is ~1/game), Realtime messages (~1,600/game → ~1,250 games).

**Overage behaviour** is only partly known: free-plan overage is not billed but
triggers service restriction — pausing, read-only mode, or `402` on all API requests,
with a one-time non-renewing grace period. B-13 remains open on the precise egress
trigger. **Note the org-level consequence: a restriction triggered by Mubitracker's usage
would take ReIN Bot down with it.**

**Two permanent constraints:** Vercel Hobby is **non-commercial only** (B-14), and
AnimeThemes' terms forbid commercial use (`doc/RESEARCH.md` §4.9). ReIN Bot must never
monetise. This aligns with the user's stated intent ("it will be a free all project")
but is now a contractual obligation, not a preference.

---

## 11. Why there is no room server, queue, or cache

- **No room server** — state lives in a `rooms` row; progression is the idempotent
  `UPDATE` of §7. Nothing needs to hold a room in memory.
- **No queue** — the only async work is curation, which is offline and resumable.
  `pgmq` is available if that changes.
- **No cache** — clips are static files behind Storage's CDN. Game state is small and
  read straight from Postgres.
- **No accounts** — identity is a display name per room (`doc/GAME-DESIGN.md` §6.1).

---

## 12. Failure modes

| Failure | Behaviour | Mitigation |
| --- | --- | --- |
| All clients disconnect mid-game | Room would freeze | `pg_cron` sweep (§7) |
| One client's clock is wrong | No effect on scoring | Server stamps all times |
| Client misses a broadcast | Stale UI | Re-read `rooms`; all broadcasts reconstructible (§9) |
| Two players correct simultaneously | Exactly one winner | Partial unique index (§5.2) |
| Egress exhausted | Service restriction | Unresolved — B-13 |
| Project auto-paused (7 days idle) | Game unavailable | `pg_cron` keeps it active (B-16) |
| Theme has no `nc: true` variant | Excluded at curation | §8.1 |
| AnimeThemes removes a file | Bank row dead | We hold our own copy; source URL only needed at curation |

---

## 13. Open items

| Item | Blocks | Tracked |
| --- | --- | --- |
| ~~§5.2 guess path not ratified by user~~ **RATIFIED 2026-08-22** | Nothing | this doc |
| ~~MCP bound to wrong project; nothing verified against real ReIN Bot~~ **VERIFIED 2026-08-22 over the Management API** (§10.1); MCP binding itself still needs a restart | Nothing | B-19 |
| `nc`/`subbed`/`overlap` semantics and surviving catalogue size | Locking the ingest query | B-20 |
| Curation seed list | Curation pipeline | B-11 item 2 |
| Difficulty weighting | Nothing — playtest | `doc/GAME-DESIGN.md` §8 |
| Egress overage trigger | Nothing — capacity planning | B-13 |
| Vercel Hobby function overage lock | Nothing at current scale | B-15 |
