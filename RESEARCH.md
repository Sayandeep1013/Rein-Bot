# Verified Research Notes

Every number here was read from the provider's own documentation on
**2026-08-21**. Nothing in this file is from memory or inference. Anything I could
not verify is marked **UNVERIFIED** rather than guessed.

Free-tier terms change. Re-verify before relying on any number below.

> ### Document map — read this first
>
> This file grew in three passes and **later sections supersede earlier ones**. Nothing
> has been deleted, because the rejected paths are what justify the chosen one, but only
> some of it is live. Current status of every section:
>
> | § | Topic | Status |
> | --- | --- | --- |
> | 1 | trace.moe API | 🗄️ **Archived dead end** — never called at runtime |
> | 2 | AniList API | 🗄️ **Archived dead end** — reversed by §5 |
> | 3.1–3.4 | Cloudflare Workers / DO / Pages / R2 | 🗄️ **Historical** — superseded by the stack decision |
> | 3.5 | **Supabase** | ✅ **LIVE — chosen** |
> | 3.6 | Neon | ➖ Not used; documented fallback only |
> | 3.7 | **GitHub Actions** | ✅ **LIVE — chosen** (CI + transcode) |
> | 3.8 | **Vercel Hobby** | ✅ **LIVE — chosen** (frontend) |
> | 4.1–4.6, 4.8–4.9 | **AnimeThemes.moe** | ✅ **LIVE** — content source and answer key |
> | 4.7 | Bandwidth arithmetic → "audio-first" | ⚠️ **Conclusions reversed** (see the callout in §4.7) |
> | 5 | AniList terms | ✅ Live *as a prohibition* — it is why §2 is dead |
> | 6 | Ruled in / out summary | ⚠️ **5 of 8 entries reversed** — see current list |
>
> **If you want only the current design, read §3.5, §3.7, §3.8, §4 and §6.**
>
> Two specific withdrawals worth naming: §1's premise that trace.moe would be called
> live in-round is withdrawn (§6, "Ruled out"), and §2's recommendation to cache AniList
> aggressively is reversed by §5, which shows the caching itself is what the terms
> prohibit.

---

> 🗄️ **§1 and §2 are archived research — 198 lines (§1 is 171 of them) covering paths
> that were investigated and rejected.** They are load-bearing only as evidence. Neither
> service appears in the current design. **Skip to §3 for the live stack.**

---

## 1. trace.moe API

Source: `https://soruly.github.io/trace.moe-api/` (docs render from
`soruly/trace.moe-api` → `docs/docs.md`, `docs/limits.md`, `docs/terms.md`).

### 1.1 What it actually does

An anime **scene search engine**: you give it a screenshot, it tells you which
anime, episode, and timestamp the frame came from.

> "Trace back the scene where an anime screenshots is taken from."

**There is no endpoint that returns a random anime frame.** This is the single
most important constraint on this project. trace.moe is a *labeller*, not a
*content source*.

### 1.2 Endpoints

| Method | URL |
| --- | --- |
| `GET` / `POST` | `https://api.trace.moe/search` |
| `GET` | `https://api.trace.moe/me` |
| `GET` | `https://api.trace.moe/video/{id}` |
| `GET` | `https://api.trace.moe/image/{id}` |

### 1.3 Ways to submit a search

| Mode | How |
| --- | --- |
| By URL | `GET /search?url=<url-encoded image URL>` |
| By raw upload | `POST /search` with binary body. Content-Type `image/*`, `video/*`, `application/octet-stream`, or `application/x-www-form-urlencoded` |
| By multipart form | `POST /search`, `enctype="multipart/form-data"`, field name `image` |
| By vector | `POST /search` with JSON field `vector` — one base64 string or 33-number array, or a batch of up to 10. **Each vector costs 1 quota.** Batch returns a 2-D `result` array |

Max upload size: **25 MB**. Larger returns **HTTP 413**.

### 1.4 Query parameters

| Param | Effect |
| --- | --- |
| `cutBorders` | Detects and cuts black borders — for phone/tablet screencaps |
| `anilistID` | Restrict the search to one anime by AniList ID |
| `anilistInfo` | Return AniList data inline: `idMal`, `title`, `synonyms`, `isAdult` |
| `size` | Media preview only — `l` / `m` / `s` |

### 1.5 Search response

Top level: `frameCount`, `error`, `quota`, `quotaUsed`, `result[]`.

Each `result[]` entry:

| Field | Meaning |
| --- | --- |
| `anilist` | AniList ID (number), or an info object when `anilistInfo` is set |
| `filename` | Filename of the indexed file the match was found in |
| `episode` | Episode parsed from the filename — **may be null** |
| `episode_start` / `episode_end` | Episode range covered (number or null) |
| `duration` | Length of the matching video, seconds |
| `from` / `at` / `to` | Scene start / matched frame / end, seconds |
| `similarity` | `0`–`1` |
| `video` / `image` | Preview URLs |

Nested `anilist` object when `anilistInfo` is set: `id`, `idMal`,
`title { native, romaji, english }`, `synonyms`, `isAdult`.

> "Similarity lower than 90% are most likely incorrect results."

**Design consequence:** treat `similarity < 0.90` as a failed label and reject the
candidate. `episode` being nullable means the UI must tolerate a missing episode
number. `isAdult` gives us a free content filter.

### 1.6 Media preview — the critical constraint

```
https://api.trace.moe/image/{id}?size=l
https://api.trace.moe/video/{id}?size=l
https://api.trace.moe/video/{id}?mute
https://api.trace.moe/video/{id}?size=l&mute
```

- Sizes: `l` large, `m` medium (default), `s` small.
- `mute` returns a silent video; default has sound.
- **Preview links expire in 300 seconds (5 minutes).**
- `{id}` is opaque.

> "Do not attempt to parse and modify the urls except documented above."

**Design consequence — this is decisive.** A preview URL cannot be stored and
replayed later, and it cannot be reconstructed from `anilistID` + `filename` +
`from`. Any use of trace.moe media must happen **inside 5 minutes of the search
that produced it**. Conveniently, a quiz round is ~30 seconds, so live use is
comfortably inside the window; a persistent media bank is impossible.

### 1.7 Limits

Global rate limit, applies with or without an API key:

> "global request rate limit of 100 requests/min per IP address (or IPv6 /64 block)"

Search quota by sponsor tier:

| Tier | Searches / day | Concurrency | Priority |
| --- | --- | --- | --- |
| **Free / anonymous** | **100** | **1** | 0 |
| $1 | 1,000 | 1 | 2 |
| $5 | 5,000 | 1 | 2 |
| $10 | 10,000 | 1 | 5 |
| $20 | 20,000 | 2 | 5 |
| $50 | 50,000 | 3 | 5 |
| $100 | 100,000 | 4 | 6 |

