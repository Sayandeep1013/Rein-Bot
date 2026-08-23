# ReIN Bot — Data Model

Status: **first draft, 2026-08-22.** **These are specifications, not migrations.** No
migration has been written or applied. The Supabase MCP is still bound to an unrelated
project (B-19), so none of this has been validated against a live database.

Companion documents: `doc/ARCHITECTURE.md` (component boundaries), `doc/GAME-DESIGN.md` (game
rules and matching semantics), `doc/RESEARCH.md` (verified platform numbers),
`doc/BLOCKERS.md` (open questions).

---

## 1. Conventions

- Primary keys are `uuid`, defaulted with `gen_random_uuid()` (`pgcrypto`).
- All timestamps are `timestamptz`, always written server-side. **A client-supplied
  timestamp is never accepted anywhere in this schema.**
- Durations are `interval`, not integers, so `now() + round_duration` is direct.
- Table names plural, column names singular, `snake_case`.
- Every table that clients touch has RLS enabled (§7).

---

## 2. Extensions

| Extension | Version available | Used for | Installed? |
| --- | --- | --- | --- |
| `pgcrypto` | — | `gen_random_uuid()` | **already installed** |
| `unaccent` | 1.1 | strip diacritics in normalisation | no |
| `fuzzystrmatch` | 1.2 | `levenshtein_less_equal()` | no |
| `pg_trgm` | 1.6 | `similarity()` fallback tier | no |
| `pg_cron` | 1.6.4 | liveness sweep + retention | no |

Versions are the platform defaults observed on Supabase; none are installed on a ReIN
Bot project yet. Availability is platform-wide so it transfers, but **confirm once
B-19 is cleared.**

### 2.1 A gap in `doc/GAME-DESIGN.md` §4.3 — flagged, not silently patched

§4.3 specifies **Damerau–Levenshtein ≤ 2** for the near-match tier.
**`fuzzystrmatch` does not provide Damerau–Levenshtein.** It provides `soundex`,
`difference`, `levenshtein`, `levenshtein_less_equal`, `metaphone`, `dmetaphone`,
`dmetaphone_alt` — plain Levenshtein only, with no transposition operation.

Three options:

1. **Use plain `levenshtein_less_equal()` with §4.3's thresholds.** A transposition
   (`Naruto` → `Nartuo`) costs **2** edits under plain Levenshtein instead of 1, so at
   a threshold of 2 it is still caught — it just consumes the whole budget. Practical
   impact is small.
2. Hand-write Damerau–Levenshtein in PL/pgSQL. Correct, slower, more code to own.
3. Loosen to `similarity()` from `pg_trgm`. Different failure modes; less predictable.

**Recommendation: option 1**, and amend §4.3 to say "Levenshtein" rather than
"Damerau–Levenshtein" so the doc matches what will actually run. `levenshtein_less_equal`
short-circuits above the threshold, so it is also the faster call.

Note `levenshtein()` errors on inputs over 255 characters. Anime titles are far shorter;
the guess input should still be length-capped at the application layer.

---

## 3. Content tables

These are written by the curation pipeline (`doc/ARCHITECTURE.md` §8) and **never read
directly by clients** (§7.1).

### 3.1 `question_bank`

```sql
create table question_bank (
  id                  uuid primary key default gen_random_uuid(),
  asset_slug          uuid        not null unique default gen_random_uuid(),  -- stills
  poster_slug         uuid        not null unique default gen_random_uuid(),
  audio_slug          uuid        not null unique default gen_random_uuid(),
  -- one uuid reused for all three is the realistic ingest bug, so it is rejected:
  constraint question_bank_slugs_distinct check (
    asset_slug <> poster_slug and asset_slug <> audio_slug and poster_slug <> audio_slug
  ),
  still_count         smallint    not null check (still_count between 2 and 3),
  audio_seconds       int         not null,
  bytes_total         int         not null,

  -- provenance
  animethemes_video_id  int,
  animethemes_theme_id  int,
  anime_slug            text      not null,

  -- difficulty inputs (§5)
  anime_year          int         not null,
  anime_season        text,
  anime_format        text        not null,
  theme_type          text        not null check (theme_type in ('OP','ED')),
  theme_sequence      int,
  difficulty          smallint    not null check (difficulty between 1 and 5),

  -- variant safety flags (doc/ARCHITECTURE.md §8.1)
  nc                  boolean     not null,
  subbed              boolean     not null,
  overlap             text,
  spoiler             boolean     not null default false,
  nsfw                boolean     not null default false,

  -- reveal payload, broadcast at ROUND_REVEAL only
  reveal              jsonb       not null,

  retired_at          timestamptz,
  created_at          timestamptz not null default now(),

  constraint credit_free_only   check (nc is true),
  constraint not_subbed         check (subbed is false),
  constraint sfw_only           check (nsfw is false)
);
```

**Amended by migration `20260823000010_still_assets.sql`.** A question no longer owns
one video; it owns five objects — one audio, two or three stills, one poster
(`doc/BLOCKERS.md` B-25). `clip_key`, `duration_seconds` and `bytes` are gone, replaced
by the four columns above.

**Object keys are derived from `asset_slug`, and `asset_slug` is deliberately NOT the
row's `id`.** The old rule — "use the row's own uuid" — became a content leak the
moment a question owned more than one object. `rounds.question_id` is readable by every
room member (§7.2), and `create_room` pre-selects every round of the game up front, so a
player can read the `question_id` of every *future* round during round 1. If keys are a
function of that id, then reading the id is equivalent to holding the keys, and because
the bucket is public-read, holding the keys is equivalent to holding the content.

