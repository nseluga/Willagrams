# Willagrams — database schema

Source of truth is `supabase/migrations/0001_init.sql`, with `0002_participant_lookup.sql`,
`0003_join_match.sql` and `0004_record_outcome.sql` on top of it. They are `protected:` in `MAP.md`: a
later migration goes through `/foundation`, not through a lane.

The runnable checks are `supabase/tests/schema_invariants.sql` — every invariant
below from both sides, because a constraint that never fires looks identical to
a working one until bad data arrives — and `supabase/tests/rls_behavior.sql`,
which reads and writes as an actual player, because a wrong policy returns zero
rows rather than an error.

    ./scripts/scratch-verify.sh

That builds a throwaway database, applies every migration in order, then runs
both fixtures twice in either order and reports how many assertions ran (45) and
whether `public` was left empty. Run it before proposing any migration.

The script's `auth` block and its grants are the stub Supabase provides for
real; neither is part of a migration. Two details matter and cost an afternoon
each if they are wrong, which is why the script owns them rather than each
person retyping them. `auth.uid()` must read `request.jwt.claims` as JSON, which
is what Supabase actually sets and what `rls_behavior.sql` sets — a stub that
reads only the `request.jwt.claim.sub` GUC gets null for every reader, so every
policy assertion passes on nothing. And the API roles need table grants: RLS
narrows privileges, it does not confer them, so without the grants every read
fails with `permission denied` before a policy is ever consulted. `0001_init.sql`
carries no grants of its own because on Supabase they arrive by default
privilege.

`rls_behavior.sql` also runs against the live project, which holds real rows from
every online test run. Assertions are therefore scoped to the rows the fixture
itself seeds rather than counting whole tables — `select 1 from public.profiles`
is correct only on an empty database, because `profiles_select_any_authenticated`
is `using (true)`. `scripts/apply-0004-live.sh` is the live runner.

Both files clean up after themselves and may be run repeatedly in either order.
Last run: 17 illegal writes rejected, `ALL SCHEMA INVARIANTS ENFORCED`; 45
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

RLS is on for all four tables, and every table carries at least one policy.
Since `0005` it is on for `realtime.messages` too, which carries two of its own
— those are described under "Realtime topics" below. This is not optional
here: the anon key that reaches these tables ships inside the app binary and is
readable by anyone who downloads it.

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

- **Stats are bumped only through `public.record_outcome(won, tiles,
  elapsed_seconds)`.** The four counters on `profiles` are a tally nobody
  recomputes, so an increment computed on the client from a row read a round
  trip earlier can lose a match for good — two matches finishing close together
  both read the same `before` and the second write erases the first, silently.
  `record_outcome` sends deltas instead and Postgres evaluates them inside one
  UPDATE. It takes no player id: the row is `auth.uid()`, so a caller cannot
  name a row and therefore cannot name the wrong one. `42501` with nobody
  signed in, `P0002` when the caller has no profile row. The same five rules are
  stated in Swift as `ProfileStats.after`, which every offline test double
  applies; the two are duplicated on purpose and `MatchOutcomeRecorderLiveTests`
  is the crossing that proves they agree. `display_name` and `friend_code` are
  untouched by it and stay reachable only through `profiles_update_self`.

### Realtime topics

`realtime.messages` carries two policies of its own (`0005`), and they are the
only rules here whose subject is a topic rather than a row.

- **`invites:<uuid>` is a private channel.** A private channel is one the
  Realtime server checks against these policies; a public one it does not check
  at all. Both halves are required and they live in different languages: the
  policies are here, and `SupabaseMatchInviteChannel` sets `config.isPrivate =
  true` on both the channel it listens on and the one it sends to. Setting one
  without the other either denies every invite or checks nothing.
- **You may listen only on your own topic.** `auth.uid()` is the only uuid that
  can appear on the right-hand side, so there is no topic name a caller can
  build that reads someone else's invites. Before `0005` this was a public
  channel, which meant anyone who resolved a friend code to a uuid could
  subscribe and read live `invite_code`s as they were sent, then join that lobby
  ahead of the friend it was meant for.
- **You may write to an accepted friend's topic, and you never gain a read on
  it.** That asymmetry is why the client sends over the REST broadcast endpoint
  (`httpSend`) rather than joining first: joining is a read, and a sender that
  joined would need a select policy letting friends listen to each other's
  invites — a smaller copy of the same hole. `'accepted'` only; a pending
  request is not a friendship and `'blocked'` is its opposite.
- **`public.invite_topic_recipient(text)`** pulls the recipient out of the topic
  name and answers null for anything that is not `invites:<uuid>`. It exists
  because a policy is one boolean expression, `and` does not promise to
  short-circuit, and a bare cast of a non-uuid raises — so a stranger joining
  `invites:hello` would get a 500 out of a rule that meant to say no.
- **`match:<uuid>` is still a public channel.** It is reached only by a player
  `join_match` already seated, and a match id is not derivable from a profile.
  Making it private is a separate decision with its own live test; nothing in
  `0005` matches its topic, so nothing in `0005` can break it.

No seed data and no service-role key appears in any migration. Three `security
definer` functions do — `is_match_participant` (0002), `join_match` (0003) and
`record_outcome` (0004). `invite_topic_recipient` (0005) is not one of them: it
reads no table, so it has no reason to run as anyone but its caller. All three pin `search_path = public, pg_temp` and are
executable by `authenticated` only. The first two are definer because a policy
cannot answer its own question; the third is definer because as an invoker
function `auth.uid()` becomes a grant the caller must hold, and because a policy
turns "not your row" into zero rows, which would make its `P0002` mean two
different things. All three are written narrowly enough to tell a caller nothing
about anyone but itself.
