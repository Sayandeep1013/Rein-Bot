-- 20260822000005_game_functions.sql
-- ReIN Bot -- the only write paths in the database. Implements doc/DATA-MODEL.md 6.2-6.5.
--
-- Every function here is SECURITY DEFINER with `set search_path = ''` and fully
-- qualified names throughout (CVE-2018-1058). Extensions resolve as extensions.*,
-- project functions as public.* -- a mistake there does not fail CREATE, it fails at
-- first execution, which is why these are execution-tested after apply, not just run.
--
-- Caller policy (doc/DATA-MODEL.md 6.4/7.3): create_room/join_room/start_game require an
-- anonymous-auth session (auth.uid() not null). grade_guess requires membership.
-- advance_round additionally serves pg_cron, which runs OUTSIDE any request context:
-- there auth.uid() is NULL, so a NULL uid is accepted for advance_round ONLY -- and is
-- harmless, because its WHERE gate makes any early call match zero rows. Supabase lint
-- 0028 (anon can execute SECURITY DEFINER) will fire on all of these; that is by
-- design and recorded in doc/DATA-MODEL.md 7.3.
--
-- FLAGGED judgement calls (cheap to override, no schema change):
--   1. p_settings carries display_name; create_room inserts the creator's players row
--      and sets host_player_id. doc/DATA-MODEL.md 6.3 does not say who the host is, but
--      6.5 says start_game is host-only, so SOMEONE must be host from creation on.
--      First-joiner-becomes-host was rejected: racy and specified nowhere.
--   2. Broadcasts use realtime.send(payload, event, topic, is_private := false) --
--      PUBLIC channels. Verified signature against supabase.com/docs/guides/realtime/
--      broadcast. Membership is enforced at the data layer (RLS + function guards);
--      public channels keep pre-auth lobby listeners possible. If private channels are
--      wanted later, this changes in emit_room_event only.

-- ---------------------------------------------------------------------------
-- emit_room_event -- single seam through which every broadcast flows.
-- ---------------------------------------------------------------------------
-- Kept as a wrapper so realtime.send signature drift or a switch to private channels
-- is fixed in ONE place rather than at each call site. Payloads carry identifiers
-- only; every message is reconstructible from table state (doc/ARCHITECTURE.md 9), so a
-- client that misses one re-reads rooms and catches up.

create or replace function public.emit_room_event(
  p_topic   text,
  p_event   text,
  p_payload jsonb
)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform realtime.send(p_payload, p_event, p_topic, false);  -- false = public channel
end;
$$;

-- ---------------------------------------------------------------------------
-- grade_guess(p_round_id uuid, p_guess text) -> jsonb
-- ---------------------------------------------------------------------------
-- doc/DATA-MODEL.md 6.2, steps in spec order. Returns verdict/match_tier/is_first_correct/
-- points and NEVER the answer: a client holding the answer mid-round has no use for it
-- except to leak it into the UI.
--
-- Tier order (doc/GAME-DESIGN.md 4.3): exact -> near -> season_lenient -> prefix.
-- Near threshold: levenshtein_less_equal <= 2 when the LONGER of the two strings
-- exceeds 8 chars, else <= 1. levenshtein_less_equal short-circuits past the threshold;
-- plain Levenshtein only (no Damerau exists in fuzzystrmatch) -- a transposition costs
-- 2, accepted deliberately as a false-negative bias (doc/GAME-DESIGN.md 4.3.1).
-- Season-lenient: strip_season_markers(guess_norm) = strip_season_markers(title_norm)
-- AND they are not already equal (migration 20260822000002 header).
-- Prefix: submission >= 8 chars and is a prefix of a candidate.
--
-- Scoring (doc/GAME-DESIGN.md 6.2, B-22 winner-takes-all): first correct guess earns
-- 100 + speed bonus decaying linearly 100 -> 0 across [started_at, ends_at] (200
-- first-second, 100 last-second). Every correct tier scores identically. Everyone else
-- scores 0, correct or not. one_winner_per_round IS the scoring rule; the loser's guess
-- is still recorded via the unique_violation branch -- ON CONFLICT DO NOTHING would
-- discard evidence the reveal depends on.

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
  v_points     int    := 0;
  v_elapsed    numeric;
  v_total      numeric;
  v_bonus      numeric;
