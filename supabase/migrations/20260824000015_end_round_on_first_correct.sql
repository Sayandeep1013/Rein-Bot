-- 0015 -- a round ends the moment someone gets it.
--
-- WHY
-- Under winner-takes-all only the first correct guess scores, so every second after it
-- is dead air: the round is decided, nobody else can earn anything, and the players sit
-- watching a timer run down on a question that is already answered. Observed directly
-- in the first two-browser playtest.
--
-- HOW, AND WHY IT IS NOT A NEW MECHANISM
-- grade_guess pulls the round's `ends_at` and the room's `deadline` back to now() when
-- it records a first-correct guess. Nothing else changes:
--
--   * Round progression is still client-driven. The existing `now() >= deadline` guard
--     in advance_round becomes true immediately, so the next poll advances the round
--     exactly as a natural timeout would. There is no second code path.
--   * The B-17 double-advance protection is untouched. That guard works because the
--     UPDATE's WHERE tests `deadline`, a column the same UPDATE writes; pulling
--     `deadline` backwards from a different function does not weaken it.
--   * get_room_state's reveal is gated on `now() >= rd.ends_at`, so moving `ends_at`
--     back is precisely what makes the answer publishable -- the gate is a fact about
--     elapsed time, not about round number, and it stays that way.
--   * grade_guess's own `now() > v_ends` rejection is evaluated from the values read at
--     the top of the call, before this write, so the winner's own guess cannot be
--     invalidated by it. Any LATER guess correctly gets ROUND_NOT_ACTIVE, which is the
--     desired behaviour: the round really is over.
--
-- The speed bonus is unaffected: it was already derived from now() - started_at at the
-- moment of the guess.
--
-- One consequence worth stating plainly: a round nobody answers still runs its full
-- duration, which is correct -- the clock is the only thing that can end it.
--
-- IDEMPOTENT: create-or-replace.

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

  select c.title_norm, c.pr
    into v_title, v_pr
    from (
      select qt.title_norm,
             case
               when qt.title_norm = v_norm
                 then 1
               when greatest(length(qt.title_norm), length(v_norm)) >= 5
                    and extensions.levenshtein_less_equal(
                          qt.title_norm, v_norm,
                          case when greatest(length(qt.title_norm), length(v_norm)) > 8
                               then 2 else 1 end)
                        <= case when greatest(length(qt.title_norm), length(v_norm)) > 8
                                then 2 else 1 end
                 then 2
               when qt.title_norm <> v_norm
                    and length(v_stripped) >= 5
                    and public.strip_season_markers(qt.title_norm) = v_stripped
                 then 3
               when length(v_norm) >= 8
                    and left(qt.title_norm, length(v_norm)) = v_norm
                 then 4
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

    v_elapsed := extract(epoch from (now() - v_started));
    v_total   := greatest(extract(epoch from (v_ends - v_started)), 0.000001);
    v_bonus   := 100 * greatest(0::numeric, least(1::numeric, (v_total - v_elapsed) / v_total));
    v_points  := 100 + round(v_bonus)::int;
  end if;

  begin
    insert into public.guesses
         (round_id, player_id, raw, normalised, verdict, match_tier, is_first_correct, points)
    values (p_round_id, v_player, p_guess, v_norm, v_verdict, v_tier, v_correct, v_points);
  exception when unique_violation then
    insert into public.guesses
         (round_id, player_id, raw, normalised, verdict, match_tier, is_first_correct, points)
    values (p_round_id, v_player, p_guess, v_norm, v_verdict, v_tier, false, 0);
    v_first  := false;
    v_points := 0;
  end;

  -- NEW IN 0015. Winning ends the round for everyone.
  --
  -- Guarded on v_first, so it runs exactly once per round -- the unique index
  -- one_winner_per_round already guarantees only one caller reaches here with
  -- v_first still true, which is the same guarantee the scoring rests on.
  --
  -- Both columns move together and both are set from the same now(): rounds.ends_at
  -- publishes the reveal (get_room_state gates on now() >= ends_at) and rooms.deadline
  -- makes advance_round due (its guard is now() >= deadline). doc/DATA-MODEL.md 4.3
  -- requires deadline to equal the current round's ends_at, and this preserves that.
  if v_first then
    update public.rounds
       set ends_at = now()
     where id = p_round_id;

    update public.rooms
       set deadline = now()
     where id = v_room_id
       and state = 'playing';
  end if;

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
  'v4 (0015): a first-correct guess pulls rounds.ends_at and rooms.deadline back to '
  'now(), so the round ends the instant it is won -- under winner-takes-all every '
  'second after that is dead air. Progression stays client-driven; the existing '
  'now() >= deadline guard simply becomes true. v3 (0012): the race loser is told the '
  'truth; near and season-lenient matching require 5+ characters; the speed-bonus '
  'clamp ceiling is 1, not 100.';
