-- 20260822000008_ingest_question.sql
--
-- Curation-pipeline write path. One RPC, called by .github/workflows/curate.yml with
-- the service_role key, that inserts a question_bank row plus its question_titles.
--
-- WHY AN RPC INSTEAD OF A DIRECT POSTGREST INSERT
-- question_titles.title_norm must be produced by public.normalise_title -- the exact
-- function grade_guess applies to the player's guess (doc/DATA-MODEL.md 3, and the
-- comment on question_titles). If the pipeline computed title_norm itself in
-- PowerShell or bash, the two normalisers could drift apart and answers would stop
-- matching for reasons invisible in both codebases. Normalising inside the database
-- makes divergence structurally impossible.
--
-- ONE UUID, NOT TWO
-- doc/DATA-MODEL.md 8.3 keys objects `clips/{question_bank.id}.webm` -- the row's OWN
-- id. So the caller passes a bare clip_uuid and this function derives both id and
-- clip_key from it. Letting the caller pass clip_key instead would mean two independent
-- uuids that must agree forever, and the day they disagree a round resolves to a
-- missing object mid-game. Deriving the key server-side also makes a leaky key
-- structurally impossible rather than merely rejected.
--
-- It also fixes the ordering: because the pipeline chooses the uuid, it can upload the
-- object FIRST and insert only after the upload succeeds. The reverse order -- insert,
-- then upload -- can leave a live row pointing at bytes that never arrived.
--
-- IDEMPOTENCE
-- clip_key is unique. A re-run of the same batch returns the existing id and inserts
-- nothing, so the workflow can be safely retried after a partial failure -- which
-- matters because it processes ~130 clips in batches and any one can fail mid-flight.
--
-- SAFETY
-- The nc / subbed / nsfw check constraints on question_bank (migration 0003) still
-- apply: this function cannot be used to smuggle an unsafe clip past them. It passes
-- the flags through rather than hardcoding them, so a buggy manifest fails loudly on
-- the constraint instead of silently inserting a credited video.
--
-- Depends on: 0002 (normalise_title), 0003 (question_bank, question_titles).

-- ---------------------------------------------------------------------------
-- ingest_question -- insert one curated clip and every string that answers it.
-- ---------------------------------------------------------------------------
create or replace function public.ingest_question(p_payload jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id       uuid := nullif(p_payload ->> 'clip_uuid', '')::uuid;  -- invalid text raises 22P02
  v_clip_key text;
  v_reveal   jsonb;
  v_title    text;
  v_kind     text;
  v_exists   uuid;
begin
  if v_id is null then
    raise exception 'MISSING_CLIP_UUID' using errcode = '22023';
  end if;

  -- doc/DATA-MODEL.md 8.3: objects are keyed by the row's own id. Built here, never
  -- supplied, so the AnimeThemes basename (ShingekiNoKyojin-OP1.webm -- it spells the
  -- answer, and clip_key reaches the client every round) can never become the key.
  v_clip_key := 'clips/' || v_id::text || '.webm';

  -- Fast path for a retried batch: the clip is already ingested.
  select id into v_exists from public.question_bank where id = v_id;
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
    -- Attribution back to AnimeThemes, which is the source of every clip.
    'source_url',     'https://animethemes.moe/anime/' || (p_payload ->> 'anime_slug')
  );

  insert into public.question_bank (
    id, clip_key, duration_seconds, bytes,
    animethemes_video_id, animethemes_theme_id, anime_slug,
    anime_year, anime_season, anime_format,
    theme_type, theme_sequence, difficulty,
    nc, subbed, overlap, spoiler, nsfw,
    reveal
  ) values (
    v_id,
    v_clip_key,
    (p_payload ->> 'duration_seconds')::int,
    (p_payload ->> 'bytes')::int,
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
    raise exception 'NO_TITLES (%)', v_clip_key using errcode = '22023';
  end if;

  return v_id;
end;
$$;

comment on function public.ingest_question(jsonb) is
  'Curation-pipeline write path (doc/ARCHITECTURE.md 8). Inserts one question_bank row '
  'plus its question_titles, computing title_norm with normalise_title -- the same '
  'function grade_guess applies to a guess, so the two can never drift. Takes a bare '
  'clip_uuid and derives both id and clip_key (clips/{id}.webm, doc/DATA-MODEL.md 8.3) '
  'so the object path and the row can never disagree, and so the caller can upload '
  'before inserting. Idempotent on the uuid: a retried batch re-returns the same id. '
  'Raises NO_TITLES rather than shipping an unwinnable question. service_role only -- '
  'no client may reach the bank.';

-- Clients must never reach the bank (doc/DATA-MODEL.md 7.1). SECURITY DEFINER makes
-- the grant the only thing standing between anon and the answer set, so it is
-- explicitly revoked rather than left at the default.
revoke all on function public.ingest_question(jsonb) from public;
revoke all on function public.ingest_question(jsonb) from anon, authenticated;
grant execute on function public.ingest_question(jsonb) to service_role;
