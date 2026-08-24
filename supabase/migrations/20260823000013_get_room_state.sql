-- 0013 -- get_room_state: the client's single read endpoint.
--
-- WHY POLLING ONE RPC RATHER THAN REALTIME
-- The design assumed Supabase Realtime would push ROUND_START / ROUND_REVEAL /
-- GAME_OVER to the room. Three things argue against it as the primary transport, and
-- the third is decisive:
--
--   1. emit_room_event publishes with realtime.send(..., false) -- a PUBLIC channel.
--      0012 moved the topic from room:<4-char-code> (about a million topics,
--      enumerable) to room:<uuid>, which makes eavesdropping impractical, but the
--      channel is still public by construction and the reveal payload contains the
--      answer.
--   2. It needs the Phoenix channel protocol, a socket dependency, and reconnection
--      handling -- none of which can be tested from this machine.
--   3. A push tells a client what happened. It does not tell a client what is TRUE.
--      After a refresh, a tab wake, or a dropped socket, the client still needs a
--      "what is the state right now" call, so that call has to exist regardless.
--      Once it exists, polling it is the whole client.
--
-- Everything answer-bearing therefore stays inside one SECURITY DEFINER function that
-- re-derives the truth on every call and gates the reveal on now() >= ends_at. There
-- is no path by which a client learns something before the server says it may.
--
-- COST, measured against the 5 GB monthly egress ceiling: the response is roughly
-- 800 bytes. At a 1.5 s interval, 8 players, a 10-round game (about 280 s) that is
-- 8 * 187 * 800 B ~= 1.2 MB per game, against 10-22 MB of media for the same game.
-- Polling is about 10% overhead, and 5 GB / 23 MB is still ~215 games per month.
-- Realtime remains available as a later optimisation; it is not needed to ship.
--
-- The broadcasts in start_game / advance_round are left in place. They cost nothing,
-- they are useful for a future latency improvement, and removing them would be a
-- change to code that is already applied and verified.
--
-- IDEMPOTENT: create-or-replace plus grants.

