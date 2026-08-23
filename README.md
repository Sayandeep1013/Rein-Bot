# ReIN Bot

Guess the anime from its opening — a multiplayer party game built to run entirely on free tiers.

[![Postgres](https://img.shields.io/badge/Postgres-16-%234169e1?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Supabase](https://img.shields.io/badge/Supabase-free%20tier-%233ecf8e?logo=supabase&logoColor=white)](https://supabase.com/)
[![GitHub Pages](https://img.shields.io/badge/GitHub%20Pages-static-%23222222?logo=github&logoColor=white)](https://pages.github.com/)
[![ffmpeg](https://img.shields.io/badge/ffmpeg-VP9%2FOpus-%23388e3c?logo=ffmpeg&logoColor=white)](https://ffmpeg.org/)
[![License](https://img.shields.io/badge/license-MIT-%23bb9af7)](LICENSE)

## Idea

A room of 2–8 friends gets a 20-second clip of an anime opening. Everyone types
freely as it plays, first correct answer takes the round, then the clip unmutes and
reveals what it was. 3–20 rounds, no accounts, join with a 4-character room code.

The interesting part isn't the game — it's the constraints. Two of them shape every
decision in here:

1. **The answer can never reach the client.** Not in a JSON payload, not in a file
   name, not in the clip's own metadata. Anything the browser can read, a player can
   read. So guesses are graded inside Postgres, the clip is named by a random UUID,
   and the tables holding answers have no `anon` grant at all.
2. **Everything must fit a free tier, including the parts nobody sees.** Serving
   video is the expensive part of a video game, so the clips are cut down, curated
   ahead of time, and the egress arithmetic is written down rather than assumed.

## Spec

Full design lives in [`doc/`](./doc):

| Document | What's in it |
| --- | --- |
| [GAME-DESIGN.md](./doc/GAME-DESIGN.md) | The round, anti-cheat reasoning, fuzzy answer matching, scoring |
| [ARCHITECTURE.md](./doc/ARCHITECTURE.md) | Stack, trust boundaries, realtime, deployment |
| [DATA-MODEL.md](./doc/DATA-MODEL.md) | Schema, RLS posture, RPC contracts |
| [RESEARCH.md](./doc/RESEARCH.md) | Free-tier quotas and the arithmetic behind them |
| [PROGRESS.md](./doc/PROGRESS.md) | Dated log of what was built and why |
| [BLOCKERS.md](./doc/BLOCKERS.md) | Open questions, and what would settle each one |

## How it works

**Answer matching** runs server-side in PL/pgSQL. Titles are normalised on both
sides — case, punctuation, long vowels, `season 2` vs `2nd season` — then matched in
tiers: exact, near (bounded Levenshtein), season-lenient, prefix. All correct tiers
score the same; the tier is only reveal flavour. The bias is deliberately toward
false negatives, because wrongly rejecting a right answer is a smaller sin in a
scoring game than accepting a wrong one.

**Clips are curated in CI, not at request time.** A GitHub Actions workflow reads a
manifest of credit-free openings, pulls each from AnimeThemes, cuts 20 seconds,
re-encodes to 480p VP9 + Opus, strips every scrap of container metadata, names the
file by a deterministic UUID, and uploads it to Supabase Storage. A single idempotent
RPC writes the question row and its accepted-answer aliases. Nothing about this
touches a developer machine — it runs on a free Ubuntu runner because the source
material is ~5.5 GB and VP9 encoding is slow.

**No accounts.** A player is a connection plus a display name. Room code in, room
code out. No auth provider, no email, no PII, no extra quota to budget.

## Stack

| Layer | Choice | Why this one |
| --- | --- | --- |
| Database | Supabase Postgres | RLS, realtime and storage in one free tier |
| Game logic | PL/pgSQL RPCs | Grading has to run where the client can't see it |
| Realtime | Supabase Realtime | Broadcast round start/reveal to a room |
| Clip storage | Supabase Storage | Public read, UUID keys, 5 MB per-object cap |
| Curation | GitHub Actions + ffmpeg | 2000 free minutes/month of someone else's CPU |
| Client | Static HTML + vanilla JS | No build step, no framework, nothing to break |
| Hosting | GitHub Pages | Static files, free, and its licence allows a non-commercial game |
| Content source | [AnimeThemes.moe](https://animethemes.moe) | Credit-free (`NC`) openings, community catalogued |

## Status

**Deployed at [sayandeep1013.github.io/Rein-Bot](https://sayandeep1013.github.io/Rein-Bot/).**
Content is loading; two dashboard steps remain before a game can be played.

Done:

- Migrations `0001`–`0013` applied to a live Supabase project and execution-tested —
  rooms, players, rounds, guesses, the question bank, RLS posture, the grading RPC,
  the idempotent ingest RPC, the `media` bucket, and `get_room_state`.
- **A supervisory audit of everything above**, which found and closed two independent
  paths by which a client could read the answer, four correctness bugs, and three
  places where the curation pipeline's spoiler filter failed *open*. Written up in
  [PROGRESS.md](./doc/PROGRESS.md); the short version is that the schema's comments had
  become its weak point, and execution testing passed because the tests confirmed what
  the comments claimed.
- A curated manifest of **46 anime / 136 openings**, every one verified credit-free,
  unsubbed, non-spoiler and SFW from the source API rather than assumed.
- The web client, in [`app/`](./app) — no framework, no build step, and no
  `supabase-js`: one polled RPC plus REST is all `fetch()`, so the page has zero
  third-party runtime dependencies.

Remaining, and both need a human with dashboard access
([B-30](./doc/BLOCKERS.md)):

1. Enable **anonymous sign-in** on the Supabase project.
2. Paste the **publishable key** into `app/config.js`.

The client detects both and renders the fix, so the deployed site explains itself
rather than failing blankly.

Out of scope: persistent profiles or lifetime stats — see `GAME-DESIGN.md` §8.

## Content and credits

Clips are derived from [AnimeThemes.moe](https://animethemes.moe), a community
project that catalogues anime themes. Only credit-free (`NC`) versions are used, each
is cut to 20 seconds, and every reveal links back to the source entry. This project
claims no ownership of the music or footage; rights remain with their owners.

If you run the pipeline yourself, be polite to AnimeThemes — it's a free service, and
the workflow paces its requests accordingly.