- Quota is a **rolling 24-hour window**, not a calendar day.
- Failed searches (HTTP 4xx / 5xx) **do not** count against quota.
- Concurrency applies **only** to `/search`.
- Anonymous quota is tracked **by IP**. Sponsors can stack: "100 (without API Key)
  + 100 (with API Key) = 200 daily quota."

Errors: **429** rate limit exceeded · **402** daily quota reached *or* concurrency
exceeded · **413** upload too large · **503** priority queue full.

Auth header: **`x-trace-key`**. Query-string keys are no longer supported.

`GET /me` returns: `id` (IP for guests, email for users), `priority`,
`concurrency`, `quota`, `quotaUsed`.

**Design consequence:** with concurrency 1, searches must be **serialised** — a
queue, not parallel fan-out. Two rooms starting a round at the same instant would
collide, so round starts need to funnel through a single-flight gate. And because
anonymous quota is per IP, a server-side search shares one 100/day pool across all
rooms, whereas a browser-side search would give each player their own pool — but
browser-side leaks the answer to the client, so it is unusable for a quiz.

> **This survives the secrecy cut · 2026-08-22.** It is *not* one of the secrecy layers
> the user dropped. A browser-side lookup would hand the answer to **every player as
> normal operation** — not merely expose it to someone determined to cheat — which
> destroys "who was correct first", i.e. the game itself. So the per-player quota pool is
> unavailable at any secrecy posture; keep any such lookup server-side.
>
> Moot in the shipped design regardless: content is curated **offline** into
> `question_bank` ahead of play (`GAME-DESIGN.md` §5), so no reverse-image lookup happens
> during a round at all, and the 100/day anonymous pool never sits on the hot path.

**UNVERIFIED:** the exact rate-limit response header names. The docs say only
"The rate limit info is included in the HTTP response header" without naming them.
Read them off a live response during implementation. Also unverified: how one
obtains an `x-trace-key` — appears tied to sponsorship, no signup steps documented.

### 1.8 Terms of use

- **Commercial use forbidden** without explicit approval: "Using this API for
  commercial purposes (such as reselling) is forbidden, unless explicitly
  approved." Not a paid service, no SLA, no refunds.
- **Data crawling is bannable.** "DoS attacks, sending malicious media, data
  crawling, hacking" are "strictly forbidden and will be banned."
- IP addresses are logged for rate limiting.
- trace.moe deletes submitted search images after the search; it does not retain
  them.
- No attribution requirement stated. No clause about hot-linking, caching, or
  rehosting previews. No clause forbidding competing services.
- No guarantee the API stays unchanged; changes announced via Patreon/Discord.

**Design consequence:** a private, free, friends-only game is inside the terms.
Bulk-harvesting a scene bank by automated search is close enough to "data
crawling" that it should be avoided — curation must be small-batch, human-paced,
and well under quota. Attribution is not required but is good manners and worth
including anyway.

### 1.9 Self-hosting (escape hatch, not a plan)

Open source, Docker Compose, indexes `.mp4 .mkv .webm` from a video directory
organised as `{anilist_id}/file.mp4`. Pre-hashed dumps are on Hugging Face.

> "Loading all 100,000+ files to memory requires about 160GB RAM."

Loading hashes "may take 24 hours"; further Milvus optimisation takes days.

**Design consequence:** self-hosting is not viable on any free tier. Rule it out
explicitly so it is not revisited.

---

## 2. AniList GraphQL API

Source: `https://anilist.gitbook.io/anilist-apiv2-docs/docs/guide/rate-limiting.md`

- Documented limit: **90 requests/minute**.
- **Currently degraded to 30 requests/minute** — the docs describe this as a
  temporary measure. Design against **30**, not 90.
- Headers on normal responses: `X-RateLimit-Limit`, `X-RateLimit-Remaining`.
- On exceed: **HTTP 429** plus GraphQL error `"Too Many Requests."`, with
  `Retry-After` (seconds to wait) and `X-RateLimit-Reset` (Unix timestamp).
  Exceeding triggers a 1-minute timeout.
- A separate **burst limiter** also exists.
- **UNVERIFIED:** whether auth is required for public read-only queries (the rate
  limiting page does not say). In practice public queries are generally
  unauthenticated, but confirm before relying on it.
- **UNVERIFIED:** terms on hot-linking / caching AniList `coverImage` and
  `bannerImage` CDN URLs — `docs.anilist.co` returned HTTP 403 to automated
  fetches, so this was not read from a primary source.

> ⚠️ **SUPERSEDED — this conclusion was reversed by §5, and is the reason §2 is
> archived.**
>
> AniList is **not** the metadata spine and is **not called at all**, at runtime or at
> curation time. **AnimeThemes supplies every field this paragraph wanted** — `romaji`,
> `english`, `native`, `synonyms[].text`, year, season and self-hosted cover art
> (§4.4–§4.5, verified live). One dependency instead of two.
>
> The recommendation below is not merely unnecessary, it is **prohibited**: §5 shows
> AniList's terms forbid exactly the "cache aggressively / build-time bulk collection"
> pattern it proposes. The 30 req/min limit is what made caching seem necessary; the
> terms are what make it impermissible. Retained as the record of how that was found.

**Design consequence (as written at the time, now superseded and prohibited):** AniList
is the metadata spine — titles, synonyms, romaji / english / native names, cover art,
adult flag. All of that is needed for fuzzy answer matching and for building
multiple-choice distractors. At 30 req/min it must be **cached aggressively**; treat
AniList as a build-time/curation-time dependency, not a per-round runtime call.

---

> 🗄️ **End of archived material.** Everything from §3 onward is live, except where a
> callout says otherwise.

---

## 3. Free-tier hosting candidates

> **Stack decision, 2026-08-22.** The stack is **Vercel (frontend + any HTTP
> functions) + Supabase (Postgres, Realtime, Storage, Edge Functions)**, with a
> **public repo**, **no custom domain**, and no paid plan anywhere.
>
> Read this section with that in mind:
> - **§3.5 Supabase** and **§3.8 Vercel** are the chosen stack. They are verified in
>   the most detail and are the ones to trust.
> - **§3.1–§3.4 (Cloudflare Workers, Durable Objects, Pages, R2)** are **historical**.
>   The numbers were verified and are kept because they are genuinely useful for
>   comparison and because a future move is possible — but nothing in the current
>   design depends on them. Their "design consequence" notes are annotated below
>   where they now contradict the decision.
> - **§3.6 Neon** is not needed; Supabase provides the Postgres.
>
> The one thing the decision costs is media headroom: R2 offered 10 GB storage with
> unmetered egress, versus Supabase's 1 GB storage and a shared 5 GB egress pool.
> That trade and its arithmetic are in `GAME-DESIGN.md` §3.

