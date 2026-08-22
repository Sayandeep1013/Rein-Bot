-- 20260822000004_game_tables.sql
-- ReIN Bot -- game state tables. Implements DATA-MODEL.md 4.1 through 4.5.
--
-- Ordering note: rooms must precede players (players references rooms), and
-- host_player_id deliberately has NO foreign key to players -- the reference is
-- circular (players.room_id -> rooms.id). The spec resolves this by omitting the FK
-- rather than making it deferrable; create_room sets host and first player in one
-- transaction, so the column is written only by code that already holds both rows.

-- ---------------------------------------------------------------------------
-- rooms
-- ---------------------------------------------------------------------------

create table public.rooms (
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

  host_player_id   uuid,       -- no FK on purpose; see file header
  created_at       timestamptz not null default now(),

  constraint difficulty_range_sane check (difficulty_min <= difficulty_max)
);

-- Partial index serving the pg_cron retention sweep (DATA-MODEL.md 8.2): it scans
-- for reapable rooms, so 'over' rows are excluded from the index entirely.
create index rooms_reapable on public.rooms (created_at) where state <> 'over';

comment on table public.rooms is
  'code is 4 chars of Crockford base32 (alphabet omits I L O U): DECIDED 2026-08-22. '
  'The check constraint is deliberate rather than left to create_room -- a wrongly '
  'shaped code cannot exist even if the generator is later changed carelessly. '
  'round_count between 3 and 20 is the user-approved range. deadline is the '
  'round-advance guard column and is load-bearing: B-17 idempotency depends on '
  'advance_round''s WHERE testing a column that same statement mutates. Renaming, '
  'splitting, or computing deadline on read silently reintroduces double-advance.';

-- ---------------------------------------------------------------------------
-- players -- anonymous auth session + display name scoped to one room.
-- ---------------------------------------------------------------------------

create table public.players (
  id            uuid primary key default gen_random_uuid(),
  room_id       uuid not null references public.rooms(id) on delete cascade,
  auth_uid      uuid not null default auth.uid(),
  display_name  text not null check (length(trim(display_name)) between 1 and 24),
  joined_at     timestamptz not null default now(),

  unique (room_id, display_name),
  unique (room_id, auth_uid)
);

create index players_by_room on public.players (room_id);

comment on table public.players is
  'unique (room_id, display_name) prevents two identical names in one room, which '
  'would make the scoreboard unreadable; unique (room_id, auth_uid) prevents one '
  'browser joining twice to farm guesses. Anonymous sign-ins count toward MAU; the '
  'Free ceiling of 50,000 is not a practical constraint.';

-- ---------------------------------------------------------------------------
-- rounds
-- ---------------------------------------------------------------------------

create table public.rounds (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid     not null references public.rooms(id) on delete cascade,
  ordinal      smallint not null,
  question_id  uuid     not null references public.question_bank(id),

  clip_key     text     not null,
  started_at   timestamptz,
  ends_at      timestamptz,

  unique (room_id, ordinal),
  unique (room_id, question_id)
);

create index rounds_by_room on public.rounds (room_id);

comment on table public.rounds is
  'clip_key is denormalised from question_bank so rounds can be exposed to clients '
  'wholesale without joining content tables -- no path from a client-readable row to '
  'an answer. unique (room_id, question_id) prevents the same clip twice in one game. '
  'started_at/ends_at are nullable because a round genuinely has no window until it '
  'becomes current; start_game stamps round 1 and advance_round each later round '
  '(B-23/B-24). Invariant: for the current round, ends_at = rooms.deadline and both '
  'are written by the same statement that advanced the room. ends_at reuses that '
  'deadline value rather than recomputing now()+round_duration, or grading and '
  'advancing disagree by however long the function took. There is NO reveal column: '
  'reveal data is broadcast at ROUND_REVEAL, never stored on a client-readable row, '
  'because Realtime evaluates RLS at join time, not per message.';

-- ---------------------------------------------------------------------------
-- guesses
-- ---------------------------------------------------------------------------

create table public.guesses (
  id                uuid primary key default gen_random_uuid(),
  round_id          uuid not null references public.rounds(id) on delete cascade,
  player_id         uuid not null references public.players(id) on delete cascade,

  raw               text not null,
  normalised        text not null,
  verdict           text not null check (verdict in ('correct','incorrect')),
  match_tier        text          check (match_tier in ('exact','near','season_lenient','prefix')),

  submitted_at      timestamptz not null default now(),
  is_first_correct  boolean     not null default false,
  points            int         not null default 0
);

create index guesses_by_round on public.guesses (round_id);
create index guesses_by_player on public.guesses (player_id);

comment on table public.guesses is
  'Every guess is recorded, correct or not -- ON CONFLICT DO NOTHING would discard a '
  'losing guess and the reveal depends on that evidence. Under winner-takes-all '
  '(B-22), one_winner_per_round IS the scoring rule, not bookkeeping.';

-- ---------------------------------------------------------------------------
-- one_winner_per_round -- the partial unique index behind first-correct.
-- ---------------------------------------------------------------------------

create unique index one_winner_per_round
  on public.guesses (round_id)
  where is_first_correct;

comment on index public.one_winner_per_round is
  'At most one is_first_correct guess per round. grade_guess claims it with a plain '
  'INSERT and catches unique_violation to record the loser as still-correct but '
  'second (0 points). This index is the only thing preventing two players from both '
  'being paid for the same round.';