create or replace function public.get_room_state(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_me        uuid;
  v_code      text;
  v_state     text;
  v_host      uuid;
  v_cur       smallint;
  v_count     smallint;
  v_audio_on  boolean;
  v_deadline  timestamptz;

  v_rid       uuid;
  v_ord       smallint;
  v_starts    timestamptz;
  v_ends      timestamptz;
  v_keys      jsonb;
  v_assets    jsonb := null;
  v_answered  boolean := false;

  v_prev_rid  uuid;
  v_prev_ord  smallint;
  v_prev_rev  jsonb;
  v_prev_post text;
  v_reveal    jsonb := null;
  v_winner    jsonb := null;

  v_players   jsonb;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select r.code, r.state, r.host_player_id, r.current_round,
         r.round_count, r.audio_enabled, r.deadline
    into v_code, v_state, v_host, v_cur, v_count, v_audio_on, v_deadline
    from public.rooms r
   where r.id = p_room_id;

  if v_code is null then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  -- Re-checked here rather than trusted from the caller, exactly as get_current_round
  -- does: this function is SECURITY DEFINER and reads content tables the caller has
  -- no grant on.
  select p.id into v_me
    from public.players p
   where p.room_id = p_room_id
     and p.auth_uid = v_uid;

  if v_me is null then
    raise exception 'NOT_A_MEMBER' using errcode = '42501';
  end if;

  -- Scoreboard. Computed here because 0012's guesses policy deliberately hides other
  -- players' rows until their round has ended, so a client cannot sum points itself
  -- without either seeing the answers early or showing a stale board.
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id',      p.id,
               'name',    p.display_name,
               'score',   coalesce(s.pts, 0),
               'is_me',   p.id = v_me,
               'is_host', p.id = v_host
             )
             order by coalesce(s.pts, 0) desc, p.display_name
           ),
           '[]'::jsonb)
    into v_players
    from public.players p
    left join (
      select g.player_id, sum(g.points)::int as pts
        from public.guesses g
        join public.rounds rd on rd.id = g.round_id
       where rd.room_id = p_room_id
       group by g.player_id
    ) s on s.player_id = p.id
   where p.room_id = p_room_id;

  -- The round in play, if any.
  if v_state = 'playing' then
    select rd.id, rd.ordinal, rd.started_at, rd.ends_at,
           public.question_asset_keys(
             qb.asset_slug, qb.poster_slug, qb.audio_slug, qb.still_count)
      into v_rid, v_ord, v_starts, v_ends, v_keys
      from public.rounds rd
      join public.question_bank qb on qb.id = rd.question_id
     where rd.room_id = p_room_id
       and rd.ordinal = v_cur;

    if v_rid is not null then
      -- poster is stripped ALWAYS during play: it is harvested from the frames the
      -- OCR filter REJECTED for containing text, so it is the single most spoiling
      -- image of the sequence. audio is stripped when the host turned it off -- an
      -- egress control, not a security one, since the bucket is public by key.
      v_assets := jsonb_build_object('stills', v_keys -> 'stills');
      if v_audio_on then
        v_assets := v_assets || jsonb_build_object('audio', v_keys ->> 'audio');
      end if;

      select exists (
               select 1 from public.guesses g
                where g.round_id = v_rid
                  and g.player_id = v_me
                  and g.verdict = 'correct'
             )
        into v_answered;
    end if;
  end if;

  -- The most recently FINISHED round, which is what the reveal shows. Gated on
  -- now() >= ends_at, so this can never describe a round still being played.
  select rd.id, rd.ordinal, qb.reveal,
         public.question_asset_keys(
           qb.asset_slug, qb.poster_slug, qb.audio_slug, qb.still_count) ->> 'poster'
    into v_prev_rid, v_prev_ord, v_prev_rev, v_prev_post
    from public.rounds rd
    join public.question_bank qb on qb.id = rd.question_id
   where rd.room_id = p_room_id
     and rd.ends_at is not null
     and now() >= rd.ends_at
   order by rd.ordinal desc
   limit 1;

  if v_prev_rid is not null then
    select jsonb_build_object('name', p.display_name, 'points', g.points)
      into v_winner
      from public.guesses g
      join public.players p on p.id = g.player_id
     where g.round_id = v_prev_rid
       and g.is_first_correct;

    v_reveal := v_prev_rev
              || jsonb_build_object(
                   'ordinal', v_prev_ord,
                   'poster',  v_prev_post,
                   'winner',  v_winner);
  end if;

  return jsonb_build_object(
    -- server_now is what the client counts down from. A browser clock can be minutes
    -- off; every deadline here is server-side, so the client must measure its own
    -- offset rather than trusting Date.now().
    'server_now',     now(),
    'room_id',        p_room_id,
    'code',           v_code,
    'state',          v_state,
    'round_count',    v_count,
    'current_round',  v_cur,
    'audio_enabled',  v_audio_on,
    'my_player_id',   v_me,
    'is_host',        v_me = v_host,
    'deadline',       v_deadline,
    'players',        v_players,
    'round', case when v_rid is null then null else jsonb_build_object(
                    'round_id',   v_rid,
                    'ordinal',    v_ord,
                    'starts_at',  v_starts,
                    'ends_at',    v_ends,
                    'answered',   v_answered,
                    'assets',     v_assets) end,
    'reveal',         v_reveal
  );
end;
$$;

comment on function public.get_room_state(uuid) is
  'The client''s single read endpoint, polled. Returns room state, the scoreboard, the '
  'current round with its asset keys (poster always stripped, audio stripped when the '
  'host disabled it) and the reveal for the most recently FINISHED round, gated on '
  'now() >= ends_at. SECURITY DEFINER because it reads question_bank, which no client '
  'role may touch. Includes server_now so the client can correct its own clock. '
  'Errors: AUTH_REQUIRED, ROOM_NOT_FOUND, NOT_A_MEMBER.';

revoke all on function public.get_room_state(uuid) from public;
revoke all on function public.get_room_state(uuid) from anon;
grant execute on function public.get_room_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Addendum, from the Supabase security advisor (applied 2026-08-23)
-- ---------------------------------------------------------------------------
-- The advisor flagged is_room_member and is_own_player as SECURITY DEFINER functions
-- executable by `anon` via /rest/v1/rpc/<name>. Both are internal helpers used inside
-- RLS policy expressions; neither is part of the client API. Exploitability is nil
-- today -- both resolve identity from auth.uid(), NULL for role anon, so both return
-- false for every input -- but "returns false today" is exactly the reasoning 0012 was
-- written to stop relying on. The grant has no purpose, so it goes.
--
-- Deliberately NOT revoked from `authenticated`: a policy expression's function calls
-- are permission-checked against the querying role, so revoking there would break the
-- policies that call them.
--
-- Two other advisor findings are intentional and are NOT acted on:
--   * The game RPCs are SECURITY DEFINER and callable by `authenticated`. They ARE the
--     client API. Each re-checks membership itself rather than trusting the caller.
--   * question_bank and question_titles report "RLS enabled, no policies". That is the
--     strongest posture available, not an oversight: RLS on with zero policies plus
--     zero grants denies every client read outright (doc/DATA-MODEL.md 7.1).

revoke execute on function public.is_room_member(uuid) from anon;
revoke execute on function public.is_own_player(uuid)  from anon;