### 3.1 Cloudflare Workers — Free plan

Source: `https://developers.cloudflare.com/workers/platform/limits/`

| Limit | Free value |
| --- | --- |
| Requests | 100,000 / day (resets midnight UTC; over-limit → Error 1027) |
| CPU time | 10 ms per invocation |
| Memory | 128 MB per isolate |
| Subrequests | 50 per request |
| Worker size | 3 MB gzipped / 64 MB uncompressed |
| Workers per account | 100 |

Note: 10 ms CPU is *compute* time, not wall time — waiting on network does not
count. Also relevant: Durable Object wall time has "no hard limit while the caller
stays connected", and alarm handlers get 15 minutes.

### 3.2 Cloudflare Durable Objects — Free plan

Source: `https://developers.cloudflare.com/durable-objects/platform/pricing/`

> "Durable Objects are available both on Workers Free and Workers Paid plans."

On free, only the **SQLite-backed** class is available (the key-value backend is
restricted to paid accounts that already hold a KV-backed namespace).

Free allowances — **per day**, reset 00:00 UTC:

| Limit | Free value |
| --- | --- |
| Requests | 100,000 / day |
| Duration | 13,000 GB-s / day |
| SQLite rows read | 5,000,000 / day |
| SQLite rows written | 100,000 / day |
| SQLite stored data | 5 GB total |

**WebSocket Hibernation is supported**, and:

> "Durable Objects that are idle and eligible for hibernation are not billed for duration."

A non-hibernatable WebSocket opened with `accept()` *is* billed for its whole
connected lifetime — so hibernation is mandatory, not optional.

**Design consequence — SUPERSEDED 2026-08-22.** This section previously read *"this
is the single best fit found"*, and on the technical merits that assessment still
holds: one Durable Object per room gives an authoritative, single-threaded game
server with built-in WebSockets and its own SQLite, on the free plan, with no idle
billing between rounds. **It is nevertheless not being used** — the stack was
mandated to Vercel + Supabase.

What the substitution actually costs is **ergonomics, not capability**. The
guarantees a DO would have given for free must now be reconstructed in Postgres:
server-side timestamping via `SECURITY DEFINER` functions (with `SET search_path = ''`
— see `GAME-DESIGN.md` §4.4.2), ~~answer secrecy via **column-level grants**~~ (dropped, see below), and round
progression via idempotent conditional `UPDATE` plus a `pg_cron` sweep — because no
Supabase Edge Function invocation can span a full-length game — 280 s at the 10-round default, 560 s at 20 (§3.5). The state machine ends
up spread across Postgres functions, RLS policies, triggers, client timers and cron,
rather than living in one class, and round boundaries become "at least 20 s" rather
than exactly 20 s. A hybrid keeping one DO purely as a room server was considered and
judged not worth reintroducing a third vendor.

> **Corrected 2026-08-22.** This paragraph previously read *"answer secrecy via RLS on
> a table with no `SELECT` grant."* That conflated two mechanisms and was wrong: **RLS
> filters rows, not columns**, so any row a player may read, they read in full. Answer
> secrecy comes from `REVOKE SELECT ON <table>` followed by a column allow-list
> `GRANT`, not from RLS. RLS remains in the design, but for row scoping (which room a
> player may see) — never for hiding the answer. See `GAME-DESIGN.md` §4.4.1 and
> **B-17** (resolved). Note that this gates **PostgREST**; whether pg_graphql honours
> the same column grants is open as **B-18**.

> **Superseded 2026-08-22 (findings retained).** Two claims in the correction above have
> since been overtaken:
>
> 1. **The column allow-list is dropped entirely.** The user cut the secrecy goal
>    (*"no need add any additional layers of secrecy"*), so answer protection is now
>    **structural rather than privilege-based**: `question_bank` and `question_titles`
>    receive **no `anon` / `authenticated` grant at all**, and `rounds` stores a
>    denormalised `clip_key` — so there is no client-reachable answer column to hide,
>    and therefore no allow-list to keep in sync. See `GAME-DESIGN.md` §4.4.2.
> 2. **B-18 is closed as moot**, on two independent grounds: `pg_graphql` was verified
>    **not installed** on `mxkqivivqultfuattuin` (2026-08-22), so no second read path
>    exists; and with column grants gone the question cannot arise. See `BLOCKERS.md`
>    → Resolved.
>
> **What remains true and load-bearing:** *RLS filters rows, not columns.* Postgres
> column privileges are additive, never subtractive, so there is no working
> `REVOKE SELECT (answer)`. Any future read path must not attempt to hide a column with
> RLS. This finding is retained precisely because dropping the allow-list removed the
> *mechanism* but not the *misconception* that motivated it.


**Re-verify (only if Cloudflare is ever revisited):** the pricing page noted SQLite
storage billing was "scheduled to start around January 7, 2026." That date is now
past, so the page read may be stale on this point. Note also a **documentation
inconsistency** found while checking: the Workers pricing page (dated 2026-07-07)
omits Durable Objects from its Free-plan list, while the DO-specific page
(2026-08-10) states explicitly that DOs are on Workers Free, SQLite-only. If ever
relied upon, smoke-test one SQLite DO on a fresh free account rather than trusting
either page.

### 3.3 Cloudflare Pages — Free plan

Source: `https://developers.cloudflare.com/pages/platform/limits/`

| Limit | Free value |
| --- | --- |
| Builds | 500 / month |
| Concurrent builds | 1 (20-minute build timeout) |
| Custom domains | 100 per project |
| Files per site | 20,000 |
| Max single asset | 25 MiB |
| Bandwidth | **Not stated on this page** |

Pages Functions are supported; their requests count against the Workers quota
above rather than having a separate allowance.

**UNVERIFIED → MOOT 2026-08-22:** Pages free bandwidth was never confirmed. The
limits page does not state it, and the Workers *"no additional charges for egress or
bandwidth"* line sits inside the **Paid**-plan paragraph, so it could not be cited for
Free either. The question is now moot — the frontend is on Vercel, whose equivalent
figure **is** confirmed (**Fast Data Transfer up to 100 GB** on Hobby, §3.8). Closed as
**B-7**.

### 3.4 Cloudflare R2 — Free tier

