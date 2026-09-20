-- Willagrams — one finished match, applied to the caller's own row atomically.
--
-- What this replaces. `MatchOutcomeRecorder` read the player's `profiles` row,
-- computed the four counters from it in Swift, and PATCHed the whole value
-- back. That is a read-modify-write across two round trips, and the window
-- between them is not theoretical: a player finishing two matches close
-- together — two devices, or the same device with a match recorded while a
-- second is already ending — has both writes computed from the same `before`
-- row, and the second one silently overwrites the first. Nothing raises. The
-- counters simply come out one match short, on a table whose whole purpose is
-- to be a tally nobody recomputes (`0001_init.sql`: "counters, never recomputed
-- from the match tables"). A lost increment is lost for good.
--
-- The fix is to stop sending a value and start sending a delta. Every counter
-- below is `column + n`, evaluated by Postgres inside one UPDATE, so the row
-- the increment reads is the row the increment writes. Two concurrent calls
-- serialise on the row lock the UPDATE already takes; neither is computed from
-- a copy.
--
-- ## Why `security definer`, and what fences it
--
-- The obvious reading is that this one does not need it: the row is the
-- caller's own, and `profiles_update_self` already grants them the update. That
-- reading was written first and then run, and it fails for two reasons found on
-- a scratch database:
--
--   1. As `security invoker` the body executes with the caller's privileges, so
--      `auth.uid()` — a function in the `auth` schema — is a permission check on
--      the `authenticated` role rather than a given. Against the stub in
--      `docs/schema.md` it raises `permission denied for schema auth` before the
--      update is reached. Whether a real project happens to carry that grant is
--      not a thing this function should depend on.
--   2. Under a policy, a row the caller may not update is not an error — it is
--      zero rows. The `not found` branch below cannot then tell "you have no
--      profile row" from "the policy hid it", and it would report the second as
--      `P0002` → `notFound`, which is the wrong answer to give a client.
--
-- So it is definer, and the guardrail `0002` set — the definer functions in this
-- schema are few and each narrowly scoped — is widened from two to three rather
-- than abandoned. What fences this one:
--
--   * `search_path` is pinned, for the reason `0002` and `0003` pin theirs: a
--     definer function that resolves names through the caller's path is how a
--     definer function becomes a hole.
--   * **There is no player-id parameter.** The row is `auth.uid()` and nothing
--     else. A caller cannot name a row, so it cannot name the wrong one, and
--     the ownership rule is not an argument to be validated — it is the absence
--     of an argument.
--   * A null caller raises before anything is read or written.
--   * The four columns it touches are the four this function is for. It reads
--     no other table and writes no other column; `display_name` and
--     `friend_code` remain reachable only through `profiles_update_self`.
--
-- ## The rules, which are `ProfileStats.after` in Swift
--
--   * `matches_played` always +1.
--   * `matches_won` +1 on a win. Both move together, so
--     `profiles_wins_within_played` can never be crossed by this function.
--   * `tiles_placed` + the count, floored at 0. A negative count is a bug
--     above; it must not take the row's own history down with it.
--   * `fastest_win_seconds` only on a win, only downwards. `least` ignores
--     nulls in Postgres, so the first win sets it and every later win either
--     beats it or leaves it — one expression for all three cases.
--   * The elapsed floor of 1 is the column's own check (`null or > 0`): a match
--     won inside a second rounds to zero.
--
-- `ProfileStats.after` in `Willagrams/Online/MatchOutcomeRecorder.swift` states
-- the same five rules in Swift and is what every offline test double applies.
-- It is duplicated on purpose, the way the `6` in `0003` is: the two move
-- together or not at all. `MatchOutcomeRecorderLiveTests` is the crossing that
-- proves they still agree.
--
-- Error contract, mapped by `SupabaseBackend.backendError(from:hasSession:)`:
--
--   * `42501` — nobody signed in. Maps to `notAuthenticated`.
--   * `P0002` — the caller has no `profiles` row. Maps to `notFound`. Because
--     the function is definer this means exactly that and nothing else: a
--     session that outlived its profile, or one that never created one.
--
-- No table, column, constraint or policy changes here. The shape
-- `FOUNDATION.md` freezes is untouched.

create or replace function public.record_outcome(
    won boolean,
    tiles integer,
    elapsed_seconds integer
)
returns public.profiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    caller  uuid := auth.uid();
    elapsed integer := greatest(1, elapsed_seconds);
    p       public.profiles;
begin
    if caller is null then
        raise exception 'record_outcome requires a signed-in caller'
            using errcode = '42501';
    end if;

    update public.profiles set
        matches_played      = matches_played + 1,
        matches_won         = matches_won + (case when won then 1 else 0 end),
        tiles_placed        = tiles_placed + greatest(0, coalesce(tiles, 0)),
        fastest_win_seconds = case when won
                                   then least(fastest_win_seconds, elapsed)
                                   else fastest_win_seconds
                              end
     where id = caller
    returning * into p;

    if not found then
        raise exception 'no profile row for the signed-in caller'
            using errcode = 'P0002';
    end if;

    return p;
end $$;

revoke execute on function public.record_outcome(boolean, integer, integer) from public;
-- Supabase's default privileges hand every new public function to anon too;
-- the revoke from public does not cover that grant. `anon` has no `auth.uid()`
-- and would raise 42501 anyway, but the grant is the thing being removed, not
-- the outcome of calling it.
revoke execute on function public.record_outcome(boolean, integer, integer) from anon;
grant execute on function public.record_outcome(boolean, integer, integer) to authenticated;
