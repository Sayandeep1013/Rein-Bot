-- 0014 -- install the pg_cron infrastructure three documents already assumed existed,
-- and pin the last unpinned search_path.
--
-- WHAT WAS WRONG
-- `pg_cron` is cited as the mechanism behind three separate guarantees:
--   * doc/ARCHITECTURE.md 12  -- "All clients disconnect mid-game -> pg_cron sweep"
--   * doc/DATA-MODEL.md 8.2   -- 24 hour retention
--   * doc/BLOCKERS.md B-16    -- keeping the project active against the 7-day pause
-- It was never installed and no job was ever scheduled. The partial index
-- `rooms_reapable on rooms (created_at) where state <> 'over'` (migration 0004) was
-- built to serve a query that did not exist. Consequence in practice: a room whose
-- players all closed their tabs stayed `state='playing'` forever, holding its code, and
-- nothing ever reclaimed old rows.
--
-- WHAT THIS DOES INSTEAD OF REPLICATING advance_round
-- The obvious implementation -- have cron call advance_round for every due room -- is
-- wrong twice over. advance_round now requires a member (0012 removed the NULL-uid
-- bypass, deliberately), and stepping an abandoned game forward one round a minute for
-- ten minutes serves nobody. A room nobody has polled for two minutes past its deadline
-- is not mid-round, it is abandoned, so it is simply ended.
--
-- Two minutes is generous on purpose: clients poll every 1.5 s, so any room with a
-- single live tab in it advances on its own long before this fires. This is a net under
-- the trapeze, not the trapeze.
--
-- B-16 IS NOT CLOSED BY THIS, and the honest reason is worth writing down: Supabase's
-- inactivity pause counts API requests, and pg_cron is internal database activity. It
-- may or may not register. Do not record B-16 as mitigated until someone has watched a
-- project survive seven quiet days.
--
-- IDEMPOTENT: extension is IF NOT EXISTS, functions are create-or-replace, and each job
-- is unscheduled by name before being rescheduled.

create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------
-- 1. Liveness net
-- ---------------------------------------------------------------------------

create or replace function public.reap_abandoned_rooms()
returns integer
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_n integer;
begin
  update public.rooms
     set state    = 'over',
         deadline = null
   where state    = 'playing'
     and deadline is not null
     and now() > deadline + interval '2 minutes';

  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;

comment on function public.reap_abandoned_rooms() is
  'Ends rooms whose deadline passed more than two minutes ago. Round progression is '
  'client-driven (any member may call the idempotent advance_round), so this only ever '
  'fires for a room every player has left -- which previously stayed in state=playing '
  'forever. Called by the pg_cron job rein_reap_rooms. NOT granted to any client role.';

revoke all on function public.reap_abandoned_rooms() from public;
revoke all on function public.reap_abandoned_rooms() from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Retention
-- ---------------------------------------------------------------------------
-- doc/DATA-MODEL.md 8.2 specifies 24 hours. players, rounds and guesses all cascade
-- from rooms, so one delete clears the lot.

create or replace function public.purge_old_rooms()
returns integer
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_n integer;
begin
  delete from public.rooms
   where created_at < now() - interval '24 hours';

  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;

comment on function public.purge_old_rooms() is
  'Deletes rooms older than 24 hours; players, rounds and guesses cascade. Implements '
  'the retention policy in doc/DATA-MODEL.md 8.2, which was specified and never built. '
  'Called by the pg_cron job rein_purge_rooms. NOT granted to any client role.';

revoke all on function public.purge_old_rooms() from public;
revoke all on function public.purge_old_rooms() from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Schedule
-- ---------------------------------------------------------------------------
-- Unschedule-by-name first so re-applying this migration does not stack duplicate jobs.
-- cron.unschedule raises if the job is absent, hence the guarded PERFORM ... FROM form,
-- which simply does nothing when the select finds no row.

do $sched$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'rein_reap_rooms';
  perform cron.unschedule(jobid) from cron.job where jobname = 'rein_purge_rooms';
end;
$sched$;

-- Every minute. Sub-minute intervals exist in pg_cron 1.5+, but granularity buys
-- nothing here: by definition nobody is watching an abandoned room.
select cron.schedule(
  'rein_reap_rooms', '* * * * *',
  $job$select public.reap_abandoned_rooms()$job$
);

-- Hourly, at :17 rather than :00 to stay off the crowded top of the hour.
select cron.schedule(
  'rein_purge_rooms', '17 * * * *',
  $job$select public.purge_old_rooms()$job$
);

-- ---------------------------------------------------------------------------
-- 4. ingest_question: search_path = '' at last
-- ---------------------------------------------------------------------------
-- The only SECURITY DEFINER function in the schema without an empty search_path, and
-- the highest-privileged one in it. It violated the project's own written rule
-- (supabase/migrations/README.md, doc/DATA-MODEL.md 6) since 0008.
--
-- `public, pg_temp` is exploitable in the classic way if any role can CREATE in public:
-- an attacker-created public.normalise_title(varchar) would out-rank the real
-- normalise_title(text) in overload resolution and run as the definer. Nothing in this
-- schema grants that today; the fix costs one line, so the question does not need to
-- stay open.
--
-- Safe because every identifier in the body is already schema-qualified -- checked
-- before changing it, not assumed: public.question_bank, public.question_titles,
-- public.normalise_title. Only the SET clause changes; the body is character-identical
-- to 0011's.

alter function public.ingest_question(jsonb) set search_path = '';
