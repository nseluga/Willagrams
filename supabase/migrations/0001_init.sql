-- Willagrams — initial schema.
--
-- Four tables: who you are, who you know, what you played, and who played it.
-- Every table has row level security on, because the anon key that reaches
-- these tables ships inside the app binary and is readable by anyone who
-- downloads it. A table without a policy here is a table any stranger can read
-- and write.
--
-- Invariants that are NOT enforced below, and why, are recorded in
-- `docs/schema.md`.

-- ---------------------------------------------------------------------------
-- profiles — one row per signed-in player, keyed to the auth user.
-- ---------------------------------------------------------------------------

create table public.profiles (
    id                  uuid primary key references auth.users (id) on delete cascade,

    display_name        text not null
                        check (char_length(display_name) between 1 and 24),

    -- Handed to a friend over any messenger the player already has. Eight
    -- unambiguous characters, uppercase so it can be read aloud.
    friend_code         text not null unique
                        check (friend_code ~ '^[A-Z0-9]{8}$'),

    created_at          timestamptz not null default now(),

    -- The profile page's "cool stats". Counters, never recomputed from the
    -- match tables, so a purged match does not rewrite anyone's history.
    matches_played      integer not null default 0 check (matches_played >= 0),
    matches_won         integer not null default 0 check (matches_won >= 0),
    tiles_placed        integer not null default 0 check (tiles_placed >= 0),

    -- Null until the player wins once. Seconds, so it survives a client clock
    -- with worse resolution than the server's.
    fastest_win_seconds integer
                        check (fastest_win_seconds is null or fastest_win_seconds > 0),

    -- You cannot win a match you did not play. Catches a bad counter update
    -- at write time rather than showing a 4/2 record on the profile page.
    constraint profiles_wins_within_played check (matches_won <= matches_played)
);

-- ---------------------------------------------------------------------------
-- friendships — one row per unordered pair, remembering who asked.
-- ---------------------------------------------------------------------------

create table public.friendships (
    requester_id uuid not null references public.profiles (id) on delete cascade,
    addressee_id uuid not null references public.profiles (id) on delete cascade,

    status       text not null check (status in ('pending', 'accepted', 'blocked')),

    created_at   timestamptz not null default now(),

    -- Set when the addressee answers. Null exactly while the request is open,
    -- so "pending" cannot disagree with the timestamp beside it.
    responded_at timestamptz,

    primary key (requester_id, addressee_id),

    constraint friendships_not_self check (requester_id <> addressee_id),
    constraint friendships_responded_iff_answered
        check ((status = 'pending') = (responded_at is null))
);

-- At most one row per unordered pair. Without this, A requests B and B
-- requests A both succeed, and the friends list shows the same person twice
-- with two different statuses. The primary key alone does not catch it,
-- because (A,B) and (B,A) are distinct keys.
create unique index friendships_pair_idx
    on public.friendships (least(requester_id, addressee_id),
                           greatest(requester_id, addressee_id));

-- Answering "who are my friends" without scanning: the pair index only helps
-- the ordered form, and both columns are queried.
create index friendships_addressee_idx on public.friendships (addressee_id);

-- ---------------------------------------------------------------------------
-- matches — one row per match, from lobby to result.
-- ---------------------------------------------------------------------------