begin
  -- Defensive length cap. The application layer caps too (doc/DATA-MODEL.md 2.1); this is
  -- the backstop because levenshtein raises on inputs over 255 chars.
  if p_guess is null or length(p_guess) > 255 then
    raise exception 'GUESS_TOO_LONG';
  end if;

  -- Step 3 (before normalising): reject empty or whitespace-only guesses.
  if btrim(p_guess) = '' then
    raise exception 'EMPTY_GUESS';
  end if;

  -- Step 1: resolve caller to a players row via auth.uid(); reject non-members.
  select pl.id into v_player
    from public.players pl
    join public.rounds rd on rd.room_id = pl.room_id
   where rd.id = p_round_id
     and pl.auth_uid = auth.uid()
   limit 1;

  if v_player is null then
    raise exception 'NOT_A_MEMBER' using errcode = '42501';
  end if;

  -- Step 2: load the round; reject if now() is outside [started_at, ends_at].
  -- NULL window counts as outside: now() < NULL is NULL, never true.
  select rd.room_id, rd.question_id, rd.started_at, rd.ends_at
    into v_room_id, v_question, v_started, v_ends
    from public.rounds rd
   where rd.id = p_round_id;

  if v_started is null or v_ends is null
     or now() < v_started or now() > v_ends then
    raise exception 'ROUND_NOT_ACTIVE';
  end if;

  -- Step 4: normalise; reject if the result is empty (mirrors title_norm_not_empty).
  v_norm := public.normalise_title(p_guess);
  if v_norm is null or v_norm = '' then
    raise exception 'EMPTY_NORMALISED';
  end if;
  v_stripped := public.strip_season_markers(v_norm);

  -- Step 5: reject if this player already has a correct guess for this round.
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

  -- Step 6: compare against question_titles for the round's question, tier order.
  select c.title_norm, c.pr
    into v_title, v_pr
    from (
      select qt.title_norm,
             case
               when qt.title_norm = v_norm
                 then 1  -- exact
               when extensions.levenshtein_less_equal(
                      qt.title_norm, v_norm,
                      case when greatest(length(qt.title_norm), length(v_norm)) > 8
                           then 2 else 1 end)
                    <= case when greatest(length(qt.title_norm), length(v_norm)) > 8
                            then 2 else 1 end
                 then 2  -- near
               when qt.title_norm <> v_norm
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
    v_verdict := 'correct';
    v_tier    := case v_pr
                   when 1 then 'exact'
                   when 2 then 'near'
                   when 3 then 'season_lenient'
                   when 4 then 'prefix'
                 end;

    -- Speed bonus decays linearly 100 -> 0 across the window; round to nearest point.
    v_elapsed := extract(epoch from (now() - v_started));
    v_total   := greatest(extract(epoch from (v_ends - v_started)), 0.000001);
    v_bonus   := 100 * greatest(0::numeric, least(100::numeric, (v_total - v_elapsed) / v_total));
    v_points  := 100 + round(v_bonus)::int;
  end if;

  -- Step 7: insert. When correct, attempt the first-correct claim; losing the race to
  -- one_winner_per_round still records the guess as correct-but-second, 0 points.
  begin
    insert into public.guesses
         (round_id, player_id, raw, normalised, verdict, match_tier, is_first_correct, points)
    values (p_round_id, v_player, p_guess, v_norm, v_verdict, v_tier, v_correct, v_points);
  exception when unique_violation then
    insert into public.guesses
         (round_id, player_id, raw, normalised, verdict, match_tier, is_first_correct, points)
    values (p_round_id, v_player, p_guess, v_norm, v_verdict, v_tier, false, 0);
  end;

  -- Step 8: verdict only. No answer in the payload, either way.
  return jsonb_build_object(
    'verdict',         v_verdict,
    'match_tier',      v_tier,
    'is_first_correct', v_correct,
    'points',          v_points
  );
end;
$$;

comment on function public.grade_guess(uuid, text) is
  'The only path by which a guess enters the database. Winner-takes-all scoring '
  '(B-22); submitted_at defaults to transaction-start now(). Errors: GUESS_TOO_LONG, '
  'EMPTY_GUESS, NOT_A_MEMBER, ROUND_NOT_ACTIVE, EMPTY_NORMALISED, ALREADY_CORRECT.';

-- ---------------------------------------------------------------------------
-- create_room(p_settings jsonb) -> jsonb {room_id, code}
-- ---------------------------------------------------------------------------
-- doc/DATA-MODEL.md 6.3. Validates settings, generates a Crockford base32 code with
-- retry-on-collision, pre-selects ALL rounds' questions up front (filtered by
-- difficulty range, excluding retired) so a game cannot begin and then run out of
-- content, creates the host player row, and sets host_player_id. All within this one
-- implicit transaction: INSUFFICIENT_CONTENT rolls back room AND rounds AND player.

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
      insert into public.rooms (code) values (v_code)
        returning id into v_room;
      exit;
    exception when unique_violation then
      -- code collision: 32^4 codes vs ~25 concurrent rooms, effectively never twice
      continue;
    end;
  end loop;

  -- Pre-select questions. Window ranks BEFORE limit, so ordinals are dense 1..N.
  -- NOTE for future readers: an earlier draft here declared the variable as v_count
  -- but referenced v_round_count, and execution testing surfaced it as
  -- '42703: column "v_round_count" does not exist' -- PL/pgSQL reports UNDECLARED
  -- names that way in every SQL context, including IF expressions. Two successive
  -- "parser limitation" theories were wrong; it was a typo both times.
  with picked as (
    select q.id, q.clip_key,
           row_number() over (order by random()) as ord
      from public.question_bank q
     where q.difficulty between v_dmin and v_dmax
       and q.retired_at is null
     limit v_count
  )
  insert into public.rounds (room_id, ordinal, question_id, clip_key)
  select v_room, p.ord, p.id, p.clip_key
    from picked p;

  get diagnostics v_inserted = row_count;
  if v_inserted <> v_count then
    raise exception 'INSUFFICIENT_CONTENT (% of % available)',
      v_inserted, v_count;
  end if;

  -- Host identity (FLAGGED inference; see file header).
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
  'Validates round_count 3-20 and difficulty range, retries code collisions against '
  'the Crockford check, pre-selects all rounds'' questions, creates the host player. '
  'Errors: AUTH_REQUIRED, BAD_NAME, BAD_ROUND_COUNT, BAD_DIFFICULTY, CODE_EXHAUSTED, '
  'INSUFFICIENT_CONTENT.';

