# Willagrams — database schema

Source of truth is `supabase/migrations/0001_init.sql`, with `0002_participant_lookup.sql`
and `0003_join_match.sql` on top of it. They are `protected:` in `MAP.md`: a
later migration goes through `/foundation`, not through a lane.

The runnable checks are `supabase/tests/schema_invariants.sql` — every invariant
below from both sides, because a constraint that never fires looks identical to
a working one until bad data arrives — and `supabase/tests/rls_behavior.sql`,
which reads and writes as an actual player, because a wrong policy returns zero
rows rather than an error.

    createdb willagrams_schema_check
    psql -q -d willagrams_schema_check <<'SQL'
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$
      select (nullif(current_setting('request.jwt.claims', true), '')::json->>'sub')::uuid $$;
    create role authenticated;
    SQL
    for f in 0001_init 0002_participant_lookup 0003_join_match; do
      psql -v ON_ERROR_STOP=1 -d willagrams_schema_check -f supabase/migrations/$f.sql
    done
    psql -q -d willagrams_schema_check <<'SQL'
    grant usage on schema public to authenticated;
    grant select, insert, update, delete on all tables in schema public to authenticated;
    SQL
    psql -v ON_ERROR_STOP=1 -d willagrams_schema_check -f supabase/tests/schema_invariants.sql
    psql -v ON_ERROR_STOP=1 -d willagrams_schema_check -f supabase/tests/rls_behavior.sql
    dropdb willagrams_schema_check

The `auth` block and the grants are the stub Supabase provides for real; neither
is part of a migration. Two details matter and cost an afternoon each if they
are wrong. `auth.uid()` must read `request.jwt.claims` as JSON, which is what
Supabase actually sets and what `rls_behavior.sql` sets — the older stub here
read a `request.jwt.claim.sub` GUC that nothing writes, so `auth.uid()` was null
for every reader and every policy assertion would have been meaningless. And
`authenticated` needs table grants: RLS narrows privileges, it does not confer
them, so without the grants every read fails with `permission denied` before a
policy is ever consulted.

Both files clean up after themselves and may be run repeatedly in either order.
Last run: 17 illegal writes rejected, `ALL SCHEMA INVARIANTS ENFORCED`; 33
policy assertions, `ALL RLS POLICIES BEHAVE`.

## The four tables

| Table | Holds | Read by |
|---|---|---|
| `profiles` | one row per signed-in player: name, friend code, stats | `account` (profile page), `friends` (lookup) |
| `friendships` | one row per unordered pair, and who asked | `friends` |
| `matches` | one row per match, lobby through result | `online`, `shell` |
| `match_players` | who is in which match | `online`, `shell` |

## Invariants enforced in SQL

**profiles**
- `display_name` is 1–24 characters.
- `friend_code` matches `^[A-Z0-9]{8}$` and is unique across the table.
- The three counters are non-negative, and `matches_won <= matches_played` — a
  4-of-2 record is rejected at write time rather than rendered on the profile
  page.
- `fastest_win_seconds` is null or positive; null means the player has not won.
- Deleting the auth user deletes the profile, which deletes its memberships.

**friendships**
- `status` is one of `pending`, `accepted`, `blocked`.
- You cannot befriend yourself.
- `responded_at` is null **exactly** while `status = 'pending'`, so the status
  and the timestamp beside it can never disagree.
- `friendships_pair_idx` allows at most one row per unordered pair. The primary
  key alone does not catch this: `(A,B)` and `(B,A)` are distinct keys, so
  without the index both directions insert and the friends list shows the same
  person twice with two different statuses.

**matches**
- `invite_code` matches `^[A-Z0-9]{6}$` and is unique. Shorter than a friend
  code because it is typed under time pressure and lives for one match.
- `seed >= 0`. Postgres `bigint` is signed, so the host draws seeds in
  `0...Int64.max` rather than the full `UInt64` range. Nothing depends on the
  high bit.
- `started_at` is non-null **exactly** when `status` is `playing` or
  `finished`; `finished_at` is non-null **exactly** when `status` is
  `finished`. The lobby list and the history list can never both claim a row.
- `winner_id` is null unless the match is finished.
- `options` is opaque `jsonb`. A column per rule variant would need a migration
  every time `settings` adds one; the client owns that shape.

**match_players**
- `(match_id, player_id)` is the primary key, so a player cannot join twice.

## Invariants NOT enforced in SQL

Both need a statement-level trigger or an edge function, and both are cheap to
get right in the client and expensive to get right in a policy. They are listed
here so the `online` lane does not assume the database is holding them:

1. **A `playing` match holds 2 to 6 `match_players` rows.** The count lives in
   a different table from the status, so no check constraint can see it. The
   host enforces it before flipping `status` to `playing`, and
   `MatchMessage.validatedStart` refuses a roster outside `MatchLimits.players`
   on every device that receives it — so a bad roster cannot start a match even
   if a bad row reaches the table.
2. **`winner_id` names one of that match's players.** A foreign key reaches
   `profiles`, not "a profile in this match". The win already carries its
   placements over the wire and every device validates them, so a wrong
   `winner_id` is a reporting bug, not a cheat vector.

## Row level security

RLS is on for all four tables, and every table carries at least one policy. This
is not optional here: the anon key that reaches these tables ships inside the
app binary and is readable by anyone who downloads it.

- **`profiles` are readable by any signed-in player.** Deliberate. A friend code
  is looked up by someone who is not yet your friend, and the stats are what the
  profile page exists to show. Nothing private lives on this table — no email,
  no auth data. Writes are restricted to your own row.
- **`friendships`** are readable and writable only by their two ends. Inserting
  requires that you are the requester.
- **`matches`** are readable by the host and by anyone in `match_players`.
  Joining is what grants the read, and `public.join_match(code)` is the only way
  to join: a player holding an invite code is not yet a participant, so no
  `select` of theirs can resolve the code, and the `security definer` function
  is what turns the code into a seat and then a row. Nothing else reads
  `matches` by `invite_code`. It raises `42501` with nobody signed in, `P0002`
  when no lobby carries the code, and `P0005` when the lobby already holds six.
  Only the host inserts or updates.
- **`match_players`** rows are readable by anyone in the same match, so the
  lobby can list who has joined. You may only delete yourself, and the only
  direct insert is the host seating itself in its own `lobby` match with fewer
  than six players (0003 tightened this; 0001's `auth.uid() = player_id` alone
  let anyone seat themselves in any match by id). Everyone else's seat comes
  from `join_match`. The `6` is `MatchLimits.players.upperBound` again.

No seed data and no service-role key appears in any migration. Two `security
definer` functions do — `is_match_participant` (0002) and `join_match` (0003).
Both are there because a policy cannot answer its own question, both pin
`search_path = public, pg_temp`, both are executable by `authenticated` only,
and both are written narrowly enough to tell a caller nothing about anyone but
itself.
