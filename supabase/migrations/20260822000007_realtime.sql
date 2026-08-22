-- 20260822000007_realtime.sql
-- ReIN Bot -- Realtime publication. Implements DATA-MODEL.md 8.1.
--
-- Only rooms, players and guesses are published to supabase_realtime. rounds is NOT:
-- round transitions are announced by advance_round's explicit broadcast (migration
-- 20260822000005), which carries the reveal payload the table does not store -- there
-- is deliberately no reveal column to publish (DATA-MODEL.md 4.3).
--
-- Every broadcast must be reconstructible from database state, because Realtime does
-- not persist messages and a client that misses one has no replay beyond re-reading
-- its rooms row (ARCHITECTURE.md 9). All three published tables carry RLS
-- (20260822000006); Realtime respects it.
--
-- Idempotent by inspection of pg_publication_tables rather than bare ALTER PUBLICATION,
-- whose ADD TABLE errors if the membership already exists.

do $$
begin
  if not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename  = 'rooms'
     ) then
    alter publication supabase_realtime add table public.rooms;
  end if;

  if not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename  = 'players'
     ) then
    alter publication supabase_realtime add table public.players;
  end if;

  if not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename  = 'guesses'
     ) then
    alter publication supabase_realtime add table public.guesses;
  end if;

  -- Guard against drift: if a future migration ever adds rounds here, the reveal's
  -- time-gating breaks (Realtime evaluates RLS at join time, not per message) and the
  -- explicit broadcast double-sends every transition. Fail loudly instead.
  if exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename  = 'rounds'
     ) then
    raise exception 'ROUNDS_MUST_NOT_BE_PUBLISHED';
  end if;
end;
$$;
