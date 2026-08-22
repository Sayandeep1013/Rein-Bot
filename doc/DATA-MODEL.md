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
  clip_key            text        not null unique,
  duration_seconds    int         not null,
  bytes               int         not null,

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

**`clip_key` must be an opaque identifier, never the AnimeThemes basename.**
`KimiSen-OP1-NCBD1080.webm` spells the answer in the network panel
(`doc/GAME-DESIGN.md` §2.1). Use the row's own uuid: `clips/{uuid}.webm`.

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

  clip_key     text     not null,
  started_at   timestamptz,
  ends_at      timestamptz,

  unique (room_id, ordinal),
  unique (room_id, question_id)
);

create index rounds_by_room on rounds (room_id);
```

**`clip_key` is denormalised from `question_bank` deliberately.** It means `rounds` can
be exposed to clients wholesale without a join to the content tables, so there is no
path from a client-readable row to an answer. `question_id` is kept for provenance and
is harmless to expose because `question_bank` carries no client grant at all (§7.1).

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

One bucket, `clips`, objects keyed `clips/{question_bank.id}.webm`.

Public read with unguessable uuid keys, rather than signed URLs. Signed URLs would add a
round trip per round and defeat CDN caching; since the original concern was that the
*filename spells the answer* — not that the bytes need protecting — a uuid key resolves
it completely. Public caching also lets repeat plays land in the separate 5 GB cached
egress allowance (`doc/ARCHITECTURE.md` §10).

---

## 9. Open items

| Item | Blocks | Tracked |
| --- | --- | --- |
| Nothing validated against a live database | All of it, weakly | B-19 |
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
