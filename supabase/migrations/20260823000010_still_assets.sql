-- 20260823000010_still_assets.sql
--
-- Reshapes content storage from ONE video per question to FIVE still/audio objects,
-- and fixes two defects found while doing it. Background: doc/BLOCKERS.md B-20 (the
-- video spelled its own answer), B-25 (the replacement round format), B-27 (room
-- settings were validated and then discarded).
--
-- This migration is a ONE-SHOT reshape guarded on empty content tables. It drops
-- columns and adds NOT NULL columns without defaults, both of which are only safe
-- while question_bank has no rows. The guard below turns "ran this too late" from
-- silent data loss into a loud failure.
--
-- ---------------------------------------------------------------------------
-- WHY asset_slug EXISTS, AND WHY IT IS NOT THE ROW id
-- ---------------------------------------------------------------------------
-- The obvious design is to derive object keys from question_bank.id, exactly as the
-- old clip_key did ('clips/' || id || '.webm'). That is now a content leak.
--
-- rounds.question_id is readable by every room member: 20260822000006 grants select
-- on public.rounds and the policy rounds_select_for_members gates on room membership
-- ALONE -- there is no `ordinal <= current_round` predicate. create_room pre-selects
-- every round of the game up front. So any player can read the question_id of every
-- FUTURE round during round 1. If keys are a function of that id, then reading the
-- id is equivalent to holding the keys, and since the bucket is public-read, holding
-- the keys is equivalent to holding the content. A player with devtools could fetch
-- all ten rounds' artwork before round 1 ends.
--
-- The old rounds.clip_key made this worse by shipping the key itself onto a
-- client-readable row. That column is dropped here.
--
-- asset_slug is an independent random uuid living ONLY on question_bank, which no
-- client may read (20260822000006 enables RLS on it and adds no policy, and 7.1 of
-- doc/DATA-MODEL.md grants nothing). Keys are computed from the slug server-side.
-- A client therefore cannot derive any key it was not explicitly handed, and it is
-- only ever handed the current round's -- see get_current_round below.
--
-- Two uuids per row is deliberate, not an accident of the kind 20260822000008 warned
-- about. That warning was against deriving a key STRING that could disagree with the
-- row it names. Here id and asset_slug are not meant to agree: the whole point is
-- that one is public and the other is not.
--
-- ---------------------------------------------------------------------------
-- WHY THE ROUND PAYLOAD IS AN RPC AND NOT A BROADCAST
-- ---------------------------------------------------------------------------
-- Two rejected alternatives:
--   Keep clients reading rounds, add `ordinal <= current_round` to the policy.
--     Leaves a correctness-critical predicate that must stay right forever, and
--     couples every future rounds query to it.
--   Put the keys in the ROUND_START broadcast.
--     emit_room_event calls realtime.send(..., false) -- a PUBLIC channel, topic
--     'room:' || code. Room codes are four Crockford characters (~1M keyspace), so
--     a non-member who guesses or is told a code can subscribe and receive whatever
--     that broadcast carries. Broadcasts are a fine place for "something changed";
--     they are the wrong place for authorised content.
-- get_current_round is SECURITY DEFINER, re-checks membership, and returns exactly
-- one round's assets. ROUND_START stays a bare signal that tells the client to call it.

-- ---------------------------------------------------------------------------
-- Guard: this reshape is only safe on empty content tables.
-- ---------------------------------------------------------------------------

do $$
declare
  v_questions bigint;
  v_objects   bigint;
begin
  select count(*) into v_questions from public.question_bank;
  if v_questions > 0 then
    raise exception
      'REFUSING_TO_RESHAPE: question_bank holds % row(s). This migration drops '
      'clip_key and adds NOT NULL columns without defaults, which is only safe at '
      'zero rows. Truncate the content tables deliberately, or write a data '
      'migration instead.', v_questions;
  end if;

  select count(*) into v_objects from storage.objects where bucket_id in ('clips', 'media');
  if v_objects > 0 then
    raise exception
      'REFUSING_TO_RESHAPE: % object(s) already in the clips/media bucket. Renaming '
      'the bucket is free only while it is empty.', v_objects;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- question_bank: five objects per question instead of one.