create table public.matches (
    id           uuid primary key default gen_random_uuid(),

    host_id      uuid not null references public.profiles (id) on delete cascade,

    -- What a friend types to join. Six characters, shorter than a friend code
    -- because it is typed under time pressure and lives for one match.
    invite_code  text not null unique check (invite_code ~ '^[A-Z0-9]{6}$'),

    -- `WireFormat.current` at creation. A client that does not speak it
    -- refuses the match rather than decoding garbage.
    wire_version integer not null check (wire_version > 0),

    -- Postgres bigint is signed, so the host draws seeds in 0...Int64.max
    -- rather than the full UInt64 range. Nothing depends on the high bit.
    seed         bigint not null check (seed >= 0),

    -- MatchOptions, as encoded by the client. Kept opaque here: the rules are
    -- the client's contract, and a column per option would need a migration
    -- every time a variant is added.
    options      jsonb not null,

    status       text not null check (status in ('lobby', 'playing', 'finished', 'abandoned')),

    created_at   timestamptz not null default now(),
    started_at   timestamptz,
    finished_at  timestamptz,

    winner_id    uuid references public.profiles (id) on delete set null,

    -- A match has started exactly when it is playing or finished. Keeps the
    -- lobby list and the history list from ever both claiming the same row.
    constraint matches_started_iff_underway
        check ((status in ('playing', 'finished')) = (started_at is not null)),

    -- Only a finished match has a winner. An abandoned match has none, and a
    -- lobby certainly does not.
    constraint matches_winner_only_when_finished
        check (winner_id is null or status = 'finished'),

    constraint matches_finished_iff_finished
        check ((status = 'finished') = (finished_at is not null))
);

create index matches_host_idx on public.matches (host_id);

-- ---------------------------------------------------------------------------
-- match_players — who is in which match.
-- ---------------------------------------------------------------------------

create table public.match_players (
    match_id  uuid not null references public.matches (id) on delete cascade,
    player_id uuid not null references public.profiles (id) on delete cascade,
    joined_at timestamptz not null default now(),

    primary key (match_id, player_id)
);

create index match_players_player_idx on public.match_players (player_id);

-- ---------------------------------------------------------------------------
-- Row level security.
-- ---------------------------------------------------------------------------

alter table public.profiles      enable row level security;
alter table public.friendships   enable row level security;
alter table public.matches       enable row level security;
alter table public.match_players enable row level security;

-- Profiles are public to signed-in players. Deliberate: a friend code is
-- looked up by someone who is not yet your friend, and the stats are what the
-- profile page exists to show. Nothing private lives on this table.
create policy profiles_select_any_authenticated
    on public.profiles for select
    to authenticated
    using (true);

create policy profiles_insert_self
    on public.profiles for insert
    to authenticated
    with check (auth.uid() = id);

create policy profiles_update_self
    on public.profiles for update
    to authenticated
    using (auth.uid() = id)
    with check (auth.uid() = id);

-- A friendship is visible to, and writable by, only its two ends.
create policy friendships_select_own
    on public.friendships for select
    to authenticated
    using (auth.uid() in (requester_id, addressee_id));

create policy friendships_insert_as_requester
    on public.friendships for insert
    to authenticated
    with check (auth.uid() = requester_id);

create policy friendships_update_own
    on public.friendships for update
    to authenticated
    using (auth.uid() in (requester_id, addressee_id))
    with check (auth.uid() in (requester_id, addressee_id));

create policy friendships_delete_own
    on public.friendships for delete
    to authenticated
    using (auth.uid() in (requester_id, addressee_id));

-- A match is visible to its host and to everyone who joined it. Joining is
-- what grants the read, so the invite code is the capability.
create policy matches_select_participants
    on public.matches for select
    to authenticated
    using (
        auth.uid() = host_id
        or exists (
            select 1 from public.match_players mp
            where mp.match_id = matches.id and mp.player_id = auth.uid()
        )
    );

create policy matches_insert_as_host
    on public.matches for insert
    to authenticated
    with check (auth.uid() = host_id);

create policy matches_update_host
    on public.matches for update
    to authenticated
    using (auth.uid() = host_id)
    with check (auth.uid() = host_id);

-- Membership rows are visible to everyone in the same match, so the lobby can
-- list who has joined.
create policy match_players_select_same_match
    on public.match_players for select
    to authenticated
    using (
        exists (
            select 1 from public.match_players mine
            where mine.match_id = match_players.match_id
              and mine.player_id = auth.uid()
        )
        or exists (
            select 1 from public.matches m
            where m.id = match_players.match_id and m.host_id = auth.uid()
        )
    );

-- You add yourself to a match. Nobody drags anybody else in.
create policy match_players_insert_self
    on public.match_players for insert
    to authenticated
    with check (auth.uid() = player_id);

create policy match_players_delete_self
    on public.match_players for delete
    to authenticated
    using (auth.uid() = player_id);
