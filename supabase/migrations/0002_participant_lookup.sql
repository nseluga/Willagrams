-- Willagrams — break the recursion in the two match policies.
--
-- `0001_init.sql` asked each policy the participation question directly, and
-- the question is circular:
--
--   * `match_players_select_same_match` reads `match_players` to decide
--     whether a `match_players` row is visible. Its own policy applies to that
--     read, which asks the same question again.
--   * `matches_select_participants` reads `match_players`, whose policy reads
--     `matches`, whose policy reads `match_players`.
--
-- Postgres stops this with `infinite recursion detected in policy for relation
-- "match_players"`, and it stops it at the first read — so no player could
-- open a match at all, host included.
--
-- Nothing caught it, because nothing asked. `schema_invariants.sql` passes on
-- the broken schema: RLS is on, every table carries a policy, and both
-- statements are true of a policy that can never return. It took
-- `rls_behavior.sql` reading an actual row as an actual player.
--
-- The fix is to answer the question somewhere the policies are not: a
-- `security definer` function runs as its owner, and the owner is not subject
-- to these policies, so the lookup inside it is an ordinary read. The circle
-- is cut at one point and both policies call in.
--
-- This is a policy change only. No table, column, or constraint moves, so the
-- shape `FOUNDATION.md` freezes and the wire the lanes build against are
-- untouched.

-- Is the caller in this match, either as its host or as somebody who joined?
--
-- `security definer` is what makes this work and is also why it is written
-- narrowly: it takes a match id and returns a boolean about `auth.uid()` and
-- nobody else, so it can tell a caller nothing it could not already ask about
-- itself. `search_path` is pinned because a definer function that resolves
-- names through the caller's path is how a definer function becomes a hole.
create or replace function public.is_match_participant(target uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1 from public.matches m
        where m.id = target and m.host_id = auth.uid()
    ) or exists (
        select 1 from public.match_players mp
        where mp.match_id = target and mp.player_id = auth.uid()
    );
$$;

revoke execute on function public.is_match_participant(uuid) from public;
grant execute on function public.is_match_participant(uuid) to authenticated;

-- A match is visible to its host and to everyone who joined it. Joining is
-- what grants the read, so the invite code is the capability.
--
-- The host test stays inline. It needs no lookup, and leaving it here means a
-- host still reads their own match if the function is ever revoked.
drop policy if exists matches_select_participants on public.matches;
create policy matches_select_participants
    on public.matches for select
    to authenticated
    using (
        auth.uid() = host_id
        or public.is_match_participant(matches.id)
    );

-- Membership rows are visible to everyone in the same match, so the lobby can
-- list who has joined.
drop policy if exists match_players_select_same_match on public.match_players;
create policy match_players_select_same_match
    on public.match_players for select
    to authenticated
    using (public.is_match_participant(match_players.match_id));