-- ---------------------------------------------------------------------------
-- join_room(p_code text, p_display_name text) -> jsonb {room_id, player_id}
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
  v_uid    uuid := auth.uid();
  v_name   text;
  v_room   uuid;
  v_state  text;
  v_player uuid;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  v_name := btrim(coalesce(p_display_name, ''));
  if v_name = '' or length(v_name) > 24 then
    raise exception 'BAD_NAME';
  end if;

  -- Stored uppercase, join upper-cases input: case-insensitive to type.
  select r.id, r.state into v_room, v_state
    from public.rooms r
   where r.code = upper(btrim(coalesce(p_code, '')));

  if v_room is null then
    raise exception 'ROOM_NOT_FOUND';
  end if;
  if v_state <> 'lobby' then
    raise exception 'NOT_IN_LOBBY';
  end if;

  begin
    insert into public.players (room_id, auth_uid, display_name)
    values (v_room, v_uid, v_name)
    returning id into v_player;
  exception when unique_violation then
    -- Surface the two unique constraints as distinct friendly errors.
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
  'Inserts a players row; rejects rooms not in lobby. Unique violations surface as '
  'ALREADY_IN_ROOM / NAME_TAKEN, never raw SQL errors. Errors: AUTH_REQUIRED, '
  'BAD_NAME, ROOM_NOT_FOUND, NOT_IN_LOBBY.';

-- ---------------------------------------------------------------------------
-- start_game(p_room_id uuid) -> void. doc/DATA-MODEL.md 6.5 (B-24).
-- ---------------------------------------------------------------------------
-- The lobby -> playing transition. advance_round cannot do this job: its guard needs
-- state='playing' AND now() >= deadline, but a lobby room has deadline NULL, so
-- now() >= NULL is NULL forever. This function exists BECAUSE of that dead branch.
--
-- Guard safety (B-17 property): the guard tests state, the same column the statement
-- writes, so a second concurrent caller re-evaluates against the committed row and
-- matches zero rows. Double-clicking Start is harmless.

