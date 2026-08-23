-- Delete objects in the `media` bucket that no question_bank row points at.
--
-- WHY ORPHANS HAPPEN, AND WHY THIS IS NOT A BUG TO FIX ELSEWHERE
-- curate_theme.py uploads all five objects for a question and THEN calls
-- ingest_question, deliberately in that order: a row pointing at bytes that never
-- arrived is worse than bytes no row points at. So any failure between the first
-- upload and a successful ingest leaves 1-5 objects behind. On retry the script mints
-- three fresh uuids -- it must, because the slugs are the only thing protecting a
-- public-read object -- so the previous upload can never be adopted, only swept.
--
-- The keys are built by question_asset_keys(), which is the single definition of the
-- storage layout, so this query cannot drift from it:
--     audio/{audio_slug}.webm
--     stills/{asset_slug}-{n}.jpg   n = 1 .. still_count
--     posters/{poster_slug}.jpg
--
-- THIS REPORTS, IT DOES NOT DELETE, and that is not a design choice.
-- storage.protect_delete() rejects a direct DELETE from storage.objects with
-- `42501: Direct deletion from storage tables is not allowed. Use the Storage API
-- instead.` -- measured, after trying it. doc/HANDOFF.md section 5 documented that
-- trigger as covering storage.buckets only; it covers storage.objects as well.
-- Actually removing an object therefore needs a Storage API call authenticated with
-- the service-role key, which exists only in GitHub Actions secrets. That is what
-- .github/workflows/sweep.yml is for; this query is how you see what it would remove
-- without needing that key.
--
-- SAFETY. This finds orphans by "not referenced", so it must never be trusted while a
-- curation run is in flight: an object uploaded seconds ago whose ingest has not yet
-- committed looks exactly like an orphan. `concurrency: curate` guarantees at most one
-- curation run, so check that none is running first.
--
--     python .tmp/q.py tools/sweep-orphans.sql
--
-- At ~63 KB per orphaned object this is about hygiene and audit clarity, not quota.

with valid as (
  select jsonb_array_elements_text(k.ks -> 'stills') as name
    from public.question_bank q
    cross join lateral (
      select public.question_asset_keys(
               q.asset_slug, q.poster_slug, q.audio_slug, q.still_count) as ks
    ) k
  union all
  select k.ks ->> 'poster'
    from public.question_bank q
    cross join lateral (
      select public.question_asset_keys(
               q.asset_slug, q.poster_slug, q.audio_slug, q.still_count) as ks
    ) k
  union all
  select k.ks ->> 'audio'
    from public.question_bank q
    cross join lateral (
      select public.question_asset_keys(
               q.asset_slug, q.poster_slug, q.audio_slug, q.still_count) as ks
    ) k
),
orphans as (
  select o.name, (o.metadata ->> 'size')::bigint as bytes
    from storage.objects o
   where o.bucket_id = 'media'
     and not exists (select 1 from valid v where v.name = o.name)
)
select count(*)                                            as orphan_count,
       coalesce(round(sum(bytes) / 1024.0), 0)             as orphan_kb,
       coalesce(string_agg(name, ', ' order by name), '(none)') as keys
  from orphans;
