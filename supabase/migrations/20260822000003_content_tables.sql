-- 20260822000003_content_tables.sql
-- ReIN Bot -- content tables. Implements doc/DATA-MODEL.md 3.1 and 3.2.
--
-- These are written by the curation pipeline (doc/ARCHITECTURE.md 8) and never read
-- directly by clients. Migration 20260822000006 revokes every grant on them; until
-- that migration runs, nothing else in this project touches these tables, so there is
-- no window in which a client could reach an answer through them.
--
-- Depends on 20260822000002 (normalise_title): question_titles.title_norm values are
-- produced by it at ingest. The grader applies the same function to guesses, so both
-- sides of every comparison pass through identical normalisation.

-- ---------------------------------------------------------------------------
-- question_bank -- one row per usable clip.
-- ---------------------------------------------------------------------------

create table public.question_bank (
  id                  uuid primary key default gen_random_uuid(),
  clip_key            text        not null unique,
  duration_seconds    int         not null,
  bytes               int         not null,

  -- provenance (AnimeThemes)
  animethemes_video_id  int,
  animethemes_theme_id  int,
  anime_slug            text      not null,

  -- difficulty inputs (doc/DATA-MODEL.md 5; formula deliberately unspecified)
  anime_year          int         not null,
  anime_season        text,
  anime_format        text        not null,
  theme_type          text        not null check (theme_type in ('OP','ED')),
  theme_sequence      int,
  difficulty          smallint    not null check (difficulty between 1 and 5),

  -- variant safety flags (doc/ARCHITECTURE.md 8.1)
  nc                  boolean     not null,
  subbed              boolean     not null,
  overlap             text,       -- recorded, not constrained: doc/RESEARCH.md 4.8 prefers NONE
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

comment on table public.question_bank is
  'Curation-pipeline output; no client grant exists (doc/DATA-MODEL.md 7.1). clip_key is '
  'an opaque identifier -- clips/{uuid}.webm -- never the AnimeThemes basename, which '
  'spells the answer (doc/GAME-DESIGN.md 2.1). The three check constraints encode the '
  'variant-selection rules so a unsafe clip cannot be inserted even by a buggy ingest '
  'run: a credited video reveals the title logo and subtitles can carry translated '
  'titles. retired_at removes a clip from rotation without deleting history.';

-- ---------------------------------------------------------------------------
-- question_titles -- every string that counts as a correct answer, one row each.
-- ---------------------------------------------------------------------------

create table public.question_titles (
  question_id  uuid not null references public.question_bank(id) on delete cascade,
  kind         text not null check (kind in ('romaji','english','native','synonym')),
  title        text not null,
  title_norm   text not null,
  primary key (question_id, title_norm)
);

create index question_titles_by_question on public.question_titles (question_id);

-- Empty-string guard. doc/GAME-DESIGN.md 4.2 documents a bug where a CJK title normalises
-- to '' and then matches any single character. normalise_title itself was fixed to use
-- [^[:alnum:]] (migration 20260822000002), but this constraint makes the failure
-- impossible at the storage layer too: a '' candidate cannot be inserted at all.
alter table public.question_titles add constraint title_norm_not_empty
  check (length(title_norm) > 0);

comment on table public.question_titles is
  'Correct-answer strings per question. title_norm is written at ingest by '
  'normalise_title() -- the same function grade_guess applies to the guess. Both sides '
  'must always pass through identical normalisation or the comparison is meaningless. '
  'Deliberately no trigram index: grading fetches the 4-8 rows for one question and '
  'compares in memory; a global index would serve no query we make.';