`asset_slug` is an independent random uuid living only on `question_bank`, which carries
no client grant at all (§7.1). Keys are computed server-side by
`question_asset_keys(still_slug, poster_slug, audio_slug, still_count)`, the single place
the Storage layout is written down.

**Each asset class has its own independent key root** (migration 0011). Sharing one
`asset_slug` across all five objects closed the `id` leak but opened a smaller one in its
place: `stills/{slug}-1.jpg` and `posters/{slug}.jpg` differ by one path segment, and the
poster is deliberately the title card, so a player holding the still they were legitimately
sent could derive the answer to the question they were being asked. `question_bank`
therefore carries three roots — `asset_slug` for stills, `poster_slug`, `audio_slug` — each
`not null unique`, and a `question_bank_slugs_distinct` CHECK rejects the realistic bug of
one uuid reused for all three.

Four uuids per row is intentional: `id` is public; the three roots are not, and are not
derivable from `id`, from public data, or from **each other**. They are not meant to agree.
Each root is a full 122 bits of randomness, which is the only thing protecting an object:
on a `public = true` bucket, reads by key bypass RLS entirely, so no policy can restrict an
object once its key is known (§7.4).

**`still_count` is 2 or 3, never 0 or 1.** Frame selection rejects any frame containing
text and any frame too flat to be recognisable (`doc/RESEARCH.md` §4.10), so yield per
sequence varies. One usable frame is not a guessable round, so the check makes that row
unrepresentable rather than merely discouraged; `ingest_question` also raises
`INSUFFICIENT_STILLS` first so a CI log states the reason instead of quoting a
constraint name. The upper bound is 3 because the progressive reveal has three slots.

The same migration adds **`rooms.audio_enabled`** (host toggle, §4.1), fixes
**`create_room`** to persist the settings it validates (`doc/BLOCKERS.md` B-27), and adds
**`get_current_round`** as the only way asset keys reach a client (§6.6).

**The three `check` constraints are the point.** `doc/ARCHITECTURE.md` §8.1 states the
variant-selection rules as pipeline policy; encoding them as constraints means a unsafe
clip *cannot be inserted at all*, even by a buggy ingest run. A credited video reveals
the title logo, and subtitles can carry translated titles — these are correctness
requirements, not preferences, so they belong in the schema rather than in a code path
that might be skipped.

`overlap` is recorded but not constrained; `doc/RESEARCH.md` §4.8 prefers `NONE` without
requiring it.

`retired_at` allows removing a clip from rotation without deleting history that
references it.

### 3.2 `question_titles`

Every string that counts as a correct answer, one row each.

```sql
create table question_titles (
  question_id  uuid not null references question_bank(id) on delete cascade,
  kind         text not null check (kind in ('romaji','english','native','synonym')),
  title        text not null,
  title_norm   text not null,
  primary key (question_id, title_norm)
);

create index question_titles_by_question on question_titles (question_id);
```

`title_norm` is written at ingest by `normalise_title()` (§6.1), using the same function
the grader applies to the guess — **both sides must always pass through identical
normalisation** or the comparison is meaningless.

No trigram index here. Grading fetches the 4–8 candidate rows for one question and
compares in memory; a global index would serve no query we make.

**Empty-string guard.** `doc/GAME-DESIGN.md` §4.2 documents a bug where a CJK title
normalises to `''` and then matches any single character. Enforced here:

```sql
alter table question_titles add constraint title_norm_not_empty
  check (length(title_norm) > 0);
```

---

## 4. Game tables

### 4.1 `rooms`

```sql
create table rooms (
  id               uuid primary key default gen_random_uuid(),
  code             text        not null unique
                     check (code ~ '^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{4}$'),
  state            text        not null default 'lobby'
                     check (state in ('lobby','playing','reveal','over')),

  round_count      smallint    not null default 10
                     check (round_count between 3 and 20),
  round_duration   interval    not null default '20 seconds',
  reveal_duration  interval    not null default '8 seconds',
  audio_enabled    boolean     not null default true,

  difficulty_min   smallint    not null default 1 check (difficulty_min between 1 and 5),
  difficulty_max   smallint    not null default 5 check (difficulty_max between 1 and 5),

  current_round    smallint    not null default 0,
  deadline         timestamptz,

  host_player_id   uuid,
  created_at       timestamptz not null default now(),

  constraint difficulty_range_sane check (difficulty_min <= difficulty_max)
);

create index rooms_reapable on rooms (created_at) where state <> 'over';
```

**`round_count between 3 and 20`** is the user-approved range. Note that no fixed
game-length constant appears anywhere in this schema — game length is a per-room
setting, and the egress budget is consequently a formula, not a number
(`doc/ARCHITECTURE.md` §10).

**`code` is 4 characters of Crockford base32 · DECIDED 2026-08-22.** The alphabet is
`0123456789ABCDEFGHJKMNPQRSTVWXYZ` — Crockford's set, which omits `I`, `L`, `O` and `U`.
Omitting the first three kills the `0`/`O` and `1`/`I`/`L` confusions that matter for a
code read aloud to friends; `U` is omitted so a random draw cannot spell something
unfortunate. Four characters give 32⁴ = 1,048,576 codes against a realistic ceiling of
~25 concurrent rooms (200 Realtime connections ÷ 8 players, `doc/ARCHITECTURE.md` §9), so
`create_room`'s retry-on-collision loop will effectively never fire twice. Stored
uppercase; `join_room` upper-cases its input, so the code is case-insensitive to type.

The `check` constraint is deliberate rather than left to `create_room`. It means a code
of the wrong shape cannot exist even if the generator is later changed carelessly, which
matters because the generator is the one place a developer is tempted to "just use
`substr(md5(...))`" — that would reintroduce `0`/`O` ambiguity and silently widen the
alphabet past what players can reliably transcribe.

