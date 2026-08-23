-- ---------------------------------------------------------------------------
-- 0011: one object-key root per asset class, not one per question.
-- ---------------------------------------------------------------------------
-- THE DEFECT THIS FIXES
--
-- Migration 0010 gave each question a single random asset_slug and built all five
-- object keys from it:
--
--     audio/{slug}.webm      posters/{slug}.jpg      stills/{slug}-{n}.jpg
--
-- Its column comment justified this as safe because asset_slug "lives only on this
-- table, which no client may read, so keys cannot be derived from anything a client
-- can see". That reasoning asks whether a client can read the slug out of a row. It
-- misses that the client is HANDED keys built from that slug: get_current_round must
-- return the still keys or the player cannot see the stills. Given
-- stills/<slug>-1.jpg, the poster key is a one-line string edit.
--
-- The poster is, by deliberate design (doc/GAME-DESIGN.md 5.2.4), the title-card
-- frame -- the answer in picture form. So any player could read the answer mid-round,
-- and get_current_round's `v_assets - 'poster'` was protecting a secret that was not
-- secret. The same edit exposed audio/{slug}.webm, making the host's stills-only
-- choice unenforceable rather than merely discouraged.
--
-- MEASURED, not assumed. Against the live project, media bucket, service-key upload
-- of one probe object, then requests with the project's anon key:
--
--   with policy "media is publicly readable" present:
--     list prefix ''         -> 1 entry  ("stills")
--     list prefix 'stills/'  -> 1 entry  ("_selftest-1.jpg")
--     GET object by key      -> 200
--   with that policy dropped:
--     list prefix ''         -> 0 entries
--     list prefix 'stills/'  -> 0 entries
--     GET object by key      -> 200   (both /object/public/... and with the anon key)
--
-- Two consequences drive this migration:
--
--  1. On a bucket with public = true, reads BY KEY bypass RLS entirely. No policy can
--     time-limit or member-limit an object. Key unguessability is therefore the only
--     protection available, which is exactly why the three key roots must be
--     independent rather than one root shared by all five objects.
--
--  2. That SELECT policy never granted the downloads 0010 wanted (those work without
--     it, and keep their CDN caching); the only capability it added was ENUMERATION.
--     Anonymously listing stills/ and posters/ revealed the shared slug and yielded a
--     complete offline answer key for the whole bank, without joining a room. It is
--     dropped below.
--
-- WHAT THIS MIGRATION DOES NOT CHANGE
--
-- The bucket stays public and unsigned, preserving the two properties 0010 chose it
-- for (no extra round trip per asset, CDN-cached repeat plays landing outside the
-- metered egress allowance -- doc/ARCHITECTURE.md A10). Independent 122-bit roots make
-- a key unguessable; they do not make it revocable. A player who saves a still URL
-- keeps it. That is acceptable for stills, which that player was shown anyway; it is
-- the reason the poster now gets a root of its own.

-- ---------------------------------------------------------------------------
-- question_bank: a separate key root for the poster and for the audio.
-- ---------------------------------------------------------------------------
-- Both are NOT NULL with a random default, so existing rows (there are none yet) and
-- any future caller that forgets them still get unguessable keys rather than NULLs
-- silently collapsing into a shared prefix.
--
-- Every statement below is written to be re-appliable: this project applies migrations
-- through the Management API by hand, with no ledger table recording what already ran,
-- so a file that fails halfway through on a second attempt is a trap.

alter table public.question_bank
  add column if not exists poster_slug uuid not null default gen_random_uuid();

alter table public.question_bank
  add column if not exists audio_slug uuid not null default gen_random_uuid();

-- Postgres has no "add constraint if not exists", so drop-then-add is the idempotent
-- spelling.
alter table public.question_bank
  drop constraint if exists question_bank_poster_slug_key;
alter table public.question_bank
  add constraint question_bank_poster_slug_key unique (poster_slug);

alter table public.question_bank
  drop constraint if exists question_bank_audio_slug_key;
alter table public.question_bank
  add constraint question_bank_audio_slug_key unique (audio_slug);

-- The failure mode worth making unrepresentable is not a collision between two
-- questions -- the UNIQUE indexes cover that -- but a pipeline that generates one uuid
-- and sends it as all three, quietly restoring the derivable-key hole this migration
-- exists to close. A row like that cannot be stored.
alter table public.question_bank
  drop constraint if exists question_bank_slugs_distinct;
