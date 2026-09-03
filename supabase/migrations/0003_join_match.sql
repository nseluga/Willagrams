-- Willagrams — turn an invite code into a seat at the table.
--
-- `0001_init.sql` made joining the thing that grants the read:
-- `matches_select_participants` shows a match to its host and to whoever is
-- already in `match_players`. That is the right rule and it is also a closed
-- door. A player holding a six-character invite code is, by definition, not yet
-- a participant, so every `select ... where invite_code = $1` they can write
-- comes back as zero rows — the same answer as "no such match". They cannot
-- resolve the code, so they cannot find the id, so they cannot insert the
-- membership row that would have let them resolve the code.
--
-- Loosening the policy is the wrong way out. A policy that lets anyone read a
-- match by code turns `matches` into an oracle: the anon key ships in the app
-- binary, and six characters is a space you can walk. The read has to happen
-- somewhere the policies are not, and it has to be a read the caller cannot
-- steer — which is exactly what a `security definer` function is. It runs as
-- its owner, so the lookup inside it is ordinary, and it hands back one row for
-- one code only after writing the membership row that earns it. The caller
-- never gets to ask "does this code exist" without also joining.
--
-- So: this function is the ONLY thing in the schema that reads `matches` by
-- `invite_code`. No policy does, and none should be added that does. Widen this
-- function and you widen the oracle.
--
-- `search_path` is pinned for the same reason it is pinned in `0002`: a definer
-- function that resolves names through the caller's path is how a definer
-- function becomes a hole.
--
-- The error contract, which the Swift client maps onto its own cases. These are
-- the whole interface — the function returns a row or it raises, and it never
-- returns null:
--
--   * `42501` (insufficient_privilege) — nobody is signed in. Maps to
--     `notAuthenticated` / permission denied.
--   * `P0002` (no_data_found) — no match in `lobby` carries that code. Maps to
--     `notFound`. Deliberately does not distinguish "never existed" from
--     "already started": telling those apart is the oracle again.
--   * `P0005` — the lobby is full. Maps to `matchFull`. Class `P0` is
--     PL/pgSQL's own, and the first free code in it is `P0005`: `P0001` is
--     `raise_exception`, which every un-coded `raise` already uses and so can
--     mean nothing in particular; `P0002` and `P0003` are `no_data_found` and
--     `too_many_rows`; and `P0004` is `assert_failure`, which is one of the two
--     conditions a plpgsql `when others` handler deliberately does NOT catch —
--     picking it would make this error uncatchable in every test and every
--     future trigger that tries to handle it.
--
-- The 6 below is `MatchLimits.players.upperBound`, duplicated here as a literal
-- on purpose — the database cannot import Swift and the client should not need
-- a round trip to know its own rules — so the two move together or not at all.
--
-- No table, column, constraint or policy changes here. The shape `FOUNDATION.md`
-- freezes is untouched.

create or replace function public.join_match(code text)
returns public.matches
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    caller  uuid := auth.uid();
    m       public.matches;
    seated  integer;
begin
    if caller is null then
        raise exception 'join_match requires a signed-in caller'
            using errcode = '42501';
    end if;

    -- `for update` is what keeps two players who race for the last seat from
    -- both counting five and both inserting. The second one waits here, then
    -- counts six.
    select * into m
      from public.matches
     where invite_code = upper(code)
       and status = 'lobby'
     for update;

    if not found then
        raise exception 'no lobby match with that invite code'
            using errcode = 'P0002';
    end if;

    -- Idempotent: a retried join, or a second tap on the button, is not an
    -- error and must not be a second row.
    if exists (select 1 from public.match_players
                where match_id = m.id and player_id = caller) then
        return m;
    end if;

    select count(*) into seated
      from public.match_players
     where match_id = m.id;

    if seated >= 6 then
        raise exception 'match is full'
            using errcode = 'P0005';
    end if;

    insert into public.match_players (match_id, player_id)
    values (m.id, caller);

    return m;
end $$;

revoke execute on function public.join_match(text) from public;
-- Supabase's default privileges hand every new public function to anon too;
-- the revoke from public does not cover that grant.
revoke execute on function public.join_match(text) from anon;
grant execute on function public.join_match(text) to authenticated;

-- `match_players_insert_self` as `0001` wrote it — `auth.uid() = player_id` —
-- let any signed-in player seat themselves in ANY match by id, lobby or not,
-- full or not, which walks straight around every guard above. The one direct
-- insert that is legitimate is the host seating itself in its own lobby right
-- after creating it; everyone else goes through `join_match`.
--
-- The count subquery reads `match_players` under its own select policy, which
-- resolves through `is_match_participant` (definer), so there is no recursion
-- to break; the host is a participant of its own match and sees every row.
-- The 6 is `MatchLimits.players.upperBound` again, duplicated on purpose.
drop policy if exists match_players_insert_self on public.match_players;
create policy match_players_insert_self
    on public.match_players for insert
    to authenticated
    with check (
        auth.uid() = player_id
        and exists (
            select 1 from public.matches m
            where m.id = match_players.match_id
              and m.host_id = auth.uid()
              and m.status = 'lobby'
        )
        and (select count(*) from public.match_players mp
              where mp.match_id = match_players.match_id) < 6
    );