create or replace function public.start_game(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_host      uuid;
  v_me        uuid;
  v_deadline  timestamptz;
  v_code      text;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select r.host_player_id, r.code into v_host, v_code
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

  -- Stamp round 1 from the SAME deadline value written above (B-23): the two cannot
  -- drift because there is exactly one source.
  update public.rounds
     set started_at = now(),
         ends_at    = v_deadline
   where room_id = p_room_id
     and ordinal  = 1;

  perform public.emit_room_event(
    'room:' || v_code,
    'ROUND_START',
    jsonb_build_object('room_id', p_room_id, 'ordinal', 1, 'ends_at', v_deadline)
  );
end;
$$;

comment on function public.start_game(uuid) is
  'Host-only lobby->playing transition (B-24). Idempotent by construction: the guard '
  'tests the same column the UPDATE mutates. Stamps round 1 behind the not-found gate '
  '(B-23). Errors: AUTH_REQUIRED, ROOM_NOT_FOUND, NOT_HOST.';

-- ---------------------------------------------------------------------------
-- advance_round(p_room_id uuid) -> void. doc/DATA-MODEL.md 6.4.
-- ---------------------------------------------------------------------------
-- Advances an already-running game N -> N+1. Cannot start a game. Callable by any
-- member and by pg_cron (NULL uid outside request context -- see caller policy above;
-- the WHERE gate makes early calls no-ops, so a stranger triggering it is harmless).
--
-- DO NOT MODIFY THE WHERE CLAUSE WITHOUT RE-READING B-17: the guarantee depends on the
-- guard testing deadline, a column this same statement mutates. A guard on state alone
-- re-evaluates TRUE for every waiting writer under READ COMMITTED and they all advance.
-- Eight simultaneous callers advance the round exactly once.

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
  v_code     text;
  -- Scalars, NOT a record: execution testing caught that assigning into fields of a
  -- never-assigned record ('select .. into v_prev.reveal') raises 55000 "record not
  -- assigned yet". A record only gains a tuple structure by whole-record assignment.
  v_reveal   jsonb;
  v_prev_ord smallint;
begin
  -- Member check skipped when uid is NULL (pg_cron). PostgREST requests always carry
  -- a JWT, so a real client is always checked here.
  if v_uid is not null then
    if not exists (
         select 1 from public.players p
          where p.room_id = p_room_id and p.auth_uid = v_uid
       ) then
      raise exception 'NOT_A_MEMBER' using errcode = '42501';
    end if;
  end if;

  update public.rooms
     set current_round = current_round + 1,
         deadline      = now() + round_duration
   where id = p_room_id
     and state = 'playing'
     and now() >= deadline
  returning current_round, deadline, round_count
       into v_round, v_deadline, v_count;

  if not found then
    return;  -- lost the race, or not yet due: the winner owns everything below
  end if;

  select r.code into v_code from public.rooms r where r.id = p_room_id;

  if v_round > v_count then
    update public.rooms
       set state = 'over', deadline = null
     where id = p_room_id;
    -- GAME_OVER behind the same gate; there is no round v_round to stamp.
    perform public.emit_room_event(
      'room:' || v_code,
      'GAME_OVER',
      jsonb_build_object('room_id', p_room_id)
    );
    return;
  end if;

  -- Stamp the new current round from the SAME v_deadline this statement wrote -- NOT
  -- now() + round_duration a second time, or grading and advancing disagree by however
  -- long the function took (doc/DATA-MODEL.md 4.3 invariant).
  update public.rounds
     set started_at = now(),
         ends_at    = v_deadline
   where room_id = p_room_id
     and ordinal  = v_round;

  -- ROUND_REVEAL for the finished round, reading question_bank.reveal via DEFINER --
  -- callers cannot read content tables themselves (7.1). Behind the same gate, or
  -- eight callers emit eight reveals for one transition (B-23 note 2).
  select qb.reveal, rd.ordinal
    into v_reveal, v_prev_ord
    from public.rounds rd
    join public.question_bank qb on qb.id = rd.question_id
   where rd.room_id = p_room_id
     and rd.ordinal = v_round - 1;

  perform case
            when v_prev_ord is not null
              then public.emit_room_event(
                     'room:' || v_code,
                     'ROUND_REVEAL',
                     jsonb_build_object(
                       'room_id', p_room_id,
                       'ordinal', v_prev_ord,
                       'reveal',  v_reveal))
            else null
          end;

  perform public.emit_room_event(
    'room:' || v_code,
    'ROUND_START',
    jsonb_build_object('room_id', p_room_id, 'ordinal', v_round, 'ends_at', v_deadline)
  );
end;
$$;

comment on function public.advance_round(uuid) is
  'Idempotent round advance; guard tests deadline, a column the UPDATE writes (B-17). '
  'Stamps the next round from the same deadline value (B-23), emits ROUND_REVEAL and '
  'ROUND_START behind the not-found gate, sets state=over past round_count.';

-- ---------------------------------------------------------------------------
-- Execution grants. PUBLIC has EXECUTE by default; revoke it so the grant list states
-- intent, then grant to anon + authenticated. Lint 0028 fires on these four-plus-one
-- SD functions being anon-callable -- expected, see doc/DATA-MODEL.md 7.3.
-- ---------------------------------------------------------------------------

revoke execute on function public.emit_room_event(text, text, jsonb) from public;
revoke execute on function public.grade_guess(uuid, text)                from public;
revoke execute on function public.create_room(jsonb)                     from public;
revoke execute on function public.join_room(text, text)                  from public;
revoke execute on function public.start_game(uuid)                       from public;
revoke execute on function public.advance_round(uuid)                    from public;

grant execute on function public.emit_room_event(text, text, jsonb) to authenticated;
grant execute on function public.grade_guess(uuid, text)
  to anon, authenticated;
grant execute on function public.create_room(jsonb)
  to anon, authenticated;
grant execute on function public.join_room(text, text)
  to anon, authenticated;
grant execute on function public.start_game(uuid)
  to anon, authenticated;
grant execute on function public.advance_round(uuid)
  to anon, authenticated;
