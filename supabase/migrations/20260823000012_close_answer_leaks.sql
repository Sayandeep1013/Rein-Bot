-- 0012 -- close the two answer-key leaks, fix four correctness bugs, add the caps
-- the design promised and never enforced.
--
-- WHY THIS MIGRATION EXISTS
-- A supervisory audit of 0001-0011 found that the schema's *comments* had become the
-- weak point: each migration reasoned carefully about the threat in front of it and
-- then declared the neighbourhood safe, and the next reader trusted the declaration.
-- Four of the six defects below sit exactly in that gap. Every claim here names the
-- query that proves it, so the next reader does not have to take this file's word.
--
-- 1. rounds.question_id was readable for EVERY round of the game, including unplayed
--    ones. 0010 removed clip_key and recorded "question_id stays on the row and remains
--    harmless" (0010 L156). It is not harmless: question_id is a globally stable
--    identifier for a fixed answer, so a player who plays a few games and records
--    (question_id -> ROUND_REVEAL titles) builds a permanent answer key for a
--    ~134-row bank, then reads every answer out of the lobby before round 1.
--      proof: select ordinal, question_id from rounds where room_id = <mine>;
--    Fixed by column-level GRANT: RLS is row-level and cannot withhold a column.
--
-- 2. guesses.raw was readable by every room member the instant it was inserted, and
--    guesses is in the realtime publication, so the winning guess text was PUSHED to
--    everyone with the round still running. 0006 called this "UI obligation, not
--    schema-enforceable". It is schema-enforceable, in one predicate.
--      proof: select raw from guesses where round_id = <current> and verdict='correct';
--
-- 3. grade_guess told the LOSER of the first-correct race that they won. The exception
--    branch stored (false, 0) correctly and then returned the unreset v_correct /
--    v_points, so two players 15 ms apart both saw "+187" while the scoreboard paid one.
--    doc/DATA-MODEL.md 6.2's own pseudocode has the fix (v_first := false) and 0005
--    dropped the line; the doc misses the points half.
--
-- 4. The final round's answer was never revealed. advance_round returned after
--    GAME_OVER, before the ROUND_REVEAL block, so the round players had just spent
--    20 s on never showed its answer.
--
-- 5. The 8 s reveal phase did not exist. rooms.reveal_duration was never read and
--    state='reveal' was never set; ROUND_REVEAL and ROUND_START fired in one
--    transaction with round N+1's clock already running, so the reveal ate the next
--    round's guess time. Implemented here WITHOUT new state: the next round's
--    started_at is pushed reveal_duration into the future, and grade_guess already
--    rejects anything outside [started_at, ends_at]. The gap IS the reveal.
--
-- 6. Near-match made a third of the content bank winnable by typing one character.
--    The tier used edit distance 1 whenever both sides were <= 8 chars, with no floor
--    on the short side, and question_titles only required length >= 1. Against the
--    real manifest: 'HQ!' (Haikyuu) normalises to 'hq', so guessing 'h' scored;
--    'SAO', 'FMA', 'DBZ', 'OPM', 'CSM', 'HxH' are all 3 chars. 15 of 46 anime had an
--    accepted answer of <= 4 characters. Fixed with a length floor on the fuzzy tiers
--    rather than a constraint on title_norm, so a Japanese player can still answer a
--    legitimately 2-character native title exactly.
--
-- Also here, all small and all previously unenforced: a room player cap (the design
-- says 2-8 and nothing checked), anime-level deduplication of a game's questions
-- (46 anime across 134 questions meant ~half of 10-round games repeated a show),
-- dense round ordinals (they relied on LIMIT-without-ORDER-BY returning rows in
-- window order, which Postgres does not guarantee), realtime topics keyed by room id
-- instead of the 4-character code (a ~1M keyspace on a public channel), and removal
-- of grants that were never needed.
--
-- IDEMPOTENT. Safe to apply twice: every statement is create-or-replace, drop-if-
-- exists, or a grant. Verified by applying it twice.
--
-- No explicit BEGIN/COMMIT: the Management API endpoint this is applied through runs
-- a multi-statement body as ONE transaction already, so one bad statement rolls the
-- whole file back. An explicit BEGIN here would open a nested transaction.

