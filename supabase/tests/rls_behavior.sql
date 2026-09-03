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
select pg_temp.must_see(
    $$select 1 from public.profiles$$, 3,
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
delete from public.friendships
 where requester_id = '11111111-1111-1111-1111-111111111111';
delete from public.profiles
 where id in ('11111111-1111-1111-1111-111111111111',
              '22222222-2222-2222-2222-222222222222',
              '33333333-3333-3333-3333-333333333333');

select 'ALL RLS POLICIES BEHAVE' as result;
