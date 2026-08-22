-- 20260822000002_normalise_title.sql
-- ReIN Bot -- title normalisation. Implements doc/GAME-DESIGN.md 4.2.
--
-- This migration MUST run before any table that references normalise_title, which is
-- why it precedes the content tables rather than sitting with the other functions.

-- ---------------------------------------------------------------------------
-- immutable_unaccent -- required wrapper, not a stylistic choice.
-- ---------------------------------------------------------------------------
-- Both unaccent(text) and unaccent(regdictionary, text) are declared STABLE, not
-- IMMUTABLE, because the single-argument form resolves the default text-search
-- dictionary at call time and that resolution can change. An IMMUTABLE function may
-- not call a STABLE one, so normalise_title cannot honestly be IMMUTABLE while calling
-- unaccent() directly.
--
-- Pinning the dictionary explicitly via the two-argument form makes the call
-- deterministic, so wrapping it and declaring IMMUTABLE is legitimate. This is the
-- idiom the PostgreSQL documentation itself recommends for indexing unaccented text.
--
-- IMMUTABLE matters here even though doc/DATA-MODEL.md 3.2 stores title_norm as a plain
-- column written at ingest rather than a generated column: it keeps the door open to
-- expression indexes later, and it is simply true.

create or replace function public.immutable_unaccent(p_text text)
returns text
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select extensions.unaccent('extensions.unaccent'::regdictionary, p_text)
$$;

comment on function public.immutable_unaccent(text) is
  'IMMUTABLE wrapper over unaccent with an explicitly pinned dictionary. Required '
  'because unaccent() itself is only STABLE. See migration 20260822000002.';

-- ---------------------------------------------------------------------------
-- normalise_title -- the six steps of doc/GAME-DESIGN.md 4.2, in order.
-- ---------------------------------------------------------------------------
-- The ORDER IS LOAD-BEARING. Two documented bugs live in this function and both are
-- ordering or character-class mistakes, not logic mistakes.

create or replace function public.normalise_title(p_title text)
returns text
language plpgsql
immutable
strict
parallel safe
set search_path = ''
as $$
declare
  v text;
begin
  -- Step 1: NFKC compatibility normalisation, then lowercase.
  -- NFKC folds fullwidth forms, so fullwidth 'ABC' collapses onto ASCII 'abc'.
  -- Verified on PG 17.6: normalize(U&'\FF21\FF22\FF23', NFKC) = 'ABC', length 3.
  v := lower(normalize(p_title, NFKC));

  -- Step 2: strip diacritics. This also covers the macron case from 4.2 step 3
  -- (o-macron -> o), so step 3 below only has to handle the ASCII digraphs.
  v := public.immutable_unaccent(v);

  -- Step 3: collapse long-vowel romanisations.
  -- Deliberately lossy: 'youth' becomes 'yoth'. That is acceptable because the exact
  -- same transform is applied to both the submitted guess and the stored title, so
  -- what matters is consistency, not linguistic correctness.
  v := replace(v, 'ou', 'o');
  v := replace(v, 'uu', 'u');
  v := replace(v, 'oo', 'o');

  -- Step 4: strip a leading article. This MUST run while spaces still exist.
  -- Running it after step 5 is doc/GAME-DESIGN.md 4.2 Bug 1: on 'Attack on Titan' the
  -- space-free string 'attackontitan' begins with 'a', so an article strip at that
  -- point yields 'ttackontitan' and the title can never be matched again.
  v := regexp_replace(v, '^(the|a|an)[[:space:]]+', '');

  -- Step 5: drop everything that is not a letter or a digit, spaces included.
  -- The class is deliberately [^[:alnum:]]:
  --   * NOT [^a-z0-9] -- that is doc/GAME-DESIGN.md 4.2 Bug 2. An ASCII-only class deletes
  --     every character of a native Japanese title, producing '', and an empty
  --     candidate matches any single-character submission under the near-match tier,
  --     so typing 'a' would score every round.
  --   * NOT [^\p{L}\p{N}] -- PostgreSQL's regex engine does not implement Perl
  --     property escapes at all. Verified: regexp_replace('abc!','[^\p{L}]','','g')
  --     raises ERROR 2201B invalid regular expression: invalid escape \ sequence.
  --     The function would not have been creatable as originally specified.
  --   * NOT a [[:punct:][:space:]] blacklist -- that leaves symbol-category
  --     characters behind, e.g. a white star U+2606 is category So, not punctuation.
  -- [[:alnum:]] was verified genuinely Unicode-aware on this project (PG 17.6,
  -- ctype en_US.UTF-8): a 4-character kana/kanji title keeps all 4 characters and a
  -- 5-character one keeps all 5, while ideographic full stop U+3002 and katakana
  -- middle dot U+30FB are correctly removed.
  v := regexp_replace(v, '[^[:alnum:]]', '', 'g');

  return v;
end;
$$;

comment on function public.normalise_title(text) is
  'Implements doc/GAME-DESIGN.md 4.2 steps 1-5. Step order is load-bearing: the article '
  'strip must precede punctuation removal. Never change [[:alnum:]] to an ASCII class.';

-- ---------------------------------------------------------------------------
-- strip_season_markers -- doc/GAME-DESIGN.md 4.2 step 6, kept separate on purpose.
-- ---------------------------------------------------------------------------
-- Step 6 is NOT part of normalise_title. The season-lenient tier is defined in 4.3 as
-- strip(guess) = strip(title) AND the two are not already equal, so the grader needs
-- both the stripped and unstripped forms of the same string. Folding step 6 into
-- normalise_title would destroy the information the tier is built on.
--
-- Input is an ALREADY-NORMALISED string, so spaces are gone by this point: 'season 2'
-- arrives as 'season2', '2nd season' as '2ndseason', 'part 2' as 'part2'.
--
-- Alternatives are ordered longest-first so the longer marker wins the match.
--
-- The length guard is a deliberate safety addition beyond the written spec. Stripping
-- trailing roman numerals is wanted for titles like 'Overlord II', but a naive
-- i{1,3}$ also eats the tail of any short title ending in i, and bare 'i' is excluded
-- entirely for that reason. Even so, an over-eager strip could reduce a title to a
-- stub short enough for the near-match tier to match nearly anything -- exactly the
-- failure mode of Bug 2. If the strip would leave fewer than 3 characters, it is
-- abandoned and the input is returned unchanged. FLAGGED: this threshold is my
-- judgement call, not a user decision, and it is cheap to revisit.

create or replace function public.strip_season_markers(p_norm text)
returns text
language plpgsql
immutable
strict
parallel safe
set search_path = ''
as $$
declare
  v text;
begin
  v := regexp_replace(
         p_norm,
         '(season[0-9]{1,2}'
         '|[0-9]{1,2}(st|nd|rd|th)season'
         '|part[0-9]{1,2}'
         '|s[0-9]{1,2}'
         '|iii|iv|ii'
         '|[0-9]{1,2})$',
         ''
       );

  if length(v) < 3 then
    return p_norm;
  end if;

  return v;
end;
$$;

comment on function public.strip_season_markers(text) is
  'doc/GAME-DESIGN.md 4.2 step 6. Deliberately NOT folded into normalise_title: the '
  'season-lenient tier needs both the stripped and unstripped forms.';