alter table public.question_bank
  add constraint question_bank_slugs_distinct check (
        asset_slug  <> poster_slug
    and asset_slug  <> audio_slug
    and poster_slug <> audio_slug
  );

comment on column public.question_bank.asset_slug is
  'Random uuid, independent of id and of the other two slugs, used to build the STILL '
  'object keys only: stills/{asset_slug}-1.jpg .. -{still_count}.jpg. Still keys are '
  'the one set a guessing client legitimately receives, so nothing else may be '
  'derivable from them (see this migration''s header).';

comment on column public.question_bank.poster_slug is
  'Independent random uuid for posters/{poster_slug}.jpg. Separate from asset_slug '
  'because the poster is the title-card frame -- the answer as an image -- and a '
  'player holding the still keys must not be able to compute it. Reaches a client only '
  'at ROUND_REVEAL.';

comment on column public.question_bank.audio_slug is
  'Independent random uuid for audio/{audio_slug}.webm. Separate from asset_slug so a '
  'stills-only room is actually stills-only: with a shared root, a client could derive '
  'and fetch the audio the room said it would not serve.';

-- ---------------------------------------------------------------------------
-- question_asset_keys: three roots in, five keys out.
-- ---------------------------------------------------------------------------
-- The 2-argument version is DROPPED rather than left beside this one. Leaving it
-- callable would leave the hole one convenient overload away, and PostgreSQL would
-- happily resolve question_asset_keys(slug, count) forever.

drop function if exists public.question_asset_keys(uuid, smallint);

create or replace function public.question_asset_keys(
  p_still_slug  uuid,
  p_poster_slug uuid,
  p_audio_slug  uuid,
  p_still_count smallint
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'audio',  'audio/'   || p_audio_slug::text  || '.webm',
    'poster', 'posters/' || p_poster_slug::text || '.jpg',
    'stills', (
      select jsonb_agg('stills/' || p_still_slug::text || '-' || g::text || '.jpg' order by g)
        from generate_series(1, p_still_count) as g
    )
  );
$$;

comment on function public.question_asset_keys(uuid, uuid, uuid, smallint) is
  'Object keys for one question, each class built from its own independent slug. Sole '
  'definition of the Storage layout, so changing it is one function rather than a '
  'coordinated client deploy. Not granted to clients: they receive computed keys for '
  'the current round only, from get_current_round.';

revoke all on function public.question_asset_keys(uuid, uuid, uuid, smallint) from public;
revoke all on function public.question_asset_keys(uuid, uuid, uuid, smallint) from anon, authenticated;

-- ---------------------------------------------------------------------------
-- get_current_round: unchanged contract, corrected key source.
-- ---------------------------------------------------------------------------
-- Body is identical to 0010 except that it reads all three slugs and passes them on.
-- Replaced wholesale rather than patched because the function is the security boundary
-- and it should be readable in one piece.

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
  v_poster  uuid;
  v_aslug   uuid;
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

  select rd.ends_at, q.asset_slug, q.poster_slug, q.audio_slug, q.still_count
    into v_ends, v_slug, v_poster, v_aslug, v_stills
    from public.rounds rd
    join public.question_bank q on q.id = rd.question_id
   where rd.room_id = p_room_id
     and rd.ordinal = v_ordinal;

  if v_slug is null then
    raise exception 'ROUND_NOT_FOUND';
  end if;

  v_assets := public.question_asset_keys(v_slug, v_poster, v_aslug, v_stills);

  -- The poster is the reveal image and is deliberately the title-card frame, so it must
  -- not reach the client during guessing: it is the answer in picture form. Since 0011
  -- the poster key is built from its own slug, so withholding it here actually withholds
  -- it -- under the shared-slug layout this line removed a key the client could
  -- reconstruct from the still keys it was just given.
  v_assets := v_assets - 'poster';

  -- In a stills-only room the audio key is removed outright. This is an egress control
  -- first -- handing over a key the client is asked not to fetch invites a bug or a
  -- curious user to spend exactly the bandwidth the toggle exists to save -- and, since
  -- 0011 gave audio its own slug, it is now also effective rather than advisory.
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
  'answer in picture form) and the audio key in stills-only rooms; since 0011 each of '
  'those is built from its own slug, so omission cannot be undone by string-editing a '
  'still key. Errors: AUTH_REQUIRED, NOT_A_MEMBER, ROOM_NOT_FOUND, ROUND_NOT_FOUND.';

revoke all on function public.get_current_round(uuid) from public;