**`deadline` is the round-advance guard column and this is load-bearing.** B-17 closed
on the finding that the idempotent advance is only safe because the `WHERE` clause tests
a column the same `UPDATE` mutates. Renaming, splitting, or computing `deadline` on read
would silently reintroduce double-advance. See §6.4.

### 4.2 `players`

No accounts (`doc/GAME-DESIGN.md` §6.1). Identity is a Supabase **anonymous** auth session
plus a display name scoped to one room.

```sql
create table players (
  id            uuid primary key default gen_random_uuid(),
  room_id       uuid not null references rooms(id) on delete cascade,
  auth_uid      uuid not null default auth.uid(),
  display_name  text not null check (length(trim(display_name)) between 1 and 24),
  joined_at     timestamptz not null default now(),

  unique (room_id, display_name),
  unique (room_id, auth_uid)
);

create index players_by_room on players (room_id);
```

`unique (room_id, display_name)` prevents two identical names in one room, which would
make the scoreboard unreadable. `unique (room_id, auth_uid)` prevents one browser
joining the same room twice to farm guesses.

Anonymous sign-ins count toward MAU; the Free ceiling is 50,000, which is not a
practical constraint here.

### 4.3 `rounds`

```sql
create table rounds (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid     not null references rooms(id) on delete cascade,
  ordinal      smallint not null,
  question_id  uuid     not null references question_bank(id),

  started_at   timestamptz,
  ends_at      timestamptz,

  unique (room_id, ordinal),
  unique (room_id, question_id)
);

create index rounds_by_room on rounds (room_id);
```

**`clip_key` was removed from `rounds` by migration `20260823000010`, and the reasoning
that put it here was wrong.** The original argument appears above in spirit: `rounds`
could be exposed to clients wholesale because no join reached an answer. That is true of
the *answer* and false of the *content*. `rounds_select_for_members` gates on room
membership alone — there is no `ordinal <= current_round` predicate — and
`create_room` inserts every round up front, so the denormalised key handed each player
the asset key of every future round. Nothing leaked the title *string*; the artwork and
audio for rounds not yet played were directly fetchable, the bucket being public-read.

The stated benefit did not survive scrutiny either. Avoiding a join to `question_bank`
was never necessary: the round is served by a `SECURITY DEFINER` function, which reads
that table regardless of grants.

Assets now reach clients only through `get_current_round` (§6.6), which re-checks
membership and returns one round. `question_id` stays on the row and remains harmless:
`question_bank` and `question_titles` carry no client grant (§7.1), and keys derive from
`asset_slug`, `poster_slug` and `audio_slug`, all three of which live only on
`question_bank`.

`unique (room_id, question_id)` prevents the same clip appearing twice in one game.

**`rounds.ends_at` and `rooms.deadline` both encode "when does this round end".** The
duplication is deliberate, because the two readers cannot share one column:

| Column | Read by | Why it must live there |
| --- | --- | --- |
| `rooms.deadline` | `advance_round` (§6.4) | The advance is a single `UPDATE` on `rooms`, and B-17's idempotency depends on the guard testing a column *that same statement mutates*. It cannot move to `rounds`. |
| `rounds.ends_at` | `grade_guess` (§6.2 step 2) | Grading has already loaded the round, so the window is readable without a second lookup on `rooms`. |

**Invariant: for the currently-playing round, `rounds.ends_at = rooms.deadline`, and
`rounds.started_at` is the moment that round became current.** Both must be written in
the same transaction that advances the round, and nothing else may write either. If they
drift, grading and advancing disagree about when the round ended — guesses are accepted
against a stale window, or rejected while the round is still live.

> **Invariant satisfied as of 2026-08-22 — B-23 and B-24 resolved.** `started_at` and
> `ends_at` remain nullable in the DDL, because a round genuinely has no window until it
> becomes current; what changed is that they are now *written*. `start_game` (§6.5) stamps
> round 1 on the `lobby → playing` transition, and `advance_round` (§6.4) stamps each
> subsequent round, both behind an `if not found then return` gate and both setting
> `ends_at` from the same `deadline` value the advancing statement wrote.
>
> Kept as a warning rather than deleted: before that fix, grading in §6.2 step 2 compared
> `now()` against `NULL`, which is never true, so **every guess in the game was rejected**
> — and separately no room could leave the lobby at all. Neither failure is visible in any
> single section; both only appear when §4.3, §6.2 and §6.4 are read together. Any future
> change that makes a round current without stamping it reintroduces the first one
> silently.

There is **no reveal column here.** Reveal data is broadcast over Realtime at
ROUND_REVEAL, not stored on a client-readable row — because Realtime evaluates RLS at
join time, not per message, so a stored-and-gated payload could not be time-gated
anyway (`doc/ARCHITECTURE.md` §9).

### 4.4 `guesses`

```sql
create table guesses (
  id                uuid primary key default gen_random_uuid(),
  round_id          uuid not null references rounds(id) on delete cascade,
  player_id         uuid not null references players(id) on delete cascade,

  raw               text not null,
  normalised        text not null,
  verdict           text not null check (verdict in ('correct','incorrect')),
  match_tier        text          check (match_tier in ('exact','near','season_lenient','prefix')),

  submitted_at      timestamptz not null default now(),
  is_first_correct  boolean     not null default false,
  points            int         not null default 0
);

create index guesses_by_round on guesses (round_id);
create index guesses_by_player on guesses (player_id);
```

### 4.5 The index that makes "who was first" correct

```sql
create unique index one_winner_per_round
  on guesses (round_id)
  where is_first_correct;
```

