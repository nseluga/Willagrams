-- Willagrams — what the row level security policies actually return.
--
-- `schema_invariants.sql` asserts that every table has RLS on and carries at
-- least one policy. That catches a table nobody wrote a policy for. It cannot
-- catch a policy that is written, enabled, and wrong.
--
-- Wrong is the dangerous case here, because a policy does not raise. A read
-- the policy refuses comes back as zero rows and a write it refuses comes back
-- as zero rows affected — both indistinguishable from "there was nothing
-- there". A friends page that renders empty in production looks exactly like a
-- player with no friends, and every test against `FakeBackend` stays green
-- because the fake enforces no policies at all.
--
-- So every assertion below names the reader as well as the row: the owner sees
-- it, the stranger sees zero, and the difference is the policy doing its job.
--
-- Run against a scratch database that already has the migration applied:
--   psql -v ON_ERROR_STOP=1 -d <scratch> -f supabase/tests/rls_behavior.sql
--
-- Requires the Supabase `auth` schema, `auth.uid()`, and the `authenticated`
-- role — the same things `0001_init.sql` itself requires to apply at all.

\set ON_ERROR_STOP on

-- Becomes `who` for the statements that follow: the role the policies name,
-- carrying the claim `auth.uid()` reads.
create or replace function pg_temp.acting_as(who uuid)
returns void language plpgsql as $$
begin
    reset role;
    perform set_config('request.jwt.claims',
                       json_build_object('sub', who, 'role', 'authenticated')::text,
                       false);
    execute 'set role authenticated';
end $$;

-- Drops back to the owning role, which bypasses RLS, for seeding and cleanup.
create or replace function pg_temp.acting_as_owner()
returns void language plpgsql as $$
begin
    reset role;
    perform set_config('request.jwt.claims', '', false);
end $$;

-- Asserts that `stmt` — a select — returns exactly `want` rows.
create or replace function pg_temp.must_see(stmt text, want bigint, label text)
returns void language plpgsql as $$
declare got bigint;
begin
    execute format('select count(*) from (%s) s', stmt) into got;
    if got <> want then
        raise exception 'POLICY WRONG: % — saw % row(s), expected %', label, got, want;
    end if;
    raise notice 'ok   % (% row(s))', label, got;
end $$;

-- Asserts that `stmt` — an insert, update or delete — touches exactly `want`
-- rows. A refusal that silently touches none is the failure this names.
create or replace function pg_temp.must_touch(stmt text, want bigint, label text)
returns void language plpgsql as $$
declare got bigint;
begin
    execute stmt;
    get diagnostics got = row_count;
    if got <> want then
        raise exception 'POLICY WRONG: % — touched % row(s), expected %', label, got, want;
    end if;
    raise notice 'ok   % (% row(s))', label, got;
end $$;

-- Asserts that `stmt` is refused outright, with an error rather than silence.
-- `with check` violations raise; `using` violations do not, which is exactly
-- why the two helpers above are separate.
create or replace function pg_temp.must_raise(stmt text, label text)
returns void language plpgsql as $$
begin
    begin
        execute stmt;
    exception when others then
        raise notice 'ok   refused: %', label;
        return;
    end;
    raise exception 'POLICY WRONG: % was allowed', label;
end $$;

-- Asserts that `stmt` is refused with one specific sqlstate. `join_match` has
-- an error contract rather than a policy — the client maps the code onto a
-- case, so "it raised something" is not enough: a full lobby reported as
-- notFound sends the player back to retype a code that was correct.
create or replace function pg_temp.must_raise(stmt text, code text, label text)
returns void language plpgsql as $$
begin
    begin
        execute stmt;
    exception when others then
        if sqlstate <> code then
            raise exception 'POLICY WRONG: % — raised %, expected %',
                label, sqlstate, code;
        end if;
        raise notice 'ok   refused %: %', code, label;
        return;
    end;
    raise exception 'POLICY WRONG: % was allowed', label;
end $$;

