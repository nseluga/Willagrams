# Willagrams — database schema

Source of truth is `supabase/migrations/0001_init.sql`. It is `protected:` in
`MAP.md`: a later migration goes through `/foundation`, not through a lane.

The runnable check is `supabase/tests/schema_invariants.sql`. It exercises every
invariant below from both sides — the legal row is accepted, the illegal one is
rejected — because a constraint that never fires looks identical to a working
one until bad data arrives.

    createdb willagrams_schema_check
    psql -q -d willagrams_schema_check <<'SQL'
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
    create role authenticated;
    SQL
    psql -v ON_ERROR_STOP=1 -d willagrams_schema_check -f supabase/migrations/0001_init.sql
    psql -v ON_ERROR_STOP=1 -d willagrams_schema_check -f supabase/tests/schema_invariants.sql
    dropdb willagrams_schema_check

The `auth` block is the stub Supabase provides for real; it is not part of the
migration. Last run: 17 illegal writes rejected, `ALL SCHEMA INVARIANTS
ENFORCED`.

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
  Joining is what grants the read, so the invite code is the capability.
  Only the host inserts or updates.
- **`match_players`** rows are readable by anyone in the same match, so the
  lobby can list who has joined. You may only insert or delete yourself.

No seed data, no `security definer` function, and no service-role key appears in
the migration.