This single partial unique index is what makes exactly-one-winner **atomic rather than
coordinated**. Two players submitting correct answers 15 ms apart cannot both be
recorded as first, because the second insert violates the index inside its own
transaction. No advisory lock, no retry loop, no application-level check.

This is also the reason grading belongs in Postgres rather than an Edge Function: the
guarantee lives here, so putting the check anywhere else would still depend on this
index while adding a network hop (`doc/ARCHITECTURE.md` §5.2).

---

## 5. Difficulty

`question_bank.difficulty` is a `smallint` 1–5 computed **at ingest**, because
**AnimeThemes exposes no difficulty field** — its `Anime` type has no score, popularity,
rank, or members (`doc/ARCHITECTURE.md` §8.3).

Inputs available: `anime_year`, `theme_type` (OP vs ED), `theme_sequence`,
`anime_format`.

**The weighting is deliberately not specified here.** It needs playtesting, and
committing a formula to the schema now would be false precision. What the schema commits
to is only that difficulty is *a stored integer we control*, filterable by
`rooms.difficulty_min/max`, and recomputable by a backfill if the formula changes:

```sql
-- recompute is a plain UPDATE; no data is lost by changing the formula
update question_bank set difficulty = compute_difficulty(...);
```

**Honest limitation, restated from `doc/ARCHITECTURE.md` §8.3:** none of these proxies
measures *recognisability*, which is what difficulty means to a player. A 2005 OP from a
famous series may be far easier than a 2023 OP from an obscure ONA. Real quality control
is a hand-picked seed list (B-11 item 2), not this column.

---

## 6. Functions

All are `SECURITY DEFINER` with `set search_path = ''`, which forces every identifier to
be schema-qualified. Unqualified names then fail at **runtime, not creation** — so each
function needs an actual execution test, not just a successful `CREATE`.

### 6.1 `normalise_title(text) → text`

Implements `doc/GAME-DESIGN.md` §4.2. `IMMUTABLE`, so it can be used in generated columns
or indexes later.

Steps, in order: lowercase → `unaccent()` → collapse whitespace → strip punctuation
**using the Unicode-aware POSIX class `[^[:alnum:]]`, not `[a-z0-9]`**.

> **Corrected 2026-08-22.** This step previously specified Perl-style `\p{L}` and `\p{N}`.
> PostgreSQL's regex engine does not implement Perl property escapes: `regexp_replace('abc!',
> '[^\p{L}]', '', 'g')` fails outright with `ERROR: 2201B: invalid regular expression:
> invalid escape \ sequence`, so the function would not have been creatable as written. The
> intent was right and is preserved — only the syntax was wrong. `[[:alnum:]]` is the correct
> equivalent and was verified Unicode-aware on this project (PG 17.6, `ctype = en_US.UTF-8`):
> 君の名は survives all 4 characters, 進撃の巨人 all 5, while `Re:ゼロ 2nd` correctly loses only
> `:` and the space, and `君の名は。` / `フルメタル・パニック!` correctly lose the ideographic full
> stop U+3002 and katakana middle dot U+30FB. A whitelist is also deliberately preferred over
> blacklisting `[[:punct:][:space:]]`, which would leave symbol-category characters such as
> `☆` (U+2606, category So — not punctuation) sitting in a normalised title.

That last point is the §4.2 Bug 2 fix and is not optional: an ASCII-only class deletes
every character of 君の名は, producing `''`, which then matches any single character. The
`title_norm_not_empty` constraint (§3.2) is the second line of defence, and the grader
guards empty input as the third.

### 6.2 `grade_guess(p_round_id uuid, p_guess text) → jsonb`

The only path by which a guess enters the database. Single transaction:

1. Resolve caller to a `players` row via `auth.uid()`; reject if not a member of the
   round's room.
2. Load the round; **reject if `now()` is outside `[started_at, ends_at]`.**
3. Reject empty or whitespace-only guesses before normalising.
4. `normalise_title(p_guess)`; reject if the result is empty.
5. Reject if this player already has a correct guess for this round.
6. Compare against `question_titles` for the round's question, in tier order —
   exact, near (`levenshtein_less_equal`, §2.1), season-lenient, prefix
   (`doc/GAME-DESIGN.md` §4.3).
7. Insert, attempting the first-correct claim:

```sql
begin
  insert into public.guesses (round_id, player_id, raw, normalised,
                              verdict, match_tier, is_first_correct, points)
  values (p_round_id, v_player, p_guess, v_norm,
          v_verdict, v_tier, v_correct, v_points)
  returning id into v_id;
exception when unique_violation then
  -- lost the race for first-correct; still record the guess
  insert into public.guesses (round_id, player_id, raw, normalised,
                              verdict, match_tier, is_first_correct, points)
  values (p_round_id, v_player, p_guess, v_norm,
          v_verdict, v_tier, false, 0)
  returning id into v_id;
  v_first := false;
