-- 20260822000006_rls_grants.sql
-- ReIN Bot -- RLS policies and grants. Implements doc/DATA-MODEL.md 7.1-7.3.
--
-- Two layers, deliberately both present:
--   grants   no table has INSERT/UPDATE/DELETE for any client role; content tables
--            have NO client grant at all.
--   RLS      even a future accidental grant leaks nothing: SELECT policies are
--            membership-scoped, and there are no INSERT/UPDATE/DELETE policies, so
--            RLS denies writes independently of the ACLs.
--
-- Recursion note: the spec's membership predicate reads public.players from inside a
-- policy ON other tables -- fine -- but a players policy that subqueries players would
-- recurse ("infinite recursion detected in policy"). All four policies therefore call
-- public.is_room_member(), a SECURITY DEFINER helper running as table owner, which
-- bypasses RLS on players and cannot recurse.

-- ---------------------------------------------------------------------------
-- is_room_member -- RLS-safe membership check.
-- ---------------------------------------------------------------------------

create or replace function public.is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.players p
     where p.room_id  = p_room_id
       and p.auth_uid = auth.uid()
  )
$$;

revoke execute on function public.is_room_member(uuid) from public;
grant execute on function public.is_room_member(uuid) to anon, authenticated;

comment on function public.is_room_member(uuid) is
  'Membership predicate from doc/DATA-MODEL.md 7.2, as a SECURITY DEFINER helper so '
  'policies can use it without recursing through players'' own RLS.';

-- ---------------------------------------------------------------------------
-- 7.1 Content tables -- no client grant at all, plus deny-all RLS.
-- ---------------------------------------------------------------------------
-- Supabase default privileges grant ALL to anon/authenticated on new tables; undo it.
-- The three check constraints (credit_free_only etc.) are the real answer-leak defence;
-- this removes even read access so nothing depends on restraint later.
-- Enabling RLS with zero policies is belt-and-braces: owner-run SECURITY DEFINER
-- functions (grade_guess, advance_round reading question_bank.reveal) are unaffected,
-- while any future stray grant still exposes zero rows.

revoke all on public.question_bank   from anon, authenticated;
revoke all on public.question_titles from anon, authenticated;

alter table public.question_bank   enable row level security;
alter table public.question_titles enable row level security;

-- ---------------------------------------------------------------------------
-- 7.2 Game tables -- RLS on, SELECT-only, membership-scoped. Zero write grants.
-- ---------------------------------------------------------------------------

alter table public.rooms    enable row level security;
alter table public.players  enable row level security;
alter table public.rounds   enable row level security;
alter table public.guesses  enable row level security;

create policy rooms_select_for_members on public.rooms
  for select to authenticated
  using (public.is_room_member(id));

create policy players_select_for_roommates on public.players
  for select to authenticated
  using (public.is_room_member(room_id));

create policy rounds_select_for_members on public.rounds
  for select to authenticated
  using (public.is_room_member(room_id));

-- guesses carries no room_id; hop through rounds (spec: "rows for rounds in the
-- caller's room"). Whole-room readability is deliberate -- scoreboard and reveal need
-- it. Nothing in a guesses row discloses an unrevealed answer except a correct guess's
-- raw text, so the client must not render other players' guess text until
-- ROUND_REVEAL: UI obligation, not schema-enforceable (doc/DATA-MODEL.md 7.2).
create policy guesses_select_for_members on public.guesses
  for select to authenticated
  using (
    exists (
      select 1
        from public.rounds rd
       where rd.id = guesses.round_id
         and public.is_room_member(rd.room_id)
    )
  );

-- No INSERT/UPDATE/DELETE policies exist anywhere: RLS denies every client write even
-- if an ACL were ever re-added. Every write goes through a function, so validation
-- cannot be bypassed because there is no bypass path.
revoke insert, update, delete, truncate
  on public.rooms, public.players, public.rounds, public.guesses
  from anon, authenticated;

-- TO authenticated only: every player holds an anonymous-auth session before touching
-- anything (doc/GAME-DESIGN.md 6.1). Pre-auth anon-role requests see zero rows, which is
-- correct -- they have no display name to bring to a room anyway.
