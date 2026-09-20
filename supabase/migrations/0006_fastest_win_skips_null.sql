-- Willagrams — a win with no elapsed time does not touch the fastest win.
--
-- A win because the opponent resigned (or abandoned) is not a race the winner
-- finished, so it must not set `fastest_win_seconds`. The client says so by
-- sending `elapsed_seconds = null` for such a win.
--
-- Why a migration and not just the client: under 0004, `greatest(1, null)` is
-- 1, so a null elapsed recorded a ONE-SECOND fastest win. Any build that sends
-- null must run against a database carrying this function, never 0004's.
--
-- Same signature, security, search_path and grants as 0004; the only rule
-- change is the `elapsed_seconds is not null` guard. Everything else in 0004's
-- header still holds.
--
-- The trailing update clears every recorded fastest win (Nate, 2026-09-15):
-- resign wins recorded before this migration cannot be told apart from real
-- ones, so none are trusted. Re-running this file clears them again — apply it
-- once.

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
        fastest_win_seconds = case when won and elapsed_seconds is not null
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
revoke execute on function public.record_outcome(boolean, integer, integer) from anon;
grant execute on function public.record_outcome(boolean, integer, integer) to authenticated;

update public.profiles set fastest_win_seconds = null where fastest_win_seconds is not null;
