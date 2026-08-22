-- 20260822000009_storage_clips.sql
--
-- The `clips` bucket. doc/DATA-MODEL.md 8.3 specified it; no migration created it, so
-- the curation pipeline had nowhere to upload to. This closes that gap.
--
-- PUBLIC READ, NOT SIGNED URLS -- doc/DATA-MODEL.md 8.3
-- The original worry was never that the bytes need protecting; it was that the
-- AnimeThemes *filename spells the answer* (doc/GAME-DESIGN.md 2.1). A uuid key
-- resolves that completely, and public read keeps two properties signed URLs would
-- cost: no extra round trip per round, and CDN caching -- so repeat plays land in the
-- separate 5 GB cached-egress allowance (doc/ARCHITECTURE.md A10) instead of the
-- metered one.
--
-- WRITES REMAIN SERVICE-ROLE-ONLY
-- storage.objects has RLS enabled by default and this migration adds no INSERT/UPDATE/
-- DELETE policy, so anon and authenticated cannot write to the bucket at all. The
-- pipeline uploads with the service_role key, which bypasses RLS. A public bucket is
-- public to *read*, not to write -- worth stating because those are easy to conflate.
--
-- The two limits below are defence in depth against a buggy pipeline run, not against
-- an attacker (an attacker cannot upload at all):
--   file_size_limit     clips target ~1 MB at 480p/20 s; 5 MB catches a transcode that
--                       silently fell back to passing the 62 MB source through.
--   allowed_mime_types  video/webm only, matching the ffmpeg output container.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('clips', 'clips', true, 5242880, array['video/webm'])
on conflict (id) do update
  set public            = excluded.public,
      file_size_limit   = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Explicit public-read policy. A `public = true` bucket is already readable through
-- /storage/v1/object/public/..., but the policy makes the intent legible in the schema
-- rather than hiding it in a boolean, and keeps reads working if the bucket flag is
-- ever flipped by mistake.
drop policy if exists "clips are publicly readable" on storage.objects;
create policy "clips are publicly readable"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'clips');