-- ---------------------------------------------------------------------------

alter table public.question_bank
  add column asset_slug uuid not null default gen_random_uuid();

alter table public.question_bank
  add constraint question_bank_asset_slug_key unique (asset_slug);

-- 2 or 3, never 0 or 1. Frame selection rejects any frame containing text (the B-20
-- failure) and any frame too flat to be recognisable (doc/RESEARCH.md 4.10), so the
-- yield per sequence is variable. One usable frame is not a guessable round, so the
-- check makes that row unrepresentable rather than merely discouraged. The upper
-- bound is 3 because the client's progressive reveal has three slots (0s / 7s / 14s);
-- a fourth still would have no defined moment to appear.
alter table public.question_bank
  add column still_count smallint not null
    constraint still_count_playable check (still_count between 2 and 3);

-- clip_key is gone: it was a pure function of id ('clips/' || id || '.webm'), so its
-- UNIQUE index duplicated the primary key's guarantee at the cost of a second btree,
-- and the single video it named no longer exists.
alter table public.question_bank drop column clip_key;

-- These two described the one video. Renamed rather than dropped because both still
-- have exactly one referent under the new model.
alter table public.question_bank rename column duration_seconds to audio_seconds;
alter table public.question_bank rename column bytes            to bytes_total;

comment on column public.question_bank.asset_slug is
  'Random uuid, independent of id, used to build every object key for this question. '
  'Lives only on this table, which no client may read, so keys cannot be derived from '
  'anything a client can see (see this migration''s header).';

comment on column public.question_bank.still_count is
  'How many clean stills this question actually yielded: 2 or 3. Keys are '
  'stills/{asset_slug}-1.jpg .. -{still_count}.jpg.';

comment on column public.question_bank.audio_seconds is
  'Length of the audio object, which is cut to the room''s guessing window (~20 s). '
  'Was duration_seconds, when it described the video.';

comment on column public.question_bank.bytes_total is
  'Advisory sum of all objects for this question, for storage and egress forecasting '
  'against the 5 GB budget. Storage itself remains the source of truth per object.';

-- Corrects two falsehoods in the old table comment: it hardcoded the retired
-- clips/{uuid}.webm layout, and it justified credit_free_only by claiming a credited
-- video is what reveals the title. B-20 disproved that -- all ten sampled clips were
-- nc:true and five of them still burned the title into the picture. The constraint is
-- kept because credit-free sources have less on-screen text and therefore yield more
-- usable frames, which is a curation-yield argument, not a secrecy one.
comment on table public.question_bank is
  'Curation-pipeline output; no client grant exists (doc/DATA-MODEL.md 7.1). Each row '
  'owns five Storage objects -- one audio, two or three stills, one poster -- keyed '
  'from asset_slug, never from id, and never from the AnimeThemes basename, which '
  'spells the answer (doc/GAME-DESIGN.md 2.1). nc/subbed/nsfw are enforced by check '
  'constraint so a buggy ingest run cannot insert an unusable source: NOT because '
  'nc:true protects the answer (doc/BLOCKERS.md B-20 proved it does not) but because '
  'credit-free, unsubtitled sources carry less on-screen text and yield more clean '
  'frames. retired_at removes a question from rotation without deleting history.';

-- ---------------------------------------------------------------------------
-- rounds: stop shipping asset keys onto a client-readable row.
-- ---------------------------------------------------------------------------
-- The denormalisation existed so serving a round needed no join against a table
-- clients cannot read. That reason does not survive scrutiny: the round is served by
-- a SECURITY DEFINER function, which reads question_bank regardless of grants. What
-- the column actually bought was a content leak (see header).
--
-- question_id stays. It remains opaque to clients: question_bank and question_titles
-- both have RLS enabled with no policy and no grant, and keys now come from
-- asset_slug, so a future round's question_id discloses nothing.
alter table public.rounds drop column clip_key;