-- ---------------------------------------------------------------------------
-- 1. rounds -- withhold question_id from clients (leak #1)
-- ---------------------------------------------------------------------------
-- RLS is row-level. Hiding one column is a GRANT, so the SELECT privilege is
-- re-issued column by column with question_id deliberately absent. The policy is
-- unchanged: which ROWS a member may read is still "rounds in my room".
--
-- Clients need none of this for play -- get_current_round is the whole contract --
-- but the remaining columns are harmless and useful for a progress indicator.

revoke select on public.rounds from anon, authenticated;

grant select (id, room_id, ordinal, started_at, ends_at)
  on public.rounds to authenticated;

-- Supabase's default "grant all on all tables" also left anon and authenticated
-- holding REFERENCES on every column. REFERENCES is not a read path -- it permits
-- creating a foreign key against the column, and neither role can CREATE TABLE in
-- public -- but leaving it makes "can a client touch question_id?" ambiguous, and an
-- audit query that forgets to filter privilege_type reports a false positive. It did:
-- the first verification run of this migration reported "LEAK STILL OPEN" against a
-- REFERENCES grant. Removed so the answer is unambiguous.
revoke references on public.rounds from anon, authenticated;
revoke references on public.question_bank, public.question_titles from anon, authenticated;

comment on column public.rounds.question_id is
  'NOT granted to any client role (migration 0012). question_id is a stable identifier '
  'for a fixed answer, and create_room pre-inserts every round, so a readable '
  'question_id let a member enumerate the whole game up front and -- across a few '
  'games -- build a permanent answer key for the bank. Reachable only through '
  'get_current_round, which returns one round and no identifier.';

-- ---------------------------------------------------------------------------
-- 2. guesses -- do not stream the answer to the room (leak #2)
-- ---------------------------------------------------------------------------
-- A member sees their own guesses always, and everyone else's only once that round's
-- guess window has closed. The scoreboard is unaffected: under winner-takes-all,
-- points are only meaningful after the round ends, which is exactly when the rows
-- become visible.
--
-- is_own_player is SECURITY DEFINER for the same reason is_room_member is: a policy
-- expression that reads an RLS-protected table is a recursion hazard, and this one
-- must be evaluated for every guesses row.

create or replace function public.is_own_player(p_player_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.players p
     where p.id = p_player_id
       and p.auth_uid = auth.uid()
  );
$$;

comment on function public.is_own_player(uuid) is
  'True when the players row belongs to the calling auth.uid(). SECURITY DEFINER so '
  'the guesses SELECT policy can test ownership without re-entering RLS on players.';

revoke all on function public.is_own_player(uuid) from public;
grant execute on function public.is_own_player(uuid) to authenticated;

drop policy if exists guesses_select_for_members on public.guesses;

create policy guesses_select_for_members on public.guesses
  for select to authenticated
  using (
    exists (
      select 1
        from public.rounds rd
       where rd.id = guesses.round_id
         and public.is_room_member(rd.room_id)
         and (
               public.is_own_player(guesses.player_id)
               or (rd.ends_at is not null and now() >= rd.ends_at)
             )
    )
  );

comment on policy guesses_select_for_members on public.guesses is
  'Own guesses always; other players'' guesses only after that round''s ends_at. '
  'Migration 0012: guesses is in the realtime publication, so the previous '
  'whole-room policy pushed the winning guess text to every client with the round '
  'still running -- the answer, in plain text, mid-round.';

-- ---------------------------------------------------------------------------
-- 3. grade_guess v3 -- honest return values, and a length floor on fuzzy matching
-- ---------------------------------------------------------------------------

create or replace function public.grade_guess(
  p_round_id uuid,
  p_guess    text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player     uuid;
  v_room_id    uuid;
  v_question   uuid;
  v_started    timestamptz;
  v_ends       timestamptz;
  v_norm       text;
  v_stripped   text;
  v_already    boolean;
  v_title      text;
  v_pr         int;
  v_verdict    text := 'incorrect';
  v_tier       text;
  v_correct    boolean := false;
  v_first      boolean := false;
  v_points     int    := 0;
  v_elapsed    numeric;
  v_total      numeric;
  v_bonus      numeric;
begin
  if p_guess is null or length(p_guess) > 255 then
    raise exception 'GUESS_TOO_LONG';
  end if;

  if btrim(p_guess) = '' then
    raise exception 'EMPTY_GUESS';
  end if;

  select pl.id into v_player
    from public.players pl
    join public.rounds rd on rd.room_id = pl.room_id
   where rd.id = p_round_id
     and pl.auth_uid = auth.uid()
   limit 1;

  if v_player is null then
    raise exception 'NOT_A_MEMBER' using errcode = '42501';
  end if;

  select rd.room_id, rd.question_id, rd.started_at, rd.ends_at
    into v_room_id, v_question, v_started, v_ends
    from public.rounds rd
   where rd.id = p_round_id;

  -- Outside [started_at, ends_at] is not gradeable. Since 0012 the window before
  -- started_at is the reveal phase of the PREVIOUS round, so this is also what stops
  -- a player guessing ahead during a reveal.
  if v_started is null or v_ends is null
     or now() < v_started or now() > v_ends then
    raise exception 'ROUND_NOT_ACTIVE';
  end if;

  v_norm := public.normalise_title(p_guess);
  if v_norm is null or v_norm = '' then
    raise exception 'EMPTY_NORMALISED';
  end if;
  v_stripped := public.strip_season_markers(v_norm);

  select exists (
           select 1
             from public.guesses g
            where g.round_id  = p_round_id
              and g.player_id = v_player
              and g.verdict   = 'correct'
         )
    into v_already;

  if v_already then
    raise exception 'ALREADY_CORRECT';
  end if;

  -- Tier order. CHANGED IN 0012: the near and season-lenient tiers now require the
  -- compared strings to be at least 5 characters. Below that, edit distance 1 covers
  -- most of the keyspace -- 'hq' (the accepted answer for Haikyuu) was matched by 'h'.
  -- Exact match is unaffected at any length, so a 2-character native CJK title is
  -- still answerable by typing it.
  select c.title_norm, c.pr
    into v_title, v_pr
    from (
      select qt.title_norm,
             case
               when qt.title_norm = v_norm
                 then 1  -- exact
               when greatest(length(qt.title_norm), length(v_norm)) >= 5
                    and extensions.levenshtein_less_equal(
                          qt.title_norm, v_norm,
                          case when greatest(length(qt.title_norm), length(v_norm)) > 8
                               then 2 else 1 end)
                        <= case when greatest(length(qt.title_norm), length(v_norm)) > 8
                                then 2 else 1 end
                 then 2  -- near
               when qt.title_norm <> v_norm
                    and length(v_stripped) >= 5
                    and public.strip_season_markers(qt.title_norm) = v_stripped
                 then 3  -- season_lenient
               when length(v_norm) >= 8
                    and left(qt.title_norm, length(v_norm)) = v_norm
                 then 4  -- prefix
               else 99
             end as pr
        from public.question_titles qt
       where qt.question_id = v_question
    ) c
   where c.pr < 99
   order by c.pr
   limit 1;

  if found then
    v_correct := true;
    v_first   := true;
    v_verdict := 'correct';
    v_tier    := case v_pr
                   when 1 then 'exact'
                   when 2 then 'near'
                   when 3 then 'season_lenient'
                   when 4 then 'prefix'
                 end;

    -- Speed bonus decays linearly 100 -> 0 across the window.
    -- CHANGED IN 0012: the clamp ceiling was least(100, ...) on a value that is a
    -- FRACTION, so it clamped nothing. Harmless while v_elapsed >= 0, but a zero
    -- round_duration would have paid 10,100 points. It is least(1, ...).
    v_elapsed := extract(epoch from (now() - v_started));
    v_total   := greatest(extract(epoch from (v_ends - v_started)), 0.000001);
    v_bonus   := 100 * greatest(0::numeric, least(1::numeric, (v_total - v_elapsed) / v_total));
    v_points  := 100 + round(v_bonus)::int;
  end if;

  -- Insert, attempting the first-correct claim. Losing the race to
  -- one_winner_per_round still records the guess, as correct-but-second worth 0.
  begin
    insert into public.guesses
         (round_id, player_id, raw, normalised, verdict, match_tier, is_first_correct, points)
    values (p_round_id, v_player, p_guess, v_norm, v_verdict, v_tier, v_correct, v_points);
  exception when unique_violation then
    insert into public.guesses
         (round_id, player_id, raw, normalised, verdict, match_tier, is_first_correct, points)
    values (p_round_id, v_player, p_guess, v_norm, v_verdict, v_tier, false, 0);
    -- THE FIX (0012): 0005 stored the right row and then returned the stale locals,
    -- so the loser was told "is_first_correct: true, points: 187".
    v_first  := false;
    v_points := 0;
  end;

  return jsonb_build_object(
    'verdict',          v_verdict,
    'match_tier',       v_tier,
    'is_first_correct', v_first,
    'points',           v_points
  );
end;
$$;

comment on function public.grade_guess(uuid, text) is
  'Grades one guess inside Postgres and returns a verdict only, never the answer. '
  'v3 (0012): the first-correct race loser is now told the truth (is_first_correct '
  'false, points 0) instead of the winner''s values; near and season-lenient matching '
  'require 5+ characters, which closes the one-letter win on short synonyms such as '
  '''hq'' / ''sao'' / ''fma''; the speed-bonus clamp ceiling is 1, not 100. '
  'Errors: GUESS_TOO_LONG, EMPTY_GUESS, NOT_A_MEMBER, ROUND_NOT_ACTIVE, '
  'EMPTY_NORMALISED, ALREADY_CORRECT.';

-- ---------------------------------------------------------------------------
-- 4. create_room v2 -- one question per anime, and genuinely dense ordinals
-- ---------------------------------------------------------------------------

create or replace function public.create_room(p_settings jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';  -- no I L O U
  v_uid        uuid := auth.uid();
  v_name       text;
  v_count      smallint;
  v_dmin       smallint;
  v_dmax       smallint;
  v_audio      boolean;
  v_code       text;
  v_attempts   int  := 0;
  v_room       uuid;
  v_player     uuid;
  v_inserted   bigint;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  v_name  := btrim(coalesce(p_settings ->> 'display_name', ''));
  v_count := coalesce((p_settings ->> 'round_count')::smallint, 10);
  v_dmin  := coalesce((p_settings ->> 'difficulty_min')::smallint, 1);
  v_dmax  := coalesce((p_settings ->> 'difficulty_max')::smallint, 5);
  v_audio := coalesce((p_settings ->> 'audio_enabled')::boolean, true);

  if v_name = '' or length(v_name) > 24 then
    raise exception 'BAD_NAME';
  end if;
  if v_count not between 3 and 20 then
    raise exception 'BAD_ROUND_COUNT';
  end if;
  if v_dmin not between 1 and 5 or v_dmax not between 1 and 5
     or v_dmin > v_dmax then
    raise exception 'BAD_DIFFICULTY';
  end if;

  loop
    v_attempts := v_attempts + 1;
    if v_attempts > 5 then
      raise exception 'CODE_EXHAUSTED';
    end if;

    v_code := '';
    for i in 1..4 loop
      v_code := v_code || substr(c_alphabet, floor(random() * 32)::int + 1, 1);
    end loop;

    begin
      insert into public.rooms (
        code, round_count, difficulty_min, difficulty_max, audio_enabled
      ) values (
        v_code, v_count, v_dmin, v_dmax, v_audio
      )
        returning id into v_room;
      exit;
    exception when unique_violation then
      continue;
    end;
  end loop;

  -- Pre-select the questions.
  --
  -- TWO CHANGES IN 0012.
  --
  -- (a) One question per anime. question_bank.anime_slug existed and was unused, and
  --     unique(room_id, question_id) only stops the same THEME twice. With 46 anime
  --     across ~134 questions, about half of all 10-round games drew one show twice --
  --     and the second time it is free points, since the titles match.
  --
  -- (b) LIMIT is applied BEFORE row_number(), in an inner subquery. The previous
  --     version numbered the whole filtered set and then took `limit v_count` with no
  --     outer ORDER BY, relying on the plan to emit rows in window order. Window
  --     evaluation does precede LIMIT, but LIMIT without ORDER BY returns an
  --     ARBITRARY subset -- dense 1..N was a plan artefact, not a guarantee. Sparse
  --     ordinals would leave start_game (WHERE ordinal = 1) matching nothing and the
  --     room permanently unstartable, and the row_count check below cannot see it.
  with per_anime as (
    select distinct on (q.anime_slug) q.id
      from public.question_bank q
     where q.difficulty between v_dmin and v_dmax
       and q.retired_at is null
     order by q.anime_slug, random()
  ),
  sampled as (
    select id from per_anime order by random() limit v_count
  ),
  picked as (
    select id, row_number() over () as ord from sampled
  )
  insert into public.rounds (room_id, ordinal, question_id)
  select v_room, p.ord, p.id
    from picked p;

  get diagnostics v_inserted = row_count;
  if v_inserted <> v_count then
    raise exception 'INSUFFICIENT_CONTENT (% distinct anime available for % rounds)',
      v_inserted, v_count;
  end if;

  insert into public.players (room_id, auth_uid, display_name)
  values (v_room, v_uid, v_name)
  returning id into v_player;

  update public.rooms
     set host_player_id = v_player
   where id = v_room;

  return jsonb_build_object('room_id', v_room, 'code', v_code);
end;
$$;

comment on function public.create_room(jsonb) is
  'Validates settings, retries code collisions, pre-selects one question PER ANIME '
  '(0012: repeats were free points), numbers rounds densely by limiting before the '
  'window (0012: dense 1..N was previously a plan artefact), creates the host player. '
  'INSUFFICIENT_CONTENT now counts distinct anime, not questions. Errors: '
  'AUTH_REQUIRED, BAD_NAME, BAD_ROUND_COUNT, BAD_DIFFICULTY, CODE_EXHAUSTED, '
  'INSUFFICIENT_CONTENT.';

-- ---------------------------------------------------------------------------
-- 5. join_room v2 -- the player cap the design always claimed
-- ---------------------------------------------------------------------------

create or replace function public.join_room(
  p_code         text,
  p_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_max_players constant int := 8;
  v_uid    uuid := auth.uid();
  v_name   text;
  v_room   uuid;
  v_state  text;
  v_player uuid;
  v_n      int;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  v_name := btrim(coalesce(p_display_name, ''));
  if v_name = '' or length(v_name) > 24 then
    raise exception 'BAD_NAME';
  end if;

  -- FOR UPDATE serialises concurrent joins against this room, which is what makes the
  -- capacity check below a real check rather than a suggestion. 0005 read the state
  -- without a lock, so a start_game committing between the read and the INSERT could
  -- also admit a player into an already-running game.
  select r.id, r.state into v_room, v_state
    from public.rooms r
   where r.code = upper(btrim(coalesce(p_code, '')))
   for update;

  if v_room is null then
    raise exception 'ROOM_NOT_FOUND';
  end if;
  if v_state <> 'lobby' then
    raise exception 'NOT_IN_LOBBY';
  end if;

  -- doc/GAME-DESIGN.md 2 promises 2-8 players and nothing enforced it before 0012.
  -- Unbounded joins are also an egress attack: the 5 GB monthly budget assumes 8
  -- players per room, so a 50-player room spends ~7x what it is allowed to.
  select count(*) into v_n
    from public.players p
   where p.room_id = v_room;

  if v_n >= c_max_players then
    -- A player rejoining their own seat is not a new player and must not be capped.
    if not exists (
         select 1 from public.players p
          where p.room_id = v_room and p.auth_uid = v_uid
       ) then
      raise exception 'ROOM_FULL';
    end if;
  end if;

  begin
    insert into public.players (room_id, auth_uid, display_name)
    values (v_room, v_uid, v_name)
    returning id into v_player;
  exception when unique_violation then
    if exists (
         select 1 from public.players p
          where p.room_id = v_room and p.auth_uid = v_uid
       ) then
      raise exception 'ALREADY_IN_ROOM';
    else
      raise exception 'NAME_TAKEN';
    end if;
  end;

  return jsonb_build_object('room_id', v_room, 'player_id', v_player);
end;
$$;

comment on function public.join_room(text, text) is
  'Inserts a players row. v2 (0012): locks the room row FOR UPDATE and enforces the '
  '8-player cap the design always claimed -- unbounded joins broke the egress budget '
  'and the lock also closes the start_game/join race. Errors: AUTH_REQUIRED, BAD_NAME, '
  'ROOM_NOT_FOUND, NOT_IN_LOBBY, ROOM_FULL, ALREADY_IN_ROOM, NAME_TAKEN.';

-- ---------------------------------------------------------------------------
-- 6. start_game v2 -- topic keyed by room id
-- ---------------------------------------------------------------------------
-- Only the broadcast topic changes. 'room:' || code put every game on a channel
-- named from a 4-character alphabet -- about a million topics, enumerable, and
-- realtime.send publishes it as a PUBLIC channel. The room id is a uuid the client
-- already holds (create_room and join_room both return it), so keying on it costs
-- nothing and makes the channel unguessable.

create or replace function public.start_game(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_host     uuid;
  v_me       uuid;
  v_deadline timestamptz;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select r.host_player_id into v_host
    from public.rooms r
   where r.id = p_room_id;

  if v_host is null then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  select p.id into v_me
    from public.players p
   where p.room_id = p_room_id
     and p.auth_uid = v_uid;

  if v_me is null or v_me <> v_host then
    raise exception 'NOT_HOST' using errcode = '42501';
  end if;

  update public.rooms
     set state         = 'playing',
         current_round = 1,
         deadline      = now() + round_duration
   where id = p_room_id
     and state = 'lobby'
  returning deadline into v_deadline;

  if not found then
    return;  -- already started, or not a lobby: idempotent, not an error
  end if;

  -- Round 1 has no reveal before it, so it starts immediately.
  update public.rounds
     set started_at = now(),
         ends_at    = v_deadline
   where room_id = p_room_id
     and ordinal  = 1;

  perform public.emit_room_event(
    'room:' || p_room_id::text,
    'ROUND_START',
    jsonb_build_object('room_id', p_room_id, 'ordinal', 1, 'ends_at', v_deadline)
  );
end;
$$;

comment on function public.start_game(uuid) is
  'Host-only, idempotent lobby -> playing transition; stamps round 1 from the same '
  'deadline it writes. v2 (0012): broadcasts on room:<uuid> rather than room:<code>, '
  'because realtime.send publishes a PUBLIC channel and a 4-character topic is '
  'enumerable. Errors: AUTH_REQUIRED, ROOM_NOT_FOUND, NOT_HOST.';

-- ---------------------------------------------------------------------------
-- 7. advance_round v2 -- reveal the last round, and make the reveal phase real
-- ---------------------------------------------------------------------------

create or replace function public.advance_round(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_round    smallint;
  v_deadline timestamptz;
  v_count    smallint;
  v_reveal   jsonb;
  v_prev_ord smallint;
  v_poster   text;
  v_reveal_s interval;
begin
  -- CHANGED IN 0012: the membership check is unconditional. 0005 skipped it whenever
  -- auth.uid() was NULL, on the reasoning that "PostgREST requests always carry a JWT,
  -- so a real client is always checked" -- but a request bearing only the publishable
  -- anon key runs as role anon with no sub claim, so auth.uid() IS NULL and the guard
  -- was skipped. The stated beneficiary was a pg_cron sweep that has never existed,
  -- and pg_cron would run as a table owner, not as anon. The anon grant is revoked at
  -- the foot of this file.
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
       select 1 from public.players p
        where p.room_id = p_room_id and p.auth_uid = v_uid
     ) then
    raise exception 'NOT_A_MEMBER' using errcode = '42501';
  end if;

  select r.reveal_duration into v_reveal_s
    from public.rooms r
   where r.id = p_room_id;

  -- The guard tests deadline, a column this same UPDATE writes. That is what makes it
  -- idempotent under a race (B-17): the second writer re-evaluates WHERE against the
  -- updated row, finds the deadline pushed into the future, and updates 0 rows. Any
  -- edit here MUST keep the guard column and a mutated column the same column.
  --
  -- CHANGED IN 0012: the next window is reveal_duration + round_duration, not just
  -- round_duration. The extra head is the reveal phase -- see the started_at stamp
  -- below.
  update public.rooms
     set current_round = current_round + 1,
         deadline      = now() + reveal_duration + round_duration
   where id = p_room_id
     and state = 'playing'
     and now() >= deadline
  returning current_round, deadline, round_count
       into v_round, v_deadline, v_count;

  if not found then
    return;  -- lost the race, or not yet due: the winner owns everything below
  end if;

  -- ROUND_REVEAL for the round that just finished.
  --
  -- MOVED IN 0012: this block used to sit AFTER the game-over branch, so the final
  -- round -- the one players had just spent 20 s on -- never revealed its answer.
  -- It now runs before the branch, so every round reveals exactly once.
  --
  -- The poster key is computed here rather than stored in question_bank.reveal: the
  -- reveal payload had no image at all, and get_current_round strips poster during
  -- play on purpose (it is harvested from the frames OCR REJECTED for containing
  -- text, so it is the single most spoiling frame of the sequence).
  select qb.reveal,
         rd.ordinal,
         public.question_asset_keys(
           qb.asset_slug, qb.poster_slug, qb.audio_slug, qb.still_count) ->> 'poster'
    into v_reveal, v_prev_ord, v_poster
    from public.rounds rd
    join public.question_bank qb on qb.id = rd.question_id
   where rd.room_id = p_room_id
     and rd.ordinal = v_round - 1;

  if v_prev_ord is not null then
    perform public.emit_room_event(
      'room:' || p_room_id::text,
      'ROUND_REVEAL',
      jsonb_build_object(
        'room_id', p_room_id,
        'ordinal', v_prev_ord,
        'reveal',  v_reveal || jsonb_build_object('poster', v_poster))
    );
  end if;

  if v_round > v_count then
    update public.rooms
       set state = 'over', deadline = null
     where id = p_room_id;

    perform public.emit_room_event(
      'room:' || p_room_id::text,
      'GAME_OVER',
      jsonb_build_object('room_id', p_room_id)
    );
    return;
  end if;

  -- Stamp the next round from the SAME deadline this transaction wrote (B-23).
  --
  -- CHANGED IN 0012: started_at is now() + reveal_duration, not now(). That gap is
  -- the reveal phase, and it is enforced rather than advisory: grade_guess rejects
  -- anything outside [started_at, ends_at], so nobody can guess ahead while the
  -- previous answer is on screen. rooms.reveal_duration was previously read by
  -- nothing at all and state='reveal' was set by nothing at all.
  update public.rounds
     set started_at = now() + v_reveal_s,
         ends_at    = v_deadline
   where room_id = p_room_id
     and ordinal  = v_round;

  perform public.emit_room_event(
    'room:' || p_room_id::text,
    'ROUND_START',
    jsonb_build_object(
      'room_id',    p_room_id,
      'ordinal',    v_round,
      'starts_at',  now() + v_reveal_s,
      'ends_at',    v_deadline)
  );
end;
$$;

comment on function public.advance_round(uuid) is
  'Idempotent round advance; the guard tests deadline, a column the UPDATE writes '
  '(B-17). v2 (0012): ROUND_REVEAL moved ahead of the game-over branch so the FINAL '
  'round reveals too; the reveal payload carries the poster key; the next round''s '
  'started_at is pushed reveal_duration into the future, which makes the reveal phase '
  'real and unguessable-ahead; membership is checked unconditionally; topics are keyed '
  'by room id. Errors: AUTH_REQUIRED, NOT_A_MEMBER.';

-- ---------------------------------------------------------------------------
-- 8. Grants -- remove what was never needed
-- ---------------------------------------------------------------------------
-- Supabase anonymous sign-in issues a JWT with role=authenticated, so a real player
-- is never role=anon. The anon grants bought nothing and, on advance_round, actively
-- disabled a membership check. Revoked.
--
-- emit_room_event is the one function in 0005 that is NOT security definer, despite
-- that file's header claiming every function is. Granted to authenticated, it lets a
-- client call realtime.send directly on any topic -- forged ROUND_REVEAL into someone
-- else's game -- for exactly as long as realtime.send is executable by authenticated.
-- No client needs it: every legitimate emit happens inside a definer function.

revoke execute on function public.grade_guess(uuid, text)   from anon;
revoke execute on function public.create_room(jsonb)        from anon;
revoke execute on function public.join_room(text, text)     from anon;
revoke execute on function public.start_game(uuid)          from anon;
revoke execute on function public.advance_round(uuid)       from anon;
revoke execute on function public.emit_room_event(text, text, jsonb) from anon, authenticated;

-- A zero round_duration would make the speed-bonus denominator collapse to its
-- 0.000001 floor. The clamp fix above already caps the payout, but the column should
-- not accept it either.
alter table public.rooms drop constraint if exists rooms_durations_positive;
alter table public.rooms add constraint rooms_durations_positive
  check (round_duration > interval '0' and reveal_duration > interval '0');