-- ---------------------------------------------------------------------------
-- Seed. Ada and Grace are friends and share a match; Alan is a stranger to
-- both and is the reader every "sees zero" assertion below uses.
--
-- The seed owns its rows outright: it clears them first, then inserts with no
-- `on conflict do nothing`. That clause was here once and it is exactly the
-- disease this file exists to name — `schema_invariants.sql` leaves a match
-- holding the same invite code behind, the seed skipped without a word, and
-- the first assertion failed on a foreign key instead of on a policy. A seed
-- that does not land must say so, for the same reason a refused read must not
-- look like an empty table.
--
-- `auth.users` is the one exception: those three rows are shared with
-- `schema_invariants.sql`, and neither file may pull them out from under the
-- other. They are inserted if absent and left alone if present.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as_owner();

-- Anything a previous run — of this file or its sibling — left behind. The
-- three players are the fixture's own, so their rows go with them.
delete from public.match_players
 where player_id in ('11111111-1111-1111-1111-111111111111',
                     '22222222-2222-2222-2222-222222222222',
                     '33333333-3333-3333-3333-333333333333');
delete from public.matches
 where host_id in ('11111111-1111-1111-1111-111111111111',
                   '22222222-2222-2222-2222-222222222222',
                   '33333333-3333-3333-3333-333333333333')
    or invite_code in ('RLSX01', 'RLSX02', 'RLSX03', 'RLSX04', 'RLSX05');
delete from public.friendships
 where requester_id in ('11111111-1111-1111-1111-111111111111',
                        '22222222-2222-2222-2222-222222222222',
                        '33333333-3333-3333-3333-333333333333')
    or addressee_id in ('11111111-1111-1111-1111-111111111111',
                        '22222222-2222-2222-2222-222222222222',
                        '33333333-3333-3333-3333-333333333333');
delete from public.profiles
 where id in ('11111111-1111-1111-1111-111111111111',
              '22222222-2222-2222-2222-222222222222',
              '33333333-3333-3333-3333-333333333333');

-- The four extra bodies the `join_match` section needs to fill a lobby. Unlike
-- Ada, Grace and Alan these are not shared with `schema_invariants.sql`, so
-- this file owns their `auth.users` rows outright and the cascade clears
-- everything hanging off them.
delete from auth.users
 where id in ('55555555-5555-5555-5555-555555555555',
              '66666666-6666-6666-6666-666666666666',
              '77777777-7777-7777-7777-777777777777',
              '88888888-8888-8888-8888-888888888888');

insert into auth.users (id) values
    ('11111111-1111-1111-1111-111111111111'),
    ('22222222-2222-2222-2222-222222222222'),
    ('33333333-3333-3333-3333-333333333333')
on conflict (id) do nothing;

insert into public.profiles (id, display_name, friend_code) values
    ('11111111-1111-1111-1111-111111111111', 'Ada',   'AAAA1111'),
    ('22222222-2222-2222-2222-222222222222', 'Grace', 'BBBB2222'),
    ('33333333-3333-3333-3333-333333333333', 'Alan',  'CCCC3333');

insert into public.friendships (requester_id, addressee_id, status, responded_at) values
    ('11111111-1111-1111-1111-111111111111',
     '22222222-2222-2222-2222-222222222222', 'accepted', now());