-- ---------------------------------------------------------------------------
-- rooms: the host's audio toggle.
-- ---------------------------------------------------------------------------
-- Both assets are produced for every question regardless, so this costs nothing in
-- curation; it is purely a serve-time egress lever (~120 KB/round/player frames-only
-- vs ~280 KB with audio). A boolean, not a mode enum, because the requirement is a
-- toggle and the flat-column style of this table is already established. If a third
-- mode ("audio only, no frames") ever arrives, that is a one-column migration made
-- with real requirements in hand rather than a guess now.
-- Default true: the richer game is the better default, and both modes fit the budget.
alter table public.rooms
  add column audio_enabled boolean not null default true;

comment on column public.rooms.audio_enabled is
  'Host choice at creation, fixed for the room''s life -- scores across rounds are only '
  'comparable if every round offered the same information. false = stills only.';

-- ---------------------------------------------------------------------------
-- question_asset_keys(uuid, smallint) -> jsonb
-- ---------------------------------------------------------------------------
-- The single place the object-key convention is written down. Because the round
-- payload is built server-side, this convention never has to be reimplemented in a
-- client, which is what makes deriving keys (rather than storing five columns) safe:
-- changing the layout is one function, not a coordinated client deploy.

create or replace function public.question_asset_keys(
  p_slug        uuid,
  p_still_count smallint
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'audio',  'audio/'   || p_slug::text || '.webm',
    'poster', 'posters/' || p_slug::text || '.jpg',
    'stills', (
      select jsonb_agg('stills/' || p_slug::text || '-' || g::text || '.jpg' order by g)
        from generate_series(1, p_still_count) as g
    )
  );
$$;

comment on function public.question_asset_keys(uuid, smallint) is
  'Object keys for one question, derived from its asset_slug. Sole definition of the '
  'Storage layout. Not granted to clients: they receive computed keys for the current '
  'round only, from get_current_round.';

revoke all on function public.question_asset_keys(uuid, smallint) from public;
revoke all on function public.question_asset_keys(uuid, smallint) from anon, authenticated;

-- ---------------------------------------------------------------------------
-- get_current_round(p_room_id uuid) -> jsonb
-- ---------------------------------------------------------------------------
-- Replaces "client selects from rounds" as the way assets reach a player. Returns the
-- CURRENT round only, after re-checking membership. Never returns the answer -- that
-- stays in question_bank.reveal and is broadcast at ROUND_REVEAL, exactly as before.