end;
```

The exception branch is what makes this correct **and** complete: the loser's guess is
still recorded, it simply isn't the winner. `ON CONFLICT DO NOTHING` would have been
wrong here — it would discard the losing guess entirely.

> **DECIDED 2026-08-22 · B-22 closed — winner-takes-all.** The `points … 0` in the
> exception branch above is **correct and intended**: a guess that is correct but *second*
> scores nothing. `doc/GAME-DESIGN.md` §6.2 has been rewritten to match, so the two documents
> now describe one game rather than two.
>
> `v_points` in the first branch is therefore `100 + speed_bonus`, the bonus decaying
> linearly from 100 to 0 across `[started_at, ends_at]` — 200 for a first-second win, 100
> for a last-second one. It derives from `now() - started_at` (`doc/GAME-DESIGN.md` §6.3),
> never from a client-supplied timestamp.
>
> **All correct tiers earn full credit.** Exact, near, season-lenient and prefix score
> identically, so step 6's tier result feeds `match_tier` for the reveal but **not** the
> points expression. There is no per-tier factor to write.
>
> One consequence worth flagging for the implementer: under winner-takes-all
> `one_winner_per_round` stops being bookkeeping and **becomes the scoring rule itself**.
> The unique index is now the only thing preventing two players from both being paid for
> the same round, which raises the stakes on the exception branch — a correct guess that
> loses the race must still be recorded, and `ON CONFLICT DO NOTHING` would silently
> delete evidence the reveal depends on.

8. Return `{verdict, match_tier, is_first_correct, points}`. **The answer is not
   returned**, on either verdict — not as a secrecy measure but because a client
   receiving the answer mid-round has no use for it except to leak it into the UI.

`submitted_at` defaults to `now()`, evaluated inside this transaction. `now()` is
transaction-start time in Postgres, which is the correct semantic: every player is
stamped at the moment their transaction began, not at some later point that depends on
how long grading took.

**Points formula is owned by `doc/GAME-DESIGN.md` §6.2**, which this function applies.
**Reconciled 2026-08-22 (B-22):** winner-takes-all, so `v_points` is `100 + speed_bonus`
for the first correct guess and `0` for every other row, with no per-tier factor. The
bonus decays linearly 100 → 0 across `[started_at, ends_at]`, derived from
`now() - started_at`.

### 6.3 `create_room` / `join_room`

`create_room(p_settings jsonb)` validates `round_count` against 3–20 and the difficulty
range, generates a short code, and retries on collision against `rooms.code`'s unique
index. It selects the round's questions up front — filtered by `difficulty_min/max`,
excluding `retired_at is not null` — so a game cannot begin and then run out of content.

**Fixed by migration `20260823000010` (`doc/BLOCKERS.md` B-27).** v1 validated all three
settings and then inserted **none** of them: `insert into rooms (code) values (v_code)`
discarded `round_count`, `difficulty_min` and `difficulty_max`, leaving every room on the
column defaults. The bug was invisible because the default `round_count` is 10 and 10 was
the value everyone tested. Off the default it broke both ways: a 5-round room built 5
rounds but `advance_round` compared against 10, so the game never ended at the real last
round and served empty rounds until 11; a 15-round room ended at 11 and silently discarded
the rest. The difficulty bounds were harmless-but-wrong — used in the selection CTE, then
never re-read.

The fix carries every setting in the **same INSERT** that generates the code, so a room is
never observable half-configured. `host_player_id` remains a separate UPDATE, because that
is a genuine circular dependency: the row must exist before a player can reference it.

`p_settings` also accepts **`audio_enabled`** (default `true`), the host's toggle between
the two round formats — stills-only, or audio + stills (`doc/GAME-DESIGN.md` §3). It is a
boolean rather than a mode enum: that matches the flat-column style of the table and the
toggle the host actually sees, and a speculative third format is one more column later
rather than an enum whose values must be interpreted everywhere today.

Verified end-to-end 2026-08-23: `round_count=5, audio_enabled=false` → row persisted with
those values and exactly 5 rounds created.

`join_room(p_code text, p_display_name text)` inserts a `players` row, surfacing the
two unique violations as friendly errors ("name taken", "already in this room") rather
than raw SQL errors. Rejects rooms not in `lobby`.

### 6.4 `advance_round(p_room_id uuid)`

Advances an **already-running** game from round N to N+1. It cannot start a game — see
§6.5 for why that is a separate function and not an extra branch here.

```sql
update public.rooms
   set current_round = current_round + 1,
       deadline      = now() + round_duration
 where id = p_room_id
   and state = 'playing'
   and now() >= deadline
returning current_round, deadline, round_count
     into v_round, v_deadline, v_count;

if not found then
  return;          -- lost the race, or not yet due: the winner owns everything below
end if;

if v_round > v_count then
  update public.rooms
     set state = 'over', deadline = null
   where id = p_room_id;
  -- emit GAME_OVER, then stop: there is no round v_round to stamp
  return;
end if;

update public.rounds
   set started_at = now(),
       ends_at    = v_deadline      -- not now() + round_duration a second time
 where room_id = p_room_id
   and ordinal  = v_round;

-- emit ROUND_REVEAL for round v_round - 1, then ROUND_START for v_round
```

**`ends_at` reuses `v_deadline` rather than recomputing it.** Two separate
`now() + round_duration` evaluations would differ by however long the function took,
breaking the §4.3 invariant by a few milliseconds — enough for a guess arriving in that
sliver to be graded against a window that disagrees with the one the advance published.

Callable by any player in the room and by `pg_cron`. Eight simultaneous callers advance
the round exactly once, because under `READ COMMITTED` a blocked `UPDATE` re-evaluates
its `WHERE` against the committed row and the losers match zero rows (B-17; PostgreSQL
`doc/src/sgml/mvcc.sgml` §13.2.1).

> **Do not modify this `WHERE` clause without re-reading B-17.** The guarantee depends
> on the guard testing `deadline`, a column this same statement mutates. A guard on
> `state` alone re-evaluates *true* for every waiting writer and they all advance.

On reaching `round_count` it sets `state = 'over'`. It also emits the reveal broadcast,
reading `question_bank.reveal` — which it can do because it is `SECURITY DEFINER`,
whereas its callers cannot (§7.1).

> **B-23 RESOLVED 2026-08-22 — the stamp above closes it.** `rounds.started_at` /
> `ends_at` are now written, so §6.2 step 2 has a real window to compare against instead
> of `NULL`. Two properties of the fix are load-bearing and easy to lose in a refactor:
>
> 1. **The stamp is gated on `if not found then return`.** Eight callers race the guard
>    and exactly one affects a row. An ungated stamp would let the seven losers re-write
>    `started_at = now()` on every call, sliding the round window forward indefinitely —
>    the *same* class of bug B-17 closed, reintroduced one statement later.
> 2. **The reveal broadcast sits behind the same gate**, or eight callers emit eight
>    reveals for one transition. The `pg_cron` sweep calls this function too, so it
>    inherits both properties for free rather than needing its own copy.

### 6.5 `start_game(p_room_id uuid)`

**Added 2026-08-22 (B-24).** The `lobby → playing` transition. This did not exist, and
without it a room could never leave the lobby: `advance_round`'s guard requires
`state = 'playing' AND now() >= deadline`, but a lobby room has `state = 'lobby'` and
`deadline IS NULL`, so `now() >= NULL` evaluates to `NULL` and the `UPDATE` matches zero
rows **forever**. No amount of client polling or `pg_cron` sweeping could start a game.

```sql
update public.rooms
   set state         = 'playing',
       current_round = 1,
       deadline      = now() + round_duration
 where id = p_room_id
   and state = 'lobby'