-- Three matches: Ada's playing match with Ada and Grace seated; Ada's empty
-- lobby, which she seats herself in below through the insert policy; and a
-- playing match Alan hosts but never sat down in, so his own self-insert has a
-- non-lobby match to be refused from.
insert into public.matches (id, host_id, invite_code, wire_version, seed, options, status, started_at)
values ('99999999-9999-9999-9999-999999999999',
        '11111111-1111-1111-1111-111111111111',
        'RLSX01', 3, 7, '{}'::jsonb, 'playing', now()),
       ('bbbbbbbb-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        'RLSX03', 3, 7, '{}'::jsonb, 'lobby', null),
       ('99999999-9999-9999-9999-999999999992',
        '33333333-3333-3333-3333-333333333333',
        'RLSX05', 3, 7, '{}'::jsonb, 'playing', now());

insert into public.match_players (match_id, player_id) values
    ('99999999-9999-9999-9999-999999999999', '11111111-1111-1111-1111-111111111111'),
    ('99999999-9999-9999-9999-999999999999', '22222222-2222-2222-2222-222222222222');

-- ---------------------------------------------------------------------------
-- profiles — public to anyone signed in, writable only by their owner.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');

-- Deliberately public: a friend code is looked up by someone who is not yet a
-- friend. If this ever returns zero, friend-code search silently finds nobody.
--
-- Named by id rather than counted over the whole table. `select 1 from
-- public.profiles` was the obvious form and it is only correct on an empty
-- database: the policy is `using (true)`, so against the real project it counts
-- every profile the live tests have ever left behind. Restricting to the
-- fixture's own three keeps the whole of the assertion's force — under a
-- reader-scoped policy Alan, who is none of them, would see zero.
select pg_temp.must_see(
    $$select 1 from public.profiles
       where id in ('11111111-1111-1111-1111-111111111111',
                    '22222222-2222-2222-2222-222222222222',
                    '33333333-3333-3333-3333-333333333333')$$, 3,
    'a stranger reads every profile');

select pg_temp.must_see(
    $$select 1 from public.profiles where friend_code = 'AAAA1111'$$, 1,
    'a stranger looks up a friend code');

-- The silent one. `using` refuses the row, so this is not an error — it is an
-- update that reports success and changes nothing.
select pg_temp.must_touch(
    $$update public.profiles set display_name = 'stolen'
      where id = '11111111-1111-1111-1111-111111111111'$$, 0,
    'a stranger cannot rename another player');

select pg_temp.must_raise(
    $$insert into public.profiles (id, display_name, friend_code)
      values ('44444444-4444-4444-4444-444444444444', 'Fake', 'DDDD4444')$$,
    'a profile inserted under an id that is not the caller');

select pg_temp.acting_as('11111111-1111-1111-1111-111111111111');

select pg_temp.must_touch(
    $$update public.profiles set display_name = 'Ada L.'
      where id = '11111111-1111-1111-1111-111111111111'$$, 1,
    'a player renames themselves');

-- ---------------------------------------------------------------------------
-- friendships — visible to the two ends and to nobody else.
-- ---------------------------------------------------------------------------

select pg_temp.must_see(
    $$select 1 from public.friendships$$, 1,
    'the requester reads their own friendship');

select pg_temp.acting_as('22222222-2222-2222-2222-222222222222');

select pg_temp.must_see(
    $$select 1 from public.friendships$$, 1,
    'the addressee reads the same friendship');

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');

-- The friends-page failure in its exact form: not an error, just nothing.
select pg_temp.must_see(
    $$select 1 from public.friendships$$, 0,
    'a stranger reads no friendship');

select pg_temp.must_raise(
    $$insert into public.friendships (requester_id, addressee_id, status)
      values ('11111111-1111-1111-1111-111111111111',
              '33333333-3333-3333-3333-333333333333', 'pending')$$,
    'a friendship requested in somebody else''s name');

select pg_temp.must_touch(
    $$delete from public.friendships
      where requester_id = '11111111-1111-1111-1111-111111111111'$$, 0,
    'a stranger cannot delete a friendship');

-- ---------------------------------------------------------------------------
-- matches — host and joined players only.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as('11111111-1111-1111-1111-111111111111');
select pg_temp.must_see(
    $$select 1 from public.matches$$, 2,
    'the host reads their matches');

select pg_temp.acting_as('22222222-2222-2222-2222-222222222222');
select pg_temp.must_see(
    $$select 1 from public.matches$$, 1,
    'a joined player reads the match');

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');

-- Joining is what grants the read, so the invite code is the capability: a
-- stranger who has not joined cannot see the row even knowing its code.
select pg_temp.must_see(
    $$select 1 from public.matches where invite_code = 'RLSX01'$$, 0,
    'a stranger cannot read a match by its invite code');

select pg_temp.must_touch(
    $$update public.matches set status = 'abandoned'
      where id = '99999999-9999-9999-9999-999999999999'$$, 0,
    'a stranger cannot abandon a match');

select pg_temp.must_raise(
    $$insert into public.matches (host_id, invite_code, wire_version, seed, options, status)
      values ('11111111-1111-1111-1111-111111111111',
              'RLSX02', 3, 7, '{}'::jsonb, 'lobby')$$,
    'a match hosted in somebody else''s name');

-- ---------------------------------------------------------------------------
-- match_players — the lobby roster, readable inside the match only.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as('22222222-2222-2222-2222-222222222222');
select pg_temp.must_see(
    $$select 1 from public.match_players$$, 2,
    'a player reads the whole roster of their match');

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');
select pg_temp.must_see(
    $$select 1 from public.match_players$$, 0,
    'a stranger reads no roster');

select pg_temp.must_raise(
    $$insert into public.match_players (match_id, player_id)
      values ('99999999-9999-9999-9999-999999999999',
              '11111111-1111-1111-1111-111111111111')$$,
    'a player dragged into a match by somebody else');

-- Seating yourself directly is the host's move only, and only in its own
-- lobby. Everyone else goes through `join_match`, which is where the lobby
-- and cap guards live; a direct insert that got past this policy would walk
-- around both.
select pg_temp.must_raise(
    $$insert into public.match_players (match_id, player_id)
      values ('99999999-9999-9999-9999-999999999999',
              '33333333-3333-3333-3333-333333333333')$$,
    'a non-host seating themselves in a playing match');

select pg_temp.must_raise(
    $$insert into public.match_players (match_id, player_id)
      values ('bbbbbbbb-0000-0000-0000-000000000001',
              '33333333-3333-3333-3333-333333333333')$$,
    'a non-host seating themselves in a lobby instead of using join_match');

select pg_temp.must_raise(
    $$insert into public.match_players (match_id, player_id)
      values ('99999999-9999-9999-9999-999999999992',
              '33333333-3333-3333-3333-333333333333')$$,
    'a host seating themselves in their own match once it is playing');

select pg_temp.acting_as('11111111-1111-1111-1111-111111111111');
select pg_temp.must_touch(
    $$insert into public.match_players (match_id, player_id)
      values ('bbbbbbbb-0000-0000-0000-000000000001',
              '11111111-1111-1111-1111-111111111111')$$, 1,
    'a host seats themselves in their own lobby');

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');

select pg_temp.must_touch(
    $$delete from public.match_players
      where player_id = '11111111-1111-1111-1111-111111111111'$$, 0,
    'a player cannot remove somebody else from a match');

-- ---------------------------------------------------------------------------
-- join_match — the one door from an invite code to a match row.
--
-- The assertions above prove the door is shut: a stranger holding a correct
-- invite code reads nothing. That is a working policy and a broken product, so
-- everything below is about the definer function being the only way through,
-- and about it refusing in the four distinct ways the client has to tell apart.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as_owner();

-- Four more players, so one lobby can be filled to `MatchLimits.players`'
-- upper bound and one more player turned away from it.
insert into auth.users (id) values
    ('55555555-5555-5555-5555-555555555555'),
    ('66666666-6666-6666-6666-666666666666'),
    ('77777777-7777-7777-7777-777777777777'),
    ('88888888-8888-8888-8888-888888888888');

insert into public.profiles (id, display_name, friend_code) values
    ('55555555-5555-5555-5555-555555555555', 'Edsger', 'EEEE5555'),
    ('66666666-6666-6666-6666-666666666666', 'Barbara','FFFF6666'),
    ('77777777-7777-7777-7777-777777777777', 'Katherine', 'GGGG7777'),
    ('88888888-8888-8888-8888-888888888888', 'Donald', 'HHHH8888');

-- A full lobby, also Ada's. The open lobby with one seat taken is `RLSX03`
-- from the top of this file, which Ada seated herself in above; the match
-- seeded `playing` there is the third case.
insert into public.matches (id, host_id, invite_code, wire_version, seed, options, status)
values ('bbbbbbbb-0000-0000-0000-000000000002',
        '11111111-1111-1111-1111-111111111111',
        'RLSX04', 3, 7, '{}'::jsonb, 'lobby');

insert into public.match_players (match_id, player_id) values
    ('bbbbbbbb-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111'),
    ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222'),
    ('bbbbbbbb-0000-0000-0000-000000000002', '55555555-5555-5555-5555-555555555555'),
    ('bbbbbbbb-0000-0000-0000-000000000002', '66666666-6666-6666-6666-666666666666'),
    ('bbbbbbbb-0000-0000-0000-000000000002', '77777777-7777-7777-7777-777777777777'),
    ('bbbbbbbb-0000-0000-0000-000000000002', '88888888-8888-8888-8888-888888888888');

select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');

-- The closed door, restated for the lobby the stranger is about to join. If
-- this ever returns 1, `join_match` has stopped being the only reader and the
-- invite code has become guessable at scale.
select pg_temp.must_see(
    $$select 1 from public.matches where invite_code = 'RLSX03'$$, 0,
    'a stranger cannot read a lobby match by its invite code');

-- The door itself. The row comes back, so the client has the id, the seed and
-- the options in one round trip rather than a join followed by a read.
select pg_temp.must_see(
    $$select * from public.join_match('RLSX03')
      where id = 'bbbbbbbb-0000-0000-0000-000000000001'$$, 1,
    'a stranger joins by code and gets the match row back');

select pg_temp.must_see(
    $$select 1 from public.matches
      where id = 'bbbbbbbb-0000-0000-0000-000000000001'$$, 1,
    'joining opens the match to the joiner');

select pg_temp.must_see(
    $$select 1 from public.match_players
      where match_id = 'bbbbbbbb-0000-0000-0000-000000000001'$$, 2,
    'the joiner sees the host and themselves');

-- Idempotent, and case-folding: a retried request or a code typed in lower
-- case is the same join, not a second row and not a not-found.
select pg_temp.must_see(
    $$select * from public.join_match('rlsx03')
      where id = 'bbbbbbbb-0000-0000-0000-000000000001'$$, 1,
    'joining twice returns the same match row');

select pg_temp.must_see(
    $$select 1 from public.match_players
      where match_id = 'bbbbbbbb-0000-0000-0000-000000000001'$$, 2,
    'joining twice seats the player once');

-- A match that has started is not in the lobby list and is not joinable, even
-- by somebody already in it. Reported as notFound on purpose: distinguishing
-- "started" from "never existed" is the oracle the function exists to avoid.
select pg_temp.must_raise(
    $$select public.join_match('RLSX01')$$, 'P0002',
    'a match that is already playing is not joinable by code');

select pg_temp.must_raise(
    $$select public.join_match('ZZZZ99')$$, 'P0002',
    'an invite code that belongs to no match');

-- The seventh player. Without the count this inserts, and a seven-player match
-- is one no client will start.
select pg_temp.must_raise(
    $$select public.join_match('RLSX04')$$, 'P0005',
    'a seventh player joining a full lobby');

-- Signed out: the role is still `authenticated` — that is what the anon key
-- carries — but there is no subject claim, so `auth.uid()` is null and there is
-- nobody to seat.
select pg_temp.acting_as(null::uuid);

select pg_temp.must_raise(
    $$select public.join_match('RLSX03')$$, '42501',
    'joining with no signed-in caller');

-- ---------------------------------------------------------------------------
-- record_outcome — the four counters, moved by deltas the server evaluates.
--
-- Every rule here is false-negative shaped in the same way the recorder's are:
-- a counter that stops moving, or one that moves the wrong way, produces a
-- profile page that looks like a player who simply has not played. So each
-- assertion below reads the whole row back and names what it should now be.
--
-- The helper is declared here rather than up with the others because it is the
-- only section that asserts on values instead of on row counts.
-- ---------------------------------------------------------------------------

-- Asserts that `stmt` — a select of exactly one value — comes back as `want`,
-- compared as text so a whole row can be named in one line. A null column
-- renders as an empty field, so `(1,0,4,)` is "played 1, won 0, 4 tiles, no
-- fastest win yet".
create or replace function pg_temp.must_equal(stmt text, want text, label text)
returns void language plpgsql as $$
declare got text;
begin
    execute stmt into got;
    if got is distinct from want then
        raise exception 'RULE WRONG: % — got %, expected %', label, got, want;
    end if;
    raise notice 'ok   % (%)', label, got;
end $$;

-- Ada's counters as the seed left them, which is what every delta below is
-- measured from. If this is not zero the section's arithmetic means nothing.
select pg_temp.acting_as('11111111-1111-1111-1111-111111111111');

select pg_temp.must_equal(
    $$select (matches_played, matches_won, tiles_placed, fastest_win_seconds)::text
        from public.profiles where id = '11111111-1111-1111-1111-111111111111'$$,
    '(0,0,0,)',
    'a fresh profile starts at zero with no fastest win');

-- A loss. Played moves, won does not, and a loss never records a time however
-- quick it was.
select pg_temp.must_equal(
    $$select (p.matches_played, p.matches_won, p.tiles_placed, p.fastest_win_seconds)::text
        from public.record_outcome(false, 4, 30) p$$,
    '(1,0,4,)',
    'a loss counts the match and the tiles, and records no time');

-- The first win. `least` over a null is the elapsed time, which is the whole
-- "first win sets it" rule with no branch.
select pg_temp.must_equal(
    $$select (p.matches_played, p.matches_won, p.tiles_placed, p.fastest_win_seconds)::text
        from public.record_outcome(true, 3, 50) p$$,
    '(2,1,7,50)',
    'the first win sets the fastest time');

-- A slower win. The one that a naive `set fastest = elapsed` would break, and
-- it would break it silently and permanently.
select pg_temp.must_equal(
    $$select (p.matches_played, p.matches_won, p.tiles_placed, p.fastest_win_seconds)::text
        from public.record_outcome(true, 0, 90) p$$,
    '(3,2,7,50)',
    'a slower win does not raise the fastest time');

select pg_temp.must_equal(
    $$select (p.matches_played, p.matches_won, p.tiles_placed, p.fastest_win_seconds)::text
        from public.record_outcome(true, 0, 20) p$$,
    '(4,3,7,20)',
    'a faster win lowers the fastest time');

-- A loss quicker than the record. `least` is guarded by the win, not by the
-- clock.
select pg_temp.must_equal(
    $$select (p.matches_played, p.matches_won, p.tiles_placed, p.fastest_win_seconds)::text
        from public.record_outcome(false, 0, 2) p$$,
    '(5,3,7,20)',
    'a fast loss does not touch the fastest time');

-- A negative count is a bug above this function. The floor is what keeps that
-- bug from eating the row's own history, which nothing recomputes.
select pg_temp.must_equal(
    $$select (p.matches_played, p.matches_won, p.tiles_placed, p.fastest_win_seconds)::text
        from public.record_outcome(false, -9, 10) p$$,
    '(6,3,7,20)',
    'a negative tile count cannot take the tally down');

-- There is no player-id parameter, so the row is the caller's by construction.
-- This pins that the returned row is in fact theirs.
select pg_temp.must_equal(
    $$select (public.record_outcome(false, 0, 10)).id::text$$,
    '11111111-1111-1111-1111-111111111111',
    'the row returned is the caller''s own');

-- Seven calls by Ada, and the other seeded player has not moved. The "wrote to
-- somebody else's row" failure, which no error would report.
select pg_temp.must_equal(
    $$select (matches_played, matches_won, tiles_placed, fastest_win_seconds)::text
        from public.profiles where id = '22222222-2222-2222-2222-222222222222'$$,
    '(0,0,0,)',
    'another player''s counters are untouched by seven of Ada''s matches');

-- The column's own check is `null or > 0`, so a match won inside a second has
-- to floor rather than be rejected. Without the floor this raises 23514 and the
-- player loses the win as well as the time.
select pg_temp.acting_as('22222222-2222-2222-2222-222222222222');

select pg_temp.must_equal(
    $$select (p.matches_played, p.matches_won, p.tiles_placed, p.fastest_win_seconds)::text
        from public.record_outcome(true, 1, 0) p$$,
    '(1,1,1,1)',
    'a win inside a second floors at one rather than failing the check');

-- A session whose profile row was never created, or has been deleted. Under
-- `profiles_update_self` there is nothing to update and nothing raises, so the
-- `not found` branch is the only thing that turns silence into an answer the
-- client can map.
select pg_temp.acting_as('44444444-4444-4444-4444-444444444444');

select pg_temp.must_raise(
    $$select public.record_outcome(false, 1, 10)$$, 'P0002',
    'a signed-in caller with no profile row');

select pg_temp.acting_as(null::uuid);

select pg_temp.must_raise(
    $$select public.record_outcome(false, 1, 10)$$, '42501',
    'recording an outcome with no signed-in caller');

-- ---------------------------------------------------------------------------
-- realtime.messages — who may listen on an invite topic, and who may write to
-- one. `0005_invite_topic_authorization.sql`.
--
-- These are the only policies in the schema whose subject is not a row. Both
-- read `realtime.topic()`, which Realtime sets to the topic being joined or
-- broadcast to before it evaluates the policy — so the assertions below set it
-- themselves, exactly as the server does. A row still has to exist for the
-- select half, because a policy that refuses and a table that is empty both
-- come back as zero rows, which is the disease this whole file is about.
--
-- The asymmetry is the point and it is asserted directly: Grace may write to
-- Ada's topic and may NOT read it. That is what lets the client send without
-- joining, and it is why a friend cannot listen in on invites meant for
-- someone else.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as_owner();

delete from realtime.messages
 where topic in ('invites:11111111-1111-1111-1111-111111111111',
                 'invites:22222222-2222-2222-2222-222222222222',
                 'invites:33333333-3333-3333-3333-333333333333');

-- One frame sitting on Ada's topic, written as the owner so no policy has a
-- say in it landing. Every read assertion below is against this one row.
insert into realtime.messages (topic, extension, payload, event)
values ('invites:11111111-1111-1111-1111-111111111111',
        'broadcast', '{}'::jsonb, 'invite');

-- Grace and Alan need a pending request between them, so 'accepted' can be
-- shown to be doing work rather than 'a row exists' doing it.
insert into public.friendships (requester_id, addressee_id, status, responded_at)
values ('22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333', 'pending', null);

-- Ada, on her own topic. The one read the policy exists to allow.
select pg_temp.acting_as('11111111-1111-1111-1111-111111111111');
select set_config('realtime.topic',
                  'invites:11111111-1111-1111-1111-111111111111', false);
select pg_temp.must_see(
    $$select 1 from realtime.messages$$, 1,
    'Ada listening on her own invite topic');

-- Alan, on Ada's topic. The defect this migration closed: before it, this was
-- a public channel and he read her live invite codes as they were sent.
select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');
select set_config('realtime.topic',
                  'invites:11111111-1111-1111-1111-111111111111', false);
select pg_temp.must_see(
    $$select 1 from realtime.messages$$, 0,
    'Alan listening on a stranger''s invite topic');

-- Grace, on Ada's topic. She is Ada's accepted friend and she still may not
-- listen — friendship buys the write below, never the read.
select pg_temp.acting_as('22222222-2222-2222-2222-222222222222');
select set_config('realtime.topic',
                  'invites:11111111-1111-1111-1111-111111111111', false);
select pg_temp.must_see(
    $$select 1 from realtime.messages$$, 0,
    'Grace listening on her friend Ada''s invite topic');

-- ...and writes to it, which is the whole send path.
select pg_temp.must_touch(
    $$insert into realtime.messages (topic, extension, payload, event)
      values ('invites:11111111-1111-1111-1111-111111111111',
              'broadcast', '{}'::jsonb, 'invite')$$, 1,
    'Grace inviting her accepted friend Ada');

-- Alan is nobody's friend, so no topic he can name will take his frame.
select pg_temp.acting_as('33333333-3333-3333-3333-333333333333');
select set_config('realtime.topic',
                  'invites:11111111-1111-1111-1111-111111111111', false);
select pg_temp.must_raise(
    $$insert into realtime.messages (topic, extension, payload, event)
      values ('invites:11111111-1111-1111-1111-111111111111',
              'broadcast', '{}'::jsonb, 'invite')$$,
    'Alan inviting a stranger');

-- A pending request is not a friendship. Alan asked Grace and she has not
-- answered, so he still cannot put a banner on her screen.
select set_config('realtime.topic',
                  'invites:22222222-2222-2222-2222-222222222222', false);
select pg_temp.must_raise(
    $$insert into realtime.messages (topic, extension, payload, event)
      values ('invites:22222222-2222-2222-2222-222222222222',
              'broadcast', '{}'::jsonb, 'invite')$$,
    'inviting someone whose friend request is still pending');

-- A topic that is not an invite topic at all. `invite_topic_recipient` has to
-- answer *null* rather than raise, or a stranger joining `invites:hello` gets a
-- 500 out of a rule that meant to say no. Asserted on the function directly as
-- well as through the policy: `must_raise` below is happy with any error, so on
-- its own it cannot tell "the policy refused" from "the cast blew up", which is
-- exactly the difference this line is about.
select pg_temp.must_see(
    $$select 1 where public.invite_topic_recipient('invites:not-a-uuid') is null
                 and public.invite_topic_recipient('match:whatever') is null
                 and public.invite_topic_recipient(
                         'invites:11111111-1111-1111-1111-111111111111')
                     = '11111111-1111-1111-1111-111111111111'::uuid$$, 1,
    'invite_topic_recipient answers null for a topic it cannot parse');

select set_config('realtime.topic', 'invites:not-a-uuid', false);
select pg_temp.must_raise(
    $$insert into realtime.messages (topic, extension, payload, event)
      values ('invites:not-a-uuid', 'broadcast', '{}'::jsonb, 'invite')$$,
    'broadcasting to a topic that is not a uuid');

select pg_temp.acting_as_owner();
select set_config('realtime.topic', '', false);

-- ---------------------------------------------------------------------------
-- Leave the database as the fixture found it, so the next run of this file or
-- of `schema_invariants.sql` starts from the same place this one did.
-- ---------------------------------------------------------------------------

select pg_temp.acting_as_owner();

delete from public.match_players
 where match_id in ('99999999-9999-9999-9999-999999999999',
                    '99999999-9999-9999-9999-999999999992',
                    'bbbbbbbb-0000-0000-0000-000000000001',
                    'bbbbbbbb-0000-0000-0000-000000000002');
delete from public.matches
 where id in ('99999999-9999-9999-9999-999999999999',
              '99999999-9999-9999-9999-999999999992',
              'bbbbbbbb-0000-0000-0000-000000000001',
              'bbbbbbbb-0000-0000-0000-000000000002');
delete from auth.users
 where id in ('55555555-5555-5555-5555-555555555555',
              '66666666-6666-6666-6666-666666666666',
              '77777777-7777-7777-7777-777777777777',
              '88888888-8888-8888-8888-888888888888');
delete from realtime.messages
 where topic in ('invites:11111111-1111-1111-1111-111111111111',
                 'invites:22222222-2222-2222-2222-222222222222',
                 'invites:33333333-3333-3333-3333-333333333333');
delete from public.friendships
 where requester_id in ('11111111-1111-1111-1111-111111111111',
                        '22222222-2222-2222-2222-222222222222');
-- Ada, Grace and Alan are shared with `schema_invariants.sql`, so this file
-- used to leave their `auth.users` rows for that file's top-of-run sweep to
-- take. Three orphan auth rows on the live project is a small thing, but "the
-- fixture leaves nothing" is easier to check than "the fixture leaves exactly
-- these three". The cascade takes the profiles, so this replaces the profile
-- delete rather than following it. Both files recreate all three at the top.
delete from auth.users
 where id in ('11111111-1111-1111-1111-111111111111',
              '22222222-2222-2222-2222-222222222222',
              '33333333-3333-3333-3333-333333333333');

select 'ALL RLS POLICIES BEHAVE' as result;