create or replace function public.get_current_round(p_room_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_state   text;
  v_ordinal int;
  v_audio   boolean;
  v_ends    timestamptz;
  v_slug    uuid;
  v_stills  smallint;
  v_assets  jsonb;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  -- Membership is re-checked here rather than trusted from RLS: this function is
  -- SECURITY DEFINER, so RLS on rooms does not apply to the reads below.
  if not public.is_room_member(p_room_id) then
    raise exception 'NOT_A_MEMBER' using errcode = '42501';
  end if;

  select r.state, r.current_round, r.audio_enabled
    into v_state, v_ordinal, v_audio
    from public.rooms r
   where r.id = p_room_id;

  if v_state is null then
    raise exception 'ROOM_NOT_FOUND';
  end if;

  -- Before start_game there is no current round. Not an error: the lobby polls this.
  if v_state <> 'playing' or v_ordinal < 1 then
    return jsonb_build_object('state', v_state, 'ordinal', null, 'assets', null);
  end if;

  select rd.ends_at, q.asset_slug, q.still_count
    into v_ends, v_slug, v_stills
    from public.rounds rd
    join public.question_bank q on q.id = rd.question_id
   where rd.room_id = p_room_id
     and rd.ordinal = v_ordinal;

  if v_slug is null then
    raise exception 'ROUND_NOT_FOUND';
  end if;

  v_assets := public.question_asset_keys(v_slug, v_stills);

  -- The poster is the reveal image and is deliberately the title-card frame, so it
  -- must not reach the client during guessing: it is the answer in picture form.
  v_assets := v_assets - 'poster';

  -- In a stills-only room the audio key is removed outright. The bucket is public, so
  -- this is not a security control -- it is an egress control. Handing over a key the
  -- client is asked not to fetch invites a bug or a curious user to spend exactly the
  -- bandwidth the toggle exists to save; removing it makes that spend impossible
  -- rather than merely discouraged.
  if not v_audio then
    v_assets := v_assets - 'audio';
  end if;

  return jsonb_build_object(
    'state',         v_state,
    'ordinal',       v_ordinal,
    'ends_at',       v_ends,
    'audio_enabled', v_audio,
    'assets',        v_assets
  );
end;
$$;

comment on function public.get_current_round(uuid) is
  'Assets for the caller''s CURRENT round only, after re-checking membership. Exists so '
  'no client-readable row ever carries an asset key: future rounds are unreachable by '
  'construction rather than by policy predicate. Omits the poster always (it is the '
  'answer in picture form) and the audio key in stills-only rooms. Errors: '
  'AUTH_REQUIRED, NOT_A_MEMBER, ROOM_NOT_FOUND, ROUND_NOT_FOUND.';

revoke all on function public.get_current_round(uuid) from public;
grant execute on function public.get_current_round(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- create_room: persist the settings it validates (B-27), and drop clip_key.
-- ---------------------------------------------------------------------------
-- The bug: round_count, difficulty_min and difficulty_max were parsed, range-checked,
-- and then never written -- the INSERT listed only `code`. No other statement in any
-- migration writes them either. difficulty_min/max were harmless-but-wrong (used in
-- the selection CTE below at creation time, never re-read afterwards). round_count was
-- actively broken: advance_round re-reads it to decide when the game ends, so it
-- always compared against the column default of 10. A 10-round room worked by
-- coincidence; 3-9 rounds served empty rounds up to 11; 11-20 ended early at 11.
--
-- Fixed by folding every setting into the one INSERT rather than a follow-up UPDATE,
-- so the row is never observable half-configured -- rooms is in the Realtime
-- publication and readable by members the moment it exists.
--
-- host_player_id stays a separate UPDATE: the player row needs the room id, so that
-- one is a genuine circular dependency and not the same class of bug.

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
  --
  -- clip_key is no longer copied here: asset keys must not land on a client-readable
  -- row. Clients call get_current_round instead.
  with picked as (
    select q.id,
           row_number() over (order by random()) as ord
      from public.question_bank q
     where q.difficulty between v_dmin and v_dmax
       and q.retired_at is null
     limit v_count
  )
  insert into public.rounds (room_id, ordinal, question_id)
  select v_room, p.ord, p.id
    from picked p;

  get diagnostics v_inserted = row_count;
  if v_inserted <> v_count then
    raise exception 'INSUFFICIENT_CONTENT (% of % available)',
      v_inserted, v_count;
  end if;

  -- Host identity (FLAGGED inference; see 20260822000005 header).
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
  'Validates round_count 3-20, difficulty range and the audio toggle, retries code '
  'collisions against the Crockford alphabet, pre-selects all rounds'' questions, '
  'creates the host player. Every validated setting is written in the same INSERT as '
  'the code (doc/BLOCKERS.md B-27: they were previously validated and discarded, which '
  'left advance_round comparing against the default round_count of 10). Errors: '
  'AUTH_REQUIRED, BAD_NAME, BAD_ROUND_COUNT, BAD_DIFFICULTY, CODE_EXHAUSTED, '
  'INSUFFICIENT_CONTENT.';

-- ---------------------------------------------------------------------------
-- ingest_question v2: five objects, caller-supplied asset_slug.
-- ---------------------------------------------------------------------------
-- The caller now supplies asset_slug rather than clip_uuid, for the same reason it
-- supplied clip_uuid before: it must know the object keys BEFORE it uploads, and it
-- uploads before inserting so a row can never point at bytes that never arrived.
-- Idempotence moves onto asset_slug, which is unique; the row's own id goes back to
-- the table default, because nothing outside this table needs to predict it.

create or replace function public.ingest_question(p_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_slug    uuid := nullif(p_payload ->> 'asset_slug', '')::uuid;  -- invalid text raises 22P02
  v_stills  smallint := (p_payload ->> 'still_count')::smallint;
  v_id      uuid;
  v_reveal  jsonb;
  v_title   text;
  v_kind    text;
  v_exists  uuid;
begin
  if v_slug is null then
    raise exception 'MISSING_ASSET_SLUG' using errcode = '22023';
  end if;

  -- Named error rather than a raw check violation, so a CI log says why a theme was
  -- skipped instead of quoting a constraint name. Mirrors NO_TITLES below: the
  -- constraint still_count_playable is the backstop, this is the diagnosis.
  if v_stills is null or v_stills not between 2 and 3 then
    raise exception 'INSUFFICIENT_STILLS (% clean frame(s) for slug %)',
      coalesce(v_stills, 0), v_slug using errcode = '22023';
  end if;

  -- Fast path for a retried batch: this question is already ingested.
  select id into v_exists from public.question_bank where asset_slug = v_slug;
  if found then
    return v_exists;
  end if;

  -- Reveal payload, broadcast only at ROUND_REVEAL (doc/ARCHITECTURE.md 9). Built here
  -- so every question reveals the same shape regardless of which pipeline run made it.
  v_reveal := jsonb_build_object(
    'titles', jsonb_build_object(
      'romaji',  p_payload -> 'titles' ->> 'romaji',
      'english', p_payload -> 'titles' ->> 'english',
      'native',  p_payload -> 'titles' ->> 'native'
    ),
    'year',           (p_payload ->> 'anime_year')::int,
    'season',         p_payload ->> 'anime_season',
    'format',         p_payload ->> 'anime_format',
    'theme',          (p_payload ->> 'theme_type') ||
                      coalesce((p_payload ->> 'theme_sequence'), ''),
    'anime_slug',     p_payload ->> 'anime_slug',
    -- Attribution back to AnimeThemes, which is the source of every asset.
    'source_url',     'https://animethemes.moe/anime/' || (p_payload ->> 'anime_slug')
  );

  insert into public.question_bank (
    asset_slug, still_count, audio_seconds, bytes_total,
    animethemes_video_id, animethemes_theme_id, anime_slug,
    anime_year, anime_season, anime_format,
    theme_type, theme_sequence, difficulty,
    nc, subbed, overlap, spoiler, nsfw,
    reveal
  ) values (
    v_slug,
    v_stills,
    (p_payload ->> 'audio_seconds')::int,
    (p_payload ->> 'bytes_total')::int,
    (p_payload ->> 'animethemes_video_id')::int,
    (p_payload ->> 'animethemes_theme_id')::int,
    p_payload ->> 'anime_slug',
    (p_payload ->> 'anime_year')::int,
    p_payload ->> 'anime_season',
    p_payload ->> 'anime_format',
    p_payload ->> 'theme_type',
    (p_payload ->> 'theme_sequence')::int,
    (p_payload ->> 'difficulty')::smallint,
    coalesce((p_payload ->> 'nc')::boolean, false),
    coalesce((p_payload ->> 'subbed')::boolean, true),
    p_payload ->> 'overlap',
    coalesce((p_payload ->> 'spoiler')::boolean, false),
    coalesce((p_payload ->> 'nsfw')::boolean, false),
    v_reveal
  )
  returning id into v_id;

  -- Every accepted answer string. normalise_title runs here, not in the pipeline.
  -- Two titles can normalise to the same value (e.g. an English title identical to a
  -- synonym), and (question_id, title_norm) is the primary key, so collisions are
  -- dropped rather than aborting the whole insert.
  for v_kind, v_title in
    select 'romaji',  p_payload -> 'titles' ->> 'romaji'  union all
    select 'english', p_payload -> 'titles' ->> 'english' union all
    select 'native',  p_payload -> 'titles' ->> 'native'  union all
    select 'synonym', s.value
      from jsonb_array_elements_text(coalesce(p_payload -> 'synonyms', '[]'::jsonb)) as s(value)
  loop
    continue when v_title is null or btrim(v_title) = '';
    insert into public.question_titles (question_id, kind, title, title_norm)
    values (v_id, v_kind, v_title, public.normalise_title(v_title))
    on conflict (question_id, title_norm) do nothing;
  end loop;

  -- A question with no answerable title is unwinnable; fail rather than ship it.
  if not exists (select 1 from public.question_titles where question_id = v_id) then
    raise exception 'NO_TITLES (slug %)', v_slug using errcode = '22023';
  end if;

  return v_id;
end;
$$;

comment on function public.ingest_question(jsonb) is
  'Curation-pipeline write path (doc/ARCHITECTURE.md 8). Inserts one question_bank row '
  'plus its question_titles, computing title_norm with normalise_title -- the same '
  'function grade_guess applies to a guess, so the two can never drift. Takes a '
  'caller-generated asset_slug, which is also the object-key root, so the caller can '
  'upload all five objects before inserting and a row can never point at bytes that '
  'never arrived. Idempotent on asset_slug: a retried batch re-returns the same id. '
  'Raises INSUFFICIENT_STILLS or NO_TITLES rather than shipping an unplayable '
  'question. service_role only -- no client may reach the bank.';

-- ---------------------------------------------------------------------------
-- Storage: the bucket is no longer a bucket of clips.
-- ---------------------------------------------------------------------------
-- Renamed clips -> media while it is empty, which is the only moment this is free:
-- at 136 questions it would be a ~680-object copy, and the name appears in every
-- asset URL the game ever serves.
--
-- Both limits TIGHTEN rather than widen, which is the opposite of what adding asset
-- kinds suggests:
--   allowed_mime_types  video/webm is REMOVED, not supplemented -- no video is stored
--                       anywhere under B-25, so continuing to allow it would leave the
--                       exact upload the design forbids possible.
--   file_size_limit     5 MB -> 512 KB. The largest object is now ~160 KB of Opus.
--                       The old ceiling existed to catch a transcode that passed the
--                       ~40 MB source through; at 512 KB that failure is caught an
--                       order of magnitude earlier, and it directly protects the 5 GB
--                       egress budget from a runaway encode.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 524288, array['audio/webm', 'image/jpeg'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Public READ only. storage.objects has RLS enabled and this migration adds no
-- INSERT/UPDATE/DELETE policy, so anon and authenticated cannot write. The pipeline
-- uploads with the service_role key, which bypasses RLS. Public-read keeps two
-- properties signed URLs would cost: no extra round trip per asset, and CDN caching,
-- so repeat plays land in the separate cached-egress allowance rather than the
-- metered one (doc/ARCHITECTURE.md A10).
drop policy if exists "clips are publicly readable" on storage.objects;
drop policy if exists "media is publicly readable"  on storage.objects;
create policy "media is publicly readable"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'media');

-- The now-unused `clips` bucket is deliberately NOT dropped here. Supabase installs a
-- trigger, storage.protect_delete(), which rejects any direct DELETE against
-- storage.buckets with 42501 "Direct deletion from storage tables is not allowed. Use
-- the Storage API instead." An earlier draft of this migration ended with such a
-- DELETE; because a multi-statement query runs as one transaction, that single
-- statement rolled the entire reshape back. Recorded here so the next person does not
-- rediscover it.
--
-- INSERT into storage.buckets is fine (20260822000009 does it, and so does this
-- migration above) -- only deletion is protected. Removing the empty bucket is
-- therefore an out-of-band DELETE /storage/v1/bucket/clips call, not schema. An empty
-- bucket costs nothing, so this is tidiness, not correctness.