returning deadline into v_deadline;

if not found then
  return;          -- already started, or not a lobby: idempotent, not an error
end if;

update public.rounds
   set started_at = now(),
       ends_at    = v_deadline
 where room_id = p_room_id
   and ordinal  = 1;

-- emit ROUND_START for round 1
```

**Why this guard is safe where `advance_round`'s `state` guard would not be.** B-17's
argument requires the guard to test a column the same statement mutates. Here it does —
`state = 'lobby'` is the guard and `state = 'playing'` is the write — so a second
concurrent caller re-evaluates against the committed row, sees `'playing'`, and matches
zero rows. This is exactly the property that makes `WHERE state = 'playing'` an *unsafe*
guard inside `advance_round`, where `state` is not written (`doc/GAME-DESIGN.md` §6.3).

Callable by the host only; every other player waits for the broadcast. Double-clicking
"Start" is harmless by the gate above.

### 6.6 `get_current_round(p_room_id uuid) → jsonb`

**Added by migration `20260823000010`.** The only path by which an asset key reaches a
client. `security definer`, `stable`, granted to `authenticated` only.

```
{ state, ordinal, ends_at, audio_enabled,
  assets: { stills: [key, ...], audio?: key } }
```

It re-checks `is_room_member(p_room_id)` rather than trusting the caller, reads the
room's `current_round`, and returns **that round only**. Keys come from
`question_asset_keys(still_slug, poster_slug, audio_slug, still_count)` (§3.1), so the
Storage layout is written down once.

**Two keys are withheld, for two different reasons.** Since migration 0011 those two
omissions are **effective** rather than advisory: before it, a client that received the
still keys could reconstruct the withheld poster key by editing one path segment, so
withholding it was a statement of intent rather than a control. With independent roots,
a key this function does not return cannot be derived from the ones it does.

`poster` is removed **always**, and this is a correctness requirement, not caution. The
poster is the title card — frame selection deliberately harvests it from the frames the
OCR filter *rejected* for containing text (`doc/RESEARCH.md` §4.10). The single most
spoiling frame in the sequence is exactly the frame the reveal wants, so it is the one
frame that must not ship early. Returning it during play would hand over the answer in a
form no fuzzy-match rule can intercept.

`audio` is removed when `audio_enabled` is false, and that is an **egress control, not a
security control**. The bucket is public-read, so a determined player who guessed the key
could fetch the audio regardless; the point is that in a stills-only room nobody should
be *handed* a key to ~160 KB the host explicitly opted out of. Omitting it means a
client-side bug cannot spend the bandwidth the toggle exists to save (§10 arithmetic:
~120 KB/round stills-only versus ~280 KB with audio).

**Why an RPC rather than the two alternatives.** Keeping `clip_key` on `rounds` and adding
an `ordinal <= current_round` predicate to `rounds_select_for_members` was rejected: it
makes a correctness-critical security property depend on a policy expression that must stay
right through every future change to round progression, and it still exposes the key for
the current round to a spectator who is merely a member. Putting keys in the ROUND_START
broadcast was rejected because `emit_room_event` publishes with `realtime.send(..., false)`
— a public channel keyed by a 4-character room code, a keyspace of about 1M. Neither
alternative removes the data; only dropping the column does.

Verified 2026-08-23 against the live database: in a room with `audio_enabled=false`,
`assets` contained `stills` alone — no `poster`, no `audio`.

---

## 7. RLS and grants

RLS here is **row scoping, not answer secrecy.** The user has dropped secrecy as a goal.
What remains is ordinary multi-tenancy: a player in room A must not read room B's rows.

### 7.1 Content tables — no client grant at all

```sql
revoke all on public.question_bank    from anon, authenticated;
revoke all on public.question_titles  from anon, authenticated;
```

Clients never query these. `grade_guess` and `advance_round` reach them as
`SECURITY DEFINER`.

**This is not a re-introduction of the secrecy apparatus that was cut.** That design
involved revoking a table grant and re-granting a hand-maintained column allow-list —
real engineering with a real failure mode. This is simply *not granting a privilege*,
which is the default state and costs nothing. Declining to publish the entire answer key
to every browser is not a security layer.

Consequently **B-18 is moot**: it asked whether `pg_graphql` enforces the same column
grants as PostgREST. With no column-level scheme and no table grant, there is nothing
for a second read path to bypass. `pg_graphql` is also not installed.

### 7.2 Game tables

| Table | Client `SELECT` | Client writes |
| --- | --- | --- |
| `rooms` | rows the caller has a `players` row for | none |
| `players` | rows sharing a room with the caller | none |
| `rounds` | rows in the caller's room | none |
| `guesses` | rows for rounds in the caller's room | none |

**Every write goes through a function.** No table has a direct `INSERT`, `UPDATE`, or
`DELETE` grant, which means the schema cannot be driven into an invalid state by a
crafted PostgREST call — validation cannot be bypassed because there is no bypass path.

Membership predicate, used by all four policies:

```sql
exists (
  select 1 from public.players p
   where p.room_id = <row's room_id>
     and p.auth_uid = auth.uid()
)
```

`guesses` are readable by the whole room by design — the scoreboard and the "what
everyone guessed" reveal both need them. Nothing in a `guesses` row discloses an
unrevealed answer *except* a correct guess's `raw` text, so the client must not render
other players' guess text until ROUND_REVEAL. That is a UI obligation, noted here
because the schema alone does not enforce it.

### 7.3 Expected lint

Supabase lint `0028_anon_security_definer_function_executable` will fire on
`grade_guess`, `advance_round`, `create_room`, and `join_room`. **This is by design** —
these functions must be callable by anonymous players. Recorded so a future reader does
not "fix" it.

---

## 8. Realtime, retention, storage

### 8.1 Realtime publication

Only `rooms`, `players`, and `guesses` are published. **`rounds` is not** — round
transitions are announced by `advance_round`'s explicit broadcast, which carries the
reveal payload the table does not store.

Every broadcast must be reconstructible from database state, because Realtime does not
persist messages and a client that misses one has no replay
(`doc/ARCHITECTURE.md` §9).

### 8.2 Retention

Rooms are ephemeral. A `pg_cron` job deletes rooms older than 24 hours; `on delete
cascade` clears `players`, `rounds`, and `guesses` with them.

Two useful side effects: the database stays far inside the 500 MB Free limit, and the
periodic write activity helps mitigate the 7-day inactivity auto-pause (B-16).

### 8.3 Storage

One bucket, `media`, five objects per question. Each asset class is keyed from its **own**
root on `question_bank`, never from `id` and never from another class's root (§3.1):

| Object | Key | Measured |
| --- | --- | --- |
| audio | `audio/{audio_slug}.webm` | ~198 KB Opus |
| still *n* | `stills/{asset_slug}-{n}.jpg`, *n* = 1..`still_count` | 27-31 KB each |
| poster | `posters/{poster_slug}.jpg` | ~30 KB |

Sizes are measured from pipeline run `32617226964` (12 themes, all five objects built), not
estimated: `bytes_total` came to a mean of 356,637 B per question, so all 134 questions land
at **~45.6 MB**. This is up from the ~42 MB measured in the earlier run `32605150598`; the
increase is not drift but a consequence of raising `ocr_min_conf` to 70, which changed which
frames survive the text filter and therefore which frames ship (see `doc/BLOCKERS.md` B-28).
Both figures are averages over 12 themes extrapolated to 134, so treat 45.6 MB as an
estimate with a measured basis, not a measurement of the full set.

The three roots are independent because they are on **different sides of a trust boundary
within the same question**. A player is legitimately sent the stills for the round they are
playing; the poster for that same round is the title card, i.e. the answer. When one
`asset_slug` rooted all five objects, `posters/{slug}.jpg` was a one-segment edit away from
the `stills/{slug}-1.jpg` the player already held. Separate roots make the poster
unreachable from the still, and the audio unreachable from either.

The bucket was renamed from `clips` while it was empty, the only moment that is free.
Its limits **tightened** rather than widened: `allowed_mime_types` is
`{audio/webm, image/jpeg}` with `video/webm` *removed*, so the one upload the design
forbids is now impossible; `file_size_limit` dropped 5 MB → 512 KB, since the largest
object is ~160 KB and the old ceiling existed to catch a transcode that passed the
~40 MB source through.

The empty `clips` bucket still exists. Supabase's `storage.protect_delete()` trigger
rejects any direct `DELETE` on `storage.buckets` (`42501`), so removing it is a Storage
API call rather than schema. Its read policy is dropped, so it is inert.

Public read with unguessable uuid keys, rather than signed URLs. Signed URLs would add a
round trip per round and defeat CDN caching; since the original concern was that the
*filename spells the answer* — not that the bytes need protecting — a uuid key resolves
it completely. Public caching also lets repeat plays land in the separate 5 GB cached
egress allowance (`doc/ARCHITECTURE.md` §10).

---

**IMPLEMENTED 2026-08-22 - migration 0009.** *Historical; superseded by migration 0011 above —
see the `media` block at the top of 8.3 for live settings.* The bucket was created by
`supabase/migrations/20260822000009_storage_clips.sql`. Until then 8.3 specified a bucket
that did not exist, so the pipeline had nowhere to upload; the gap was found while
writing the ingest path. Settings **as of 0009**: `public = true`, `file_size_limit = 5242880`
(5 MB - a clip was ~1 MB at 480p/20 s, so this caught a transcode that silently passed a
62 MB source through), `allowed_mime_types = {video/webm}`. Both were tightened once the
design dropped video: the live limit is **512 KB** and the live MIME allow-list is
**`{audio/webm, image/jpeg}`**, with `video/webm` removed. What has *not* changed, and is the
part worth carrying forward: no INSERT/UPDATE/DELETE policy exists on `storage.objects` for
this bucket, so anon and authenticated cannot write to it — a public bucket is public to
*read* only. The pipeline uploads with the service_role key, which bypasses RLS.

### 8.4 Ingest path

**DECIDED 2026-08-22 - migration 0008.** The curation pipeline writes through one RPC,
`ingest_question(jsonb)`, never through a direct PostgREST insert. Two reasons:

1. `question_titles.title_norm` must be produced by `normalise_title` - the same
   function `grade_guess` applies to the player's guess (3). A pipeline that normalised
   titles itself would let the two implementations drift, and answers would silently
   stop matching with nothing wrong on either side.
2. No object key is ever supplied by the caller. The pipeline passes the three slugs and
   `still_count`; every key is computed by `question_asset_keys` (§3.1). The AnimeThemes
   basename therefore cannot be supplied at all, rather than being rejected by a guard.

**Amended by migration `20260823000010`, then `20260823000011`.** v1 took a single
`clip_uuid` and derived both `id` and `clip_key` from it. v2 took `asset_slug` (plus
`still_count`, `audio_seconds`, `bytes_total`) and let `id` default independently. v3
requires all three roots — `asset_slug`, `poster_slug`, `audio_slug` — and adds
`MISSING_POSTER_SLUG`, `MISSING_AUDIO_SLUG`, and `SLUGS_NOT_DISTINCT` to its named
failures.

The two-argument `question_asset_keys(asset_slug, still_count)` was **dropped**, not left
in place beside the four-argument version. Keeping it as an overload would have left the
derivable-poster hole exactly one call site away, and the whole point of routing keys
through one function is that there is no second way to compute them.

That reverses the shape of the original rule, so it is worth being precise about what the
rule was protecting. The 0008 warning was against **a derived key string disagreeing with
the row that owns it** — one uuid in the path, another in the column, and a live round
resolving to a missing object. It was never an argument that a row may hold only one
uuid. Here the extra uuids exist precisely because the values need different
visibility: `id` is client-readable, the three roots must not be (§3.1). Nothing has to
agree, because no key is stored — keys are a pure function of the roots, computed in
one place.

Because the pipeline chooses the slugs, it uploads all five objects **before**
inserting the row. The reverse order can leave a row pointing at bytes that never
arrived, and with five objects the window is five times wider.

The function stays idempotent on `asset_slug` alone, so a batch that fails partway can be
retried without duplicating rows or orphaning uploads. Its named failures are
`MISSING_ASSET_SLUG`
(caller bug), `INSUFFICIENT_STILLS` (fewer than 2 usable frames survived selection —
the theme is skipped, not degraded) and `NO_TITLES (slug %)`, which refuses to insert an
unwinnable question and now identifies *which* one in a 136-item CI log. It is granted to
`service_role` only, with `anon` and `authenticated` explicitly revoked (§7.1).

---
## 9. Open items

| Item | Blocks | Tracked |
| --- | --- | --- |
| OCR reliability on stylised anime logos is unverified; no local `tesseract`, so it is provable only in CI | Content correctness of every question | **B-28** |
| ~~Nothing validated against a live database~~ **CLOSED 2026-08-23** — migrations 0001—0010 applied to `mxkqivivqultfuattuin` and schema-verified; `create_room`/`get_current_round` proven behaviourally (§6.6) | Nothing | ~~B-19~~ |
| ~~`rounds.clip_key` hands every room member the asset keys of all future rounds~~ **RESOLVED 2026-08-23** — column dropped, delivery moved to `get_current_round` (§4.3, §6.6) | Nothing | **B-27a** |
| ~~`create_room` validates `round_count` / `difficulty_min` / `difficulty_max` then inserts none of them~~ **RESOLVED 2026-08-23** — single INSERT carries all settings; verified `round_count=5` → 5 rounds | Nothing | **B-27** |
| ~~§4.3 says Damerau–Levenshtein; `fuzzystrmatch` has only Levenshtein~~ **AMENDED 2026-08-22** — §4.3 now specifies `levenshtein_less_equal`, proof in §4.3.1 | Nothing | §2.1 |
| ~~**CONTRADICTION:** §6.2 scores *every* correct guess 100–200; `grade_guess` step 7 scores a correct-but-second guess **0**~~ **RESOLVED 2026-08-22** — winner-takes-all chosen, so the `0` is correct and `doc/GAME-DESIGN.md` §6.2 was rewritten to match | Nothing | **B-22** |
| ~~**BROKEN:** `rounds.started_at` / `ends_at` are never written by any function; grading compares against `NULL` and rejects every guess~~ **RESOLVED 2026-08-22** — stamped by `start_game` (§6.5) for round 1 and `advance_round` (§6.4) thereafter, both behind the race gate | Nothing | **B-23** |
| ~~**BROKEN:** nothing transitions `lobby → playing`, so no room can ever start a game~~ **RESOLVED 2026-08-22** — `start_game` added (§6.5); found while fixing B-23 | Nothing | **B-24** |
| ~~`rooms.deadline` and `rounds.ends_at` duplicate one fact; invariant stated but not yet enforced~~ **RESOLVED 2026-08-22** — both writers set `ends_at` from the same `deadline` value their own statement wrote, so the two cannot drift | Nothing | **B-23**, §4.3 |
| Difficulty weighting | Nothing — playtest | §5 |
| ~~Season-lenient: full or partial credit~~ **RESOLVED 2026-08-22** — full credit for every correct tier; the points expression carries no per-tier factor | Nothing | **B-22** |
| ~~Room code length/alphabet~~ **DECIDED 2026-08-22 — 4-char Crockford base32 (§4.1)** | Nothing | closed |
| Whether `nc: false` always implies on-screen text | Ingest filter strictness | B-20 |
| Persistence beyond 24 h (leaderboard / history) | Retention policy | B-11 item 7 |