Source: `https://developers.cloudflare.com/r2/pricing/`

| Limit | Free value |
| --- | --- |
| Storage | 10 GB-month |
| Class A ops (writes/lists) | 1,000,000 / month |
| Class B ops (reads) | 10,000,000 / month |
| Egress to internet | **Free** |

> "no charges for egress bandwidth for any storage class"

Free tier covers **Standard** storage only, not Infrequent Access. Caveat noted:
connecting other metered services to a bucket can incur their charges.

**Design consequence — SUPERSEDED 2026-08-22.** This section previously read *"only
needed if we decide to host our own frame stills"*, which the Option B media decision
had already outgrown — we host **every clip**, not just stills.

R2 remains **the objectively better media host** and is the strongest argument against
the mandated stack: 750 MB of clips is 7.5% of 10 GB (versus 75% of Supabase's 1 GB),
and **egress is unmetered**, so there is no per-month game ceiling at all. Its
practical constraints are elsewhere and none bind: ~500 Class A ops for the one-time
upload against 1,000,000, and ~1,200 Class B ops/month against 10,000,000.

**Why it was still not chosen:** it reintroduces a third vendor, and serving publicly
without a custom domain requires fronting the bucket with a Worker on `*.workers.dev`
(100,000 req/day) — R2's built-in `r2.dev` endpoint is rate-limited and documented as
not for production. Supabase Storage clears the *actual* expected usage with ~4×
headroom (`GAME-DESIGN.md` §3), so the extra vendor buys margin we do not yet need.

**Revisit if** traffic becomes bursty or public — Supabase egress is a hard monthly
cliff (**B-13**), R2 has no cliff. This is the documented escape hatch.

### 3.5 Supabase — Free plan · **CHOSEN (backend, database, realtime, storage)**

Sources: `https://supabase.com/pricing`,
`https://supabase.com/docs/guides/realtime/quotas`,
`https://supabase.com/docs/guides/functions/limits`,
`https://supabase.com/docs/guides/platform/manage-your-usage/egress`,
`https://supabase.com/docs/guides/platform/free-project-pausing`,
`https://supabase.com/docs/guides/platform/database-size`,
`https://supabase.com/docs/guides/cron`

**Status note (2026-08-22):** this section previously ended *"the 7-day inactivity
pause is disqualifying … Rejected as the primary datastore."* That conclusion is
**withdrawn.** The stack was subsequently mandated to Vercel + Supabase, and on
re-reading the pausing docs the risk is manageable rather than fatal — see
*Inactivity pause* below and **B-16**.

#### Platform quotas

| Limit | Free value |
| --- | --- |
| Database size | 500 MB · ⚠️ carried from the pricing page, **not re-verified** |
| Active projects | 2 (paused projects do not count) |
| **Inactivity pause** | Paused after **1 week** of inactivity |
| Monthly active users | 50,000 · ⚠️ carried from the pricing page, **not re-verified** |
| File storage | **1 GB**, metered as **744 GB-Hrs** — an *average over the billing period*, not live peak |
| Egress | **5 GB uncached + 5 GB cached** — see the unified-pool warning below |

Both ⚠️ figures are non-load-bearing here: the question bank is ~500 rows of text
(order 1–2 MB), and the player base is a friend group, so neither 500 MB nor
50,000 MAU is within reach. Re-verify only if the scope changes.

**Egress is a single unified pool.** Verbatim: *"Egress is incurred by all services -
Database, Auth, Storage, Edge Functions, Realtime and Log Drains."* There is no
separate media allowance. Measured consequence: media is ~98% of our draw
(~80 MB/game at the chosen clip size versus ~2 MB of Realtime traffic), so the media
arithmetic in `GAME-DESIGN.md` §3 effectively *is* the egress budget.

**Database overage is not graceful.** Verbatim: *"your database can go into read-only
mode which can prevent you inserting and deleting data."* The equivalent behaviour
for **egress** overage was not found and is tracked as **B-13**.

**Inactivity pause — downgraded from disqualifying to manageable.** The docs indicate
a few database requests per day prevent the pause, a warning email arrives roughly a
week ahead, and a one-click restore within 90 days preserves all data. Mitigation is
a daily keepalive ping from GitHub Actions cron (free on a public repo). The docs
hedge with *"typically … is enough"*, so this is documented-compatible but not
guaranteed — tracked as **B-16**.

#### Realtime quotas

| Limit | Free value |
| --- | --- |
| Peak concurrent connections | 200 |
| Messages | 2,000,000 / month |
| **Messages per second** | **100** |
| **Max message payload** | **256 KB** |
| Channel joins per second | 100 |
| Channels per connection | 100 |
| Presence keys per channel | 10 |
| Presence messages per second | 20 |

The last six rows were **absent from this document before 2026-08-22** and are the
ones that actually bind. Sizing check for an 8-player game at the
10-round default (the selectable range is 3-20, so scale linearly): state events
are small JSON (well under 256 KB) and burst at round boundaries, not continuously —
roughly 8 recipients × a handful of events per transition, far below 100 msg/s. The
2,000,000 monthly figure is not the constraint; the per-second rate would only bite
with many simultaneous rooms.

#### Edge Function limits

| Limit | Free value |
| --- | --- |
| **Wall-clock duration** | **150 s** (400 s on paid) |
| CPU time per request | 2 s |
| Memory | 256 MB |
| Idle timeout | 150 s |
| Functions per project | 100 |
| Recursive requests | ~5,000 / min |
| Bundle size | 20 MB (CLI) / 5 MB (server-side deploy) |

Additional constraints found: **no Web Worker API**, no multithreaded native
libraries (e.g. libvips), outbound ports **25 and 587 blocked**, and serving HTML
requires a custom domain — without one, `text/html` responses are downgraded to
`text/plain`. That last item matters because the project has **no domain**: Edge
Functions can serve JSON APIs but cannot serve pages.

**Design consequence — this is the load-bearing number.** A full game is
10 × (20 s play + 8 s reveal) = **280 s**, which exceeds the **150 s** ceiling. No
single Edge Function invocation can drive a game to completion. Round progression
must therefore be *stateless and idempotent* rather than a long-running loop; the
chosen approach is an any-client conditional `UPDATE`
(`WHERE state = 'playing' AND now() >= deadline`) backed by a periodic `pg_cron`
sweep as a liveness net. **Verified 2026-08-22 (B-17 closed):** PostgreSQL's
`READ COMMITTED` re-evaluates a blocked `UPDATE`'s `WHERE` clause against the
committed updated row, so the second concurrent writer matches 0 rows and cannot
double-advance — *but only because the guard tests `deadline`, a column the same
statement mutates.* A guard on an unmutated column would re-evaluate true and both
writers would advance. Source: `postgres/postgres` `doc/src/sgml/mvcc.sgml` §13.2.1.
Full reasoning and the caveats in `GAME-DESIGN.md` §6.3.

#### Cron

Supabase Cron is `pg_cron` under the hood, enabled from Dashboard → Integrations.
Schedules range from *"every second to once a year"*. Guidance is to keep to **≤8
concurrent jobs** and **≤10 minutes per job**. No plan restriction is stated, so it
is available on Free — which is what makes the `pg_cron` liveness sweep viable.

### 3.6 Neon Postgres — Free plan

Source: `https://neon.com/docs/introduction/plans`

| Limit | Free value |
| --- | --- |
| Storage | 0.5 GB per project |
| Compute | 100 CU-hours / project / month (≈400 h at 0.25 CU) |
| Projects | 100 |
| Branches | 10 per project |
| Scale to zero | Suspends after **5 min** idle; cannot be disabled on Free |

No permanent pause or deletion tied to inactivity is documented. If compute or
transfer is exhausted, compute suspends until the next period — and "None of
these limits delete your data."

**Design consequence — NOT USED, but retained as the documented fallback.** Supabase
now provides the Postgres, so Neon is not in the design. It stays on record for one
specific reason: Neon has **no week-long inactivity pause**, only a 5-minute
scale-to-zero that adds cold-start latency without breaking anything, and *"None of
these limits delete your data."* If the Supabase pause mitigation (**B-16**) proves
unreliable in practice, Neon is the pre-vetted alternative for the database half.

Note it would **not** replace Supabase wholesale — Realtime, Storage and Auth would
still need homes, so this is a partial escape hatch, not a drop-in one.

### 3.7 GitHub Actions + Pages

Source: GitHub billing docs for Actions

| Limit | Free value |
| --- | --- |
| Actions minutes, **private** repo | 2,000 / month (GitHub Free) |
| Actions minutes, **public** repo | Free on standard runners |
| Artifact storage (GitHub Free) | 500 MB |
| Cache storage | 10 GB per repository |

Larger runners are always billed, even on public repos.

**VERIFIED 2026-08-22 (was UNVERIFIED).** GitHub **Free = 20 total concurrent jobs**,
of which at most **5** may be macOS. Two further findings from the same check:

- **Minutes are summed across jobs, not wall time.** Sharding the curation crawl
  20 ways cuts wall time from roughly 240 min to ~12 min — which is what removes the
  6-hour per-job timeout risk — but consumes the same total minutes. Only
  **public-repo** status makes standard-runner minutes free, which the repo now is.
- **Artifacts and Packages share one 500 MB pool** on Free.
- **`ffmpeg` is NOT preinstalled on `ubuntu-latest`.** The curation workflow must
  install it explicitly. Closed as **B-12**.

The GitHub Pages half of the original question is moot: the frontend is on Vercel and
the repo is public.

**Design consequence:** ample for CI. This is where cloud-based testing runs, so
nothing needs to be installed on the laptop.

### 3.8 Vercel — Hobby plan · **CHOSEN (frontend + HTTP functions)**

Sources: `https://vercel.com/docs/plans/hobby`,
`https://vercel.com/docs/functions/limitations`,
`https://vercel.com/docs/functions/websockets`,
`https://vercel.com/docs/limits/fair-use-guidelines`
(Vercel serves markdown at `<url>.md`, which is how these were read verbatim.)

#### Quotas

| Limit | Hobby value |
| --- | --- |
| Function max duration | **300 s** (this is both the default *and* the maximum) |
| Function memory | 2 GB / 1 vCPU |
| Request & response body | **4.5 MB** (exceeding → 413 `FUNCTION_PAYLOAD_TOO_LARGE`) |
| Function invocations | 1,000,000 |
| Edge requests | 1,000,000 |
| Active CPU | 4 CPU-hrs |
| Provisioned Memory | 360 GB-hrs |
| **Fast Data Transfer** | **up to 100 GB** |
| **Fast Origin Transfer** | **up to 10 GB** |
| Projects | 200 |
| Workflow events | 50,000 / month |

Edge runtime must begin responding within **25 s**, though it may stream for up to
300 s.

#### Two clauses that constrain the project permanently

**Non-commercial only.** Verbatim: *"Hobby teams are restricted to non-commercial
personal use only. All commercial usage of the platform requires either a Pro or
Enterprise plan."* And separately: *"Asking for Donations fall under commercial
usage."* The project is free-for-all so this is satisfied today, but it forecloses
donations, sponsorship and any monetisation without a paid plan. Tracked as **B-14**.

**No overage — hard lockout instead.** Exceeding a Hobby limit locks that feature
until **30 days** have passed (Web Analytics resumes after 7). There is no
pay-as-you-go softening. Tracked as **B-15**. Combined with the unknown Supabase
egress behaviour (**B-13**), *both* halves of the stack fail as a cliff rather than a
slope — which is the main reason media is deliberately kept off Vercel entirely.

#### WebSockets — supported, but not a game server

An earlier assumption in this project's planning was that Vercel functions *cannot*
hold WebSocket connections. **That was wrong.** Verbatim: *"Vercel Functions can serve
WebSocket connections, keeping a bidirectional connection open between a client and
your server-side code."* The corrected reasons it is still unsuitable as the
authoritative room server:

1. **The connection dies at the function's max duration.** Verbatim: *"WebSocket
   connections close when a Vercel Function reaches its maximum duration."* On Hobby
   that is **300 s**, against a **280 s** game — a 20-second margin, before any lobby
   time, reconnect or slow round. Effectively zero headroom.
2. **It is billed as live function time.** Verbatim: *"WebSocket connections use
   Vercel Functions and follow the same limits and pricing model as other Function
   invocations. This includes Function usage while the connection is active, plus Fast
   Data Transfer and Fast Origin Transfer for data sent over the connection."*
   Sizing: 2 GB × 300 s ≈ 0.167 GB-hr per connection, ×8 players ≈ 1.33 GB-hrs per
   game, against 360 GB-hrs ≈ **~270 games/month**. Survivable, but it consumes a
   quota that would otherwise be untouched.
3. **No shared state across instances.** Nothing guarantees eight players land on one
   function instance, so authority and fan-out need an external coordinator anyway.

**Design consequence.** Vercel WebSockets are a *transport*, not a stateful
single-threaded authority — they are not a Durable Object substitute. **Supabase
Realtime is the better transport** for this game precisely because it has no 300 s
ceiling and does not consume Vercel function time. Authority lives in Postgres
(§3.5). One residual unknown: the WebSocket docs carry a *"Permissions Required:
WebSockets"* gate whose plan eligibility is unstated — untested, and irrelevant while
Realtime is the transport.

---

## 4. AnimeThemes.moe — the content source

Source: `https://api-docs.animethemes.moe/` (docs render from
`AnimeThemes/animethemes-api-docs` → `docs/`), plus **live responses read on
2026-08-21**. Terms read from `https://animethemes.moe/about/terms-of-service`.

This section was added after §1–§3. It changes the architecture: it supplies the
thing trace.moe cannot.

### 4.1 What it is

> "AnimeThemes is a simple and consistent repository of anime opening and ending
> themes. We provide direct links to high quality WebMs of your favorite OPs and
> EDs for your listening and discussion needs."

A **labelled** repository of anime OP/ED videos and audio, with a public API
explicitly provided "for your development needs". Unlike trace.moe, it is a
*content source*, not a labeller.

### 4.2 Endpoints and auth

| Surface | URL | Verified |
| --- | --- | --- |
| GraphQL (primary) | `POST https://graphql.animethemes.moe/` | ✅ live 200 |
| GraphiQL explorer | `https://graphql.animethemes.moe/graphiql` | documented |
| JSON:API (legacy) | `GET https://api.animethemes.moe/anime` | ✅ live 200 |
| Video CDN | `https://v.animethemes.moe/{basename}.webm` | ✅ live 206 |
| Audio CDN | `https://a.animethemes.moe/{basename}.ogg` | ✅ live 206 |

**No API key. No account. No auth of any kind for reads.** Verified by
unauthenticated live calls. Bearer-token auth exists but only for "protected
actions" — i.e. writes, which we never perform.

Note the GraphQL endpoint is the **bare root** `https://graphql.animethemes.moe/`.
`/graphql` on that host returns 404, and `POST /graphql` on `api.animethemes.moe`
returns 405. This cost several probes to find; it is not stated plainly in the docs.

### 4.3 Rate limits — read from docs *and* off live responses

> "The AnimeThemes API limits requests to 90 per minute."

Live response headers confirm it: `x-ratelimit-limit: 90`,
`x-ratelimit-remaining: 89`. On exceed: HTTP **429**, plus `Retry-After: 60` and
`X-RateLimit-Reset`, body `{message: "Too Many Attempts."}`.

**There is no daily quota.** This is the decisive difference from trace.moe's
100/day.

GraphQL also enforces **max query depth 13** and **max complexity 10000** (the
docs flag the complexity value as "experimental and debatable"). Both are far
above what our query needs.

### 4.4 The single query that produces a whole game round

Verified live. `animethemeShuffle` is a purpose-built randomiser:

```
animethemeShuffle(type: [OP], format: [...], year_lte: Int, year_gte: Int,
                  spoiler: Boolean, first: Int, page: Int)
```

`RANDOM` also exists as a sort enum value on `AnimeSort`, `AnimeThemeSort`,
`VideoSort` and 19 other sort enums, so randomisation is available on ordinary
pagination queries too.

One call with `first: 20` returned 20 complete rounds, each carrying:

| Field | Use in the game |
| --- | --- |
| `animethemeentries.videos.nodes.link` | The video to play (stable URL) |
| `...videos.nodes.audio.link` | Audio-only alternative, ~15× smaller |
| `anime.title { romaji english native }` | Answer key, three scripts |
| `anime.synonyms.text` | Extra accepted answers for fuzzy matching |
| `anime.year`, `anime.season` | Difficulty tiering |
| `anime.images.nodes.link` | Cover art for reveal cards / distractors |
| `anime.resources.nodes` | `ANILIST`, `MAL`, `KITSU`, `ANIDB`, `ANN` IDs |
| `animethemeentries.spoiler` / `.nsfw` | Content filtering |
| `song.title.romaji` | Bonus "name the song" mode |

Sample verified result: *Kimi to Boku no Saigo no Senjou* — OP1, romaji + English
+ native titles, 3 synonyms including the fan abbreviation "Kimisen", 1080p WebM,
3.5 MB OGG, `ANILIST#112667`, `spoiler: false`, `nsfw: false`.

**Design consequence — decisive.** One unauthenticated HTTP request yields an
entire round *including its answer key*. Requests are Relay-style: connections
require a `nodes { }` sub-selection (`videos { nodes { link } }`), and
`song.title` / `anime.title` are objects needing sub-selection.

### 4.5 Media URLs are stable — unlike trace.moe

```
https://v.animethemes.moe/KimiSen-OP1-NCBD1080.webm
https://a.animethemes.moe/KimiSen-OP1-NCBD1080.ogg
```

Human-readable, derived from `Video.basename`, **no expiry token**. Live checks
returned HTTP **206 Partial Content** with `Accept-Ranges: bytes` on both hosts,
so seeking and progressive playback work.

This retires the constraint that shaped the entire earlier design: media no
longer has to be consumed within 300 seconds, so a question bank *can* store
references and replay them indefinitely.

### 4.6 No CORS headers — a real constraint with a narrow blast radius

Live requests with an `Origin` header returned **no `Access-Control-Allow-Origin`
header at all** on either CDN host.

| Works without CORS | Blocked without CORS |
| --- | --- |
| `<video src>` / `<audio src>` playback | `fetch()` / XHR on the media bytes |
| Range requests by the media element | `crossorigin="anonymous"` attribute |
| Progressive streaming and seeking | Canvas frame extraction (taints canvas) |
| | WebAudio `decodeAudioData` on fetched bytes |

**Design consequence — this recommendation was ADOPTED.** Plain playback from
AnimeThemes is fine and would have cost us no egress, but it is limited to plain
playback. Any mode requiring *client-side pixel or sample access* — blurred-frame
reveal, waveform visualiser, custom scrubbing — needs either curation-time
preprocessing into **our own bucket**, or a proxy. A proxy would pull 33–56 MB per round
through our own compute and is a bad trade; **prefer preprocessing.**

`GAME-DESIGN.md` §3 chose preprocessing, into **Supabase Storage** (this section
originally said R2 — see §3.4/§3.5 for why the bucket changed). Two updates to the
wording above, now that we self-host:

- **"Costs us nothing" no longer applies to us.** It describes hot-linking. Serving our
  own clips costs **80 MB of egress per game** against the 5 GB unified pool (§3.5,
  §4.7). This section's reasoning is unaffected — the CORS limitation is what forced
  preprocessing, and preprocessing is what created the egress line item.
- **CORS was the second reason to preprocess, not the first.** The first is that
  hot-linked filenames leak the answer (§4.5, B-9). Either alone would have been
  sufficient.
  > **Ranking inverted 2026-08-22 (secrecy cut).** With secrecy dropped, the answer leak
  > is **no longer sufficient on its own**, so this ordering flips: **CORS (B-9) is now
  > the first reason**, and bandwidth the second — hot-linking costs ~1.2 GB per game
  > against ~80 MB preprocessed (§4.7), roughly **15x**, measured against an *org-shared*
  > 5 GB allowance (`ARCHITECTURE.md` §10.2). The conclusion is unchanged and now
  > over-determined; only the justification order moves.

Also observed: `Cache-Control: no-cache, private` and `Set-Cookie` on the video
response — it is a Laravel app serving files, not a pure CDN. Browsers will
therefore **re-download per player, per round**.

### 4.7 Bandwidth arithmetic — why audio-first

Observed real sizes: 1080p WebM **56.1 MB**, 720p WebM **33.5–38.4 MB**,
OGG audio **2.2–3.5 MB**.

For one 8-player game at the 10-round default (the selectable range is 3-20), with no
browser caching:

| Mode | Per round (8 players) | Per game | Verdict |
| --- | --- | --- | --- |
| Audio OGG (~3 MB) | 24 MB | **240 MB** | Acceptable |
| 720p WebM (~36 MB) | 288 MB | 2.9 GB | Discourteous |
| 1080p WebM (~56 MB) | 448 MB | **4.5 GB** | Unacceptable |

**Our own egress in the hot-linking cases: zero** — media is served by AnimeThemes,
and only small JSON crosses our backend.

> ⚠️ **SUPERSEDED 2026-08-22 — both conclusions in this section were reversed.**
>
> **1. "Our own egress is zero" no longer holds.** `GAME-DESIGN.md` §3 chose to
> preprocess clips into **our own Supabase Storage bucket**, because hot-linking leaks
> the answer in the filename and offers no CORS. We now serve the media, so egress is
> ours: **80 MB per game**, against a **5 GB/month unified pool** shared with Database,
> Auth, Realtime and Edge Functions (§3.5). That is ~4× headroom at expected usage, and
> it is now the tightest quota in the design.
>
> **2. "Make audio-only the default mode" was not adopted.** Video was kept. The ~15×
> figure above compares *raw* files; it does not survive preprocessing. A re-encoded
> ~1 MB video clip is **smaller than the ~3 MB full-length OGG** this section costs at
> 240 MB/game, so preprocessed video is ~3× *lighter* than hot-linked audio, not 15×
> heavier. The real cost of choosing video is against *preprocessed audio* clips
> (~19 MB/game), i.e. ~4×, which the budget absorbs.
>
> The ToS argument in this section — that a donation-funded service may remove anything
> "burdensome to our systems" — **was accepted, and is better served by the decision
> actually taken.** Preprocessing fetches each theme **once, ever** (~500 requests
> total) instead of ~800 partial fetches *per game*. Retained here because the
> per-fetch arithmetic below is still the correct input to that comparison.

**Design consequence (as written at the time, now superseded):** make **audio-only the
default mode**. It is ~15× lighter, it is kinder to a donation-funded service whose
terms let them remove anything "burdensome to our systems", and it is a better game on
mobile data. Treat video as an opt-in mode, lowest resolution first.

### 4.8 Video variants — and the `nc` flag that protects the answer

Verified live: most themes carry **multiple video variants**, selectable by
`resolution`, `size`, `nc`, `subbed`, `source`, `overlap`, `priority` and `tags`.

Resolution/size spread across a 100-video sample:

| Resolution | Count | Min | Median | Max |
| --- | --- | --- | --- | --- |
| 468–480 | 32 | 6.6 MB | 17.3 MB | 35.1 MB |
| 544–576 | 23 | 6.9 MB | 21.3 MB | 26.9 MB |
| 720 | 10 | 3.7 MB | 39.7 MB | 42.4 MB |
| 960–1076 | 4 | 44.3 MB | — | 100.2 MB |
| 1080 | 31 | 17.0 MB | 46.7 MB | 92.8 MB |

Overall median **26.1 MB**, mean **31.9 MB**. Size correlates only loosely with
resolution — a 720p file can exceed a 1080p one.

**The critical field is `nc` ("no credits").** A variant with `nc: false` is the
broadcast version, which burns opening/ending **credits — and frequently the show's
title logo — into the picture.** For a guess-the-anime game that hands the player
the answer.

Example, *Bocchi the Rock!* OP, verified live:

| Variant | Resolution | Size | `nc` | Safe to use? |
| --- | --- | --- | --- | --- |
| WEB | 720 | 47.1 MB | `false` | ✗ shows credits |
| NCBD1080 | 1080 | 56.0 MB | `true` | ✓ |

**Design consequence — and it cuts against bandwidth.** Spoiler-safety requires
preferring `nc: true`, but the credit-free versions are typically the 1080p
Blu-ray rips, i.e. the *largest* files. The safe variant is often the heavy one, so
"just pick the smallest" is wrong. Selection precedence must be:

1. `nc: true` — mandatory; a credited video can reveal the title.
2. `subbed: false` — subtitles can carry translated titles.
3. `overlap: NONE` preferred — avoids dialogue bleeding over the theme.
4. *Then* smallest `size`.

A theme with no `nc: true` variant should be **excluded during curation** rather
than used with a warning.

**UNVERIFIED:** whether `nc: false` reliably implies on-screen text in every case,
and whether any credited variants are in fact title-free. Spot-check a sample
visually during curation rather than trusting the flag alone.

### 4.9 Terms of service

Last updated **March 18, 2021**. Relevant clauses, quoted:

- > "The Site may not be used in connection with any commercial endeavors except
  > those that are specifically endorsed or approved by us."
- > "Use the Site as part of any effort to compete with us or otherwise use the
  > Site and/or the Content for any revenue-generating endeavor or commercial
  > enterprise."
- They reserve the right, without notice, "to remove from the Site or otherwise
  disable all files and content that are excessive in size or are in any way
  burdensome to our systems".

**Notably absent:** any clause prohibiting scraping, data mining, automated
access, systematic retrieval, framing, or hot-linking. This is a material
difference from trace.moe, which explicitly bans "data crawling". AnimeThemes
publishes an API and documentation precisely to enable third-party development.

**Design consequence:** a free, private, non-commercial friends' game is squarely
inside these terms. The project must never carry ads or charge money. Attribution
is not required but should be included.

**UNVERIFIED:** whether the API/CDN publishes a separate robots or fair-use policy
beyond the site ToS. Not found; not obviously existing.

---

## 5. AniList terms of use — closes blocker B-5

Source: `https://docs.anilist.co/guide/terms-of-use`, read **2026-08-21**. The
403 that blocked this earlier did not recur; the page served normally with a
browser user-agent.

Quoted guidelines:

- > "Free for non-commercial usage."
- > "The AniList API may be used within commercial applications or services
  > operating at less than $150 of revenue per month free of charge, no express
  > permission is required."
- > "Using the AniList API as a backup or data storage service is strictly
  > prohibited."
- > "[Scraping] or mass collection of data from the AniList API is strictly
  > prohibited."
- > "Use of the AniList API within competing, non-complementary services of the
  > same nature is prohibited. This includes, but is not limited to, anime and
  > manga list or tracker services."
- Naming: if "AniList" appears in the application name, it must be clearly marked
  unofficial.

**Design consequence — this reverses §2's recommendation.** §2 concluded AniList
should be "cached aggressively" as a "build-time/curation-time dependency". That
is precisely what these terms forbid: building a local mirror of AniList media
data is both "backup or data storage" and "mass collection".

A quiz is not a competing list/tracker service, so the competing-services clause
does not bite. But the caching plan does.

Fortunately AniList is now **unnecessary**: §4.4 shows AnimeThemes already returns
romaji/English/native titles, synonyms, cover art and year — everything AniList
was wanted for. AnimeThemes also **self-hosts its cover images** on its own R2
bucket (`https://pub-…​.r2.dev/anime/large-cover/…​.png`), verified live, so the
unresolved question of hot-linking AniList's CDN is moot too.

**Recommendation:** drop AniList from the architecture. Keep the `ANILIST`
external ID from AnimeThemes purely as an outbound "read more" link, which
requires no API call at all.

**UNVERIFIED:** AniList's current rate limit in practice. §2 recorded 30 req/min
(degraded from 90). Not re-checked, and no longer load-bearing.

---

## 6. What this research already rules in and out

**Ruled out**

- **trace.moe as the runtime content source** — it is a labeller, not a content
  source, and has no random-frame endpoint.
- **trace.moe anywhere in the runtime path at all.** Beyond the above: its free
  quota is 100 searches/day, which at one search per round caps the *entire game,
  all rooms, all players combined* at 100 rounds/day. Worse, that quota is tracked
  **per IP**, and a Cloudflare Worker egresses from Cloudflare's shared IP ranges
  — so the pool would be shared with unrelated Workers platform-wide, producing
  unpredictable `402`s. §4 removes any need for it.
- Storing trace.moe preview URLs — they expire in 300 seconds.
- Reconstructing trace.moe preview URLs from stored fields — `{id}` is opaque and
  parsing is explicitly forbidden.
- Bulk-harvesting a scene bank via automated trace.moe search — reads as "data
  crawling", which is bannable.
- Self-hosting trace.moe — needs ~160 GB RAM.
- **Caching or mirroring AniList data** — explicitly prohibited by AniList's terms
  as "backup or data storage" and "mass collection". This reverses §2.
- **AniList as a dependency at all** — superseded by §4.4/§5; AnimeThemes already
  provides titles, synonyms, cover art and year.
- Supabase as primary datastore — 7-day inactivity pause.
- 1080p, and by default any, video mode as the primary experience — 4.5 GB per
  8-player game (§4.7).
- Client-side pixel/sample processing of AnimeThemes media without preprocessing
  — no CORS headers (§4.6).
- Any commercial use of the project, including ads — forbidden by both trace.moe's
  and AnimeThemes' terms, and revenue over $150/month would additionally require
  an AniList commercial licence.

**Ruled in**

> ⚠️ **This list is the state as of the Cloudflare-era research. Five of its eight
> entries were reversed by the 2026-08-22 stack decision.** The current answer is
> below; the original wording is kept beneath it for the record.

**Current — as decided:**

- **AnimeThemes.moe GraphQL as the content source and answer key**, unauthenticated,
  90 req/min, no daily cap. *(Unchanged.)* One `animethemeShuffle` call returns a batch
  of complete rounds.
- **GitHub Actions as the cloud test/CI environment and as the transcode runner** —
  with an explicit `ffmpeg` install step (§3.7, B-12). *(Unchanged, now verified.)*
- **Video, preprocessed into ~20 s / ~1 MB clips** — *reverses* "audio-only as the
  default mode" (§4.7).
- **Our own Supabase Storage bucket with opaque keys** — *reverses* "direct hot-linking
  … zero egress cost to us". Hot-linking leaks the answer in the filename and gives no
  CORS control (§4.6, `GAME-DESIGN.md` §3).
- **Postgres as the authoritative store + Supabase Realtime for fan-out** — *reverses*
  "Workers + SQLite Durable Objects with WebSocket Hibernation". Same state model, no
  DO-equivalent primitive; see §3.2 and **B-17** (resolved 2026-08-22 — verified, with
  four corrections applied along the way).
- **Vercel Hobby for the frontend** (§3.8) — *reverses* "Cloudflare Pages".
- **R2: not used**, retained as a documented escape hatch if egress becomes bursty
  (§3.4) — *reverses* "R2 only if we add a mode needing preprocessed frames", since we
  now preprocess by default but host it on Supabase instead.
- trace.moe: still **not required**. *(Unchanged.)*

<details><summary>Original list, as written during the Cloudflare research</summary>

- **AnimeThemes.moe GraphQL as the content source and answer key**, unauthenticated,
  90 req/min, no daily cap. One `animethemeShuffle` call returns a batch of
  complete rounds.
- **Audio-only (OGG, ~3 MB) as the default game mode**, video as opt-in at lowest
  resolution.
- **Direct hot-linking of `a.animethemes.moe` / `v.animethemes.moe`** via plain
  `<audio>` / `<video>` elements — stable URLs, range requests work, zero egress
  cost to us.
- Cloudflare Workers + SQLite Durable Objects with WebSocket Hibernation as the
  authoritative realtime game server, on the free plan.
- Cloudflare Pages for the static frontend.
- GitHub Actions as the cloud test and CI environment.
- R2 only if we add a mode needing preprocessed frames (§4.6).
- trace.moe retained *optionally*, at curation time only, if we ever want to label
  frames we already hold. Not required by the current design.

</details>

**Still open — needs a decision, not research**

The game itself is undesigned: what the player sees and hears, what they type,
scoring, round length, room size, difficulty tiers, persistence. §4 settles where
content comes from; it does not settle what the game is.