-- 0010 wrote `revoke ... from public` and granted `authenticated`, intending
-- authenticated-only. Measured after applying this migration, the server still reported
-- anon=X/postgres: 0006 had granted EXECUTE to anon explicitly, and revoking from the
-- PUBLIC pseudo-role does not remove a grant made to a named role, nor does CREATE OR
-- REPLACE reset an ACL. The function's own AUTH_REQUIRED check was the only thing
-- containing that grant -- correct, but it made a documented restriction depend on the
-- body rather than on the privilege. Named explicitly here so the intent holds.
revoke all on function public.get_current_round(uuid) from anon;

grant execute on function public.get_current_round(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- ingest_question v3: the caller supplies all three slugs.
-- ---------------------------------------------------------------------------
-- Same reason v2 took asset_slug: the pipeline must know every object key BEFORE it
-- uploads, and it uploads before inserting so a row can never point at bytes that
-- never arrived. Three roots means three caller-supplied uuids. They are REQUIRED, not
-- defaulted, because a server-side default would name keys the pipeline never wrote.
-- Idempotence stays on asset_slug.

create or replace function public.ingest_question(p_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_slug    uuid := nullif(p_payload ->> 'asset_slug', '')::uuid;   -- invalid text raises 22P02
  v_poster  uuid := nullif(p_payload ->> 'poster_slug', '')::uuid;
  v_aslug   uuid := nullif(p_payload ->> 'audio_slug', '')::uuid;
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

  -- Named separately from MISSING_ASSET_SLUG so a CI log identifies which root the
  -- pipeline failed to send, rather than reporting a generic bad payload.
  if v_poster is null then
    raise exception 'MISSING_POSTER_SLUG (asset_slug %)', v_slug using errcode = '22023';
  end if;

  if v_aslug is null then
    raise exception 'MISSING_AUDIO_SLUG (asset_slug %)', v_slug using errcode = '22023';
  end if;

  -- The diagnosis for the bug this migration exists to prevent: a caller that reuses
  -- one uuid across classes. question_bank_slugs_distinct is the backstop; this is the
  -- message that says what went wrong.
  if v_slug = v_poster or v_slug = v_aslug or v_poster = v_aslug then
    raise exception
      'SLUGS_NOT_DISTINCT (asset %, poster %, audio % -- each asset class needs its own root)',
      v_slug, v_poster, v_aslug using errcode = '22023';
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
    asset_slug, poster_slug, audio_slug,
    still_count, audio_seconds, bytes_total,
    animethemes_video_id, animethemes_theme_id, anime_slug,
    anime_year, anime_season, anime_format,
    theme_type, theme_sequence, difficulty,
    nc, subbed, overlap, spoiler, nsfw,
    reveal
  ) values (
    v_slug,
    v_poster,
    v_aslug,
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
  'function grade_guess applies to a guess, so the two can never drift. Takes three '
  'caller-generated slugs (asset_slug for stills, poster_slug, audio_slug), which are '
  'the object-key roots, so the caller can upload all five objects before inserting and '
  'a row can never point at bytes that never arrived. They must be distinct: a shared '
  'root would let a player derive the poster from a still key. Idempotent on '
  'asset_slug: a retried batch re-returns the same id. Raises MISSING_ASSET_SLUG, '
  'MISSING_POSTER_SLUG, MISSING_AUDIO_SLUG, SLUGS_NOT_DISTINCT, INSUFFICIENT_STILLS or '
  'NO_TITLES rather than shipping an unplayable or self-spoiling question. '
  'service_role only -- no client may reach the bank.';

-- ---------------------------------------------------------------------------
-- Storage: stop advertising the catalogue.
-- ---------------------------------------------------------------------------
-- Measured above: this policy was not what made objects downloadable. A public bucket
-- serves reads by key without consulting RLS, so /object/public/... and anon GETs both
-- still return 200 with the policy gone, and CDN caching is untouched. What the policy
-- did grant was storage.objects SELECT, i.e. LIST -- letting an anonymous visitor walk
-- stills/ and posters/ and read every key in the bank. Under the old shared-slug layout
-- that was a complete answer key; under 0011 it still discloses the entire content
-- catalogue and invites bulk fetching against a 5 GB monthly egress budget.
--
-- No read policy replaces it: nothing a legitimate player does needs to list a bucket.
-- Writes were never possible for anon or authenticated (0010 added no INSERT/UPDATE/
-- DELETE policy); the pipeline keeps uploading with the service_role key, which
-- bypasses RLS.

drop policy if exists "media is publicly readable" on storage.objects;
