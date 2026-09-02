# Willagrams — online lane

Round 2. First version: online 1v1 between friends over Supabase — a hosted
client, a session, database access, and the `MatchTransport` adapter over a
realtime channel. No screen, no matchmaking, no chat, no message replay.

Lane: online — The backend seam that replaces GameKit — hosted client, authentication session, database access, and the MatchTransport adapter over realtime channels. Owns match creation and the invite plumbing behind shell's buttons. Owns the schema migrations. Does not own any screen.

Owned — this lane's items live inside these paths:
  Willagrams/Online/**
  Tests/OnlineTests/**
  supabase/**

Open — merged lanes. Wiring items may edit these; rebase onto `integration` first:
  Willagrams/Style/**, Tests/StyleTests/**, docs/ip-review.md            (style)
  Willagrams/Board/**, Tests/BoardTests/**                              (board)
  Willagrams/Match/**, Tests/MatchTests/**                              (match)
  Willagrams/Settings/**, Tests/SettingsTests/**                        (settings)
  Willagrams/Shell/**, Willagrams/App/**, Tests/ShellTests/**           (shell)
  Willagrams/Bot/**, Tests/BotTests/**                                  (bot)
  Willagrams/Audio/**, Tests/AudioTests/**                              (audio)

Stop and report if an item requires changing a path outside both lists:
  protected — Sources/WillagramsRules/Contracts.swift, Sources/WillagramsRules/BoardAnalysis.swift, Sources/WillagramsRules/Pool.swift, Sources/WillagramsRules/GameState.swift, Sources/WillagramsRules/MatchMessage.swift, Sources/WillagramsRules/MatchOptions.swift, Sources/WillagramsRules/WordList.swift, Sources/WillagramsRules/Resources/dictionary.txt, Tests/WillagramsRulesTests/**, Willagrams/Match/MatchTransport.swift, Willagrams/Style/DesignTokens.swift, Willagrams/Style/Terminology.swift, Willagrams.entitlements, Package.swift, supabase/migrations/**, Willagrams/Online/BackendContracts.swift, Willagrams/Audio/AudioPlayer.swift
  an unmerged lane's — Willagrams/Account/**, Tests/AccountTests/** (account); Willagrams/Friends/**, Tests/FriendsTests/** (friends); fastlane/**, docs/store/** (launch)
  unowned — `.` (repo root), .claude/**, docs/*.md except docs/ip-review.md and docs/store/**, progress/**, Sources/WillagramsRules/**, Tests/WillagramsRulesTests/**, Willagrams.xcodeproj/**

Frozen contracts — build and test against these; they will not move:
  match — Willagrams/Match/MatchTransport.swift (the protocol and its stream contract, lines 44–63) and Sources/WillagramsRules/MatchMessage.swift (wire v3); fixture Tests/WillagramsRulesTests/Fixtures/wire-v3.json
  online's own seam — Willagrams/Online/BackendContracts.swift (`BackendClient`, row types, `BackendError`); fixture Tests/OnlineTests/Cases/BackendContractTests.swift
  schema — supabase/migrations/0001_init.sql, 0002_participant_lookup.sql, 0003_join_match.sql (`public.join_match(code text) returns matches`; sqlstate P0002 → notFound, P0005 → matchFull, 42501 → notAuthenticated); fixtures supabase/tests/schema_invariants.sql and rls_behavior.sql

Test against the fixture, not the producing lane. Do not wait for it to exist.

## Global rules

- `Willagrams/Online/BackendContracts.swift` and `Willagrams/Online/FakeBackend.swift` never import `Supabase`. The seam stays SDK-free so `account`, `friends` and every test package compile without it.
- `supabase/migrations/**` is protected. A schema change is a `/foundation` amendment, never a lane item. `join_match` is the only join path for a non-host; the `match_players` insert policy admits only the host into its own lobby. Do not work around RLS from the client.
- No service-role key, database password, or access token appears anywhere in the repo. `SupabaseConfig.swift` holds the project URL and the anon key only — the anon key is public by design and RLS is the fence.
- Live-project tests run only when the environment variable `WILLAGRAMS_LIVE_TESTS=1` is set. Unset, they are reported as skipped and every OnlineTests case stays green offline. Each live test signs in fresh anonymous users and never depends on rows another test left behind.
- `signInAnonymously()` on the concrete client exists only under `#if DEBUG`. It is never on the `BackendClient` protocol and never reachable in Release.
- Symlink hazard: `Tests/OnlineTests/MatchSrc` is a live write-through into `Willagrams/Match/**`. Never edit a file reached through it; that path belongs to `match`.
- `MatchSession` is at a toolchain limit: adding one observed stored property aborts MatchTests. This lane adds no state to `MatchSession`; if an item believes it must, stop and report.
- Every OnlineTests case is run with `swift test --package-path Tests/OnlineTests` as a literal command. `swift test` never compiles SwiftUI; the `xcodebuild` line in README is the only check that the app target still builds after a change under `Willagrams/`.

Fuller context: `README.md` (run/verify commands), `MAP.md` (lane map, symlink hazard, decisions), `FOUNDATION.md` (frozen contracts and the Sign in with Apple postponement), `docs/schema.md`.

## Out of scope

- Matchmaking with strangers — v1 plays friends only; a queue is a later lane item, not a contract change (MAP.md).
- Chat — cut from this release; needs message storage and a report/block flow.
- Message replay / reconnect after a socket loss — a `.gone` peer is dropped by the frozen session rules; a `match_messages` table is a second amendment for a later round.
- Any screen — shell round 3 wires "Play with a friend"; account and friends own their pages.
- Lobbies larger than two — the schema, wire and session stay at 2 to 6; only the façade's `start()` insists on exactly one guest this version.
- The stale stage notes in `scripts/supabase-setup.sh` — `scripts/` is in no lane's `owns:`; Reviewer edit.

---

- task: The concrete Supabase client and its session. `Willagrams/Online/SupabaseConfig.swift` holds the project `url` and `anonKey` as constants. `Willagrams/Online/SupabaseBackend.swift` declares `public actor SupabaseBackend: BackendClient` over one `SupabaseClient` (Auth, PostgREST, Realtime — the products already linked in the xcodeproj). Implements `currentUserID`, `signOut`, `profile(id:)`, `profile(friendCode:)` (nil on zero rows, never a throw), `updateDisplayName`, and `#if DEBUG public func signInAnonymously() async throws -> Profile`. Both sign-in routes call one private `ensureProfile()`: select the caller's own row; if missing, insert it with a random `[A-Z0-9]{8}` friend code and a placeholder display name, retrying once on a unique violation. `signInWithApple(idToken:nonce:)` throws `BackendError.notAuthenticated` until item 8. One `BackendError` mapping turns PostgREST and Auth errors into the closed enum: sqlstate 23505 → `alreadyExists`, 42501 → `permissionDenied` (or `notAuthenticated` when no session), P0002 → `notFound`, P0005 → `matchFull`, `URLError` → `offline`; anything else rethrows. `Tests/OnlineTests/Cases/LiveProject.swift` holds the `WILLAGRAMS_LIVE_TESTS` gate and a helper that constructs a `SupabaseBackend` and signs in a fresh anonymous user.
  guardrails:
    - `FakeBackend.swift` keeps compiling and every existing FakeBackendTests case keeps passing; this item adds beside the fake, it does not edit its behaviour
    - The friend-code generator draws from the same 36-character alphabet the column check enforces; a code that fails the check constraint is a bug in this item, not a retry case
    - Decoding goes through `BackendCoding.decoder` / `.encoder`, never a second `JSONDecoder` with its own date strategy
  done when:
    - With the gate set, a fresh anonymous sign-in returns a `Profile` whose `profiles` row exists with an 8-character friend code and `matchesPlayed == 0`
    - Signing the same user in a second time returns the same row; the table holds one row for that id, not two
    - A PostgREST unique violation surfaces as `BackendError.alreadyExists`, and `profile(friendCode:)` for an unknown code returns nil without throwing
    - With the gate unset, `swift test --package-path Tests/OnlineTests` passes with every live case reported as skipped, and the 26 existing cases still pass
  status: done — e061e4a; live criteria 1-3 deferred to a live pass (no anon key this session)

- task: Friendships on the real client. `Willagrams/Online/SupabaseBackend+Friends.swift` implements `friendships()`, `requestFriend(addresseeID:)`, `respondToFriendRequest(requesterID:accept:)` and `block(_:)` against the `friendships` table under the existing policies. Semantics are the ones `FakeBackendTests` already pins: one row per unordered pair (the `friendships_pair_idx` unique index is the dedupe, surfaced as `alreadyExists`), decline stores `blocked`, `respondedAt` is stamped once on the transition out of `pending`, `block` upserts the pair as `blocked` with the caller as requester when no row exists.
  guardrails:
    - No definer function, no client-side pair scan to fake uniqueness — the index does it
    - A refused read is zero rows, not an error; the tests name the reader on every assertion
  done when:
    - Two anonymous users request and accept, and `friendships()` from either side returns exactly one `accepted` row with `respondedAt` set
    - A third anonymous user's `friendships()` contains zero rows for that pair
    - A second `requestFriend` for the same pair from either direction throws `alreadyExists`
    - Responding to a request that does not exist throws `notFound`
  status: not started
  parallel-group: b

- task: Matches on the real client. `Willagrams/Online/SupabaseBackend+Matches.swift` implements `createMatch(options:seed:)`, `joinMatch(inviteCode:)` and `players(inMatch:)`. `createMatch` inserts the `matches` row with a random `[A-Z0-9]{6}` invite code (retry once on a unique violation), `wire_version = WireFormat.current`, the signed seed, `options` encoded through `BackendCoding.encoder`, `status = 'lobby'`, and then inserts the host's own `match_players` row so the host is a participant like everyone else. `joinMatch` calls `rpc("join_match", params: ["code": code])` and decodes the returned `matches` row; P0002 maps to `notFound`, P0005 to `matchFull`. `players(inMatch:)` selects the roster ordered by `joined_at`.
  guardrails:
    - Never select `matches` by `invite_code` from the client; `join_match` is the only code-to-row path
    - The host's `match_players` insert is part of `createMatch`, never left to the caller
  done when:
    - Host creates a match and `players(inMatch:)` returns one row naming the host
    - A guest joins by the invite code and both clients' `players(inMatch:)` return the same two rows
    - Joining with a code no lobby match carries throws `notFound`; a seventh join on a full lobby throws `matchFull`
    - The decoded `MatchRecord.options` equals the `MatchOptions` the host passed, and `poolSeed` equals the seed the host drew
  status: not started
  parallel-group: b

- task: The realtime transport. `Willagrams/Online/RealtimeMatchTransport.swift` declares `public actor RealtimeMatchTransport: MatchTransport` over one Supabase Realtime channel named `match:<match uuid>`. Wire messages travel as broadcast event `wire` with the payload produced by the existing `MatchCodec` in `Willagrams/Match/`; presence tracks the local `PlayerID`, and a peer's presence join maps to `.connected(peer)`, leave to `.disconnected(peer)`. Honors the contract in `MatchTransport.swift` lines 44–63: `inboundMessages` and `peerConnectionStates` are single-subscription streams that return the same stream object on every access; elements produced before a consumer starts are buffered without bound and replayed in production order; `send` never applies backpressure; both streams finish on `leave()` and when the last peer's presence leaves. `MatchDelivery.lossy` sends exactly as `reliable` does. Broadcast is configured with `self: false` AND the adapter drops any inbound whose sender is `localPlayerID`, so a config change cannot echo. `SupabaseBackend.transport(for:as:)` constructs one, subscribes it, and returns it only once the subscription is confirmed.
  guardrails:
    - One subscription per channel per transport; a second `subscribe` on the same channel is a bug
    - No inbound message is dropped because no consumer has started yet; no message is delivered twice
    - `MatchCodec` is used as-is through the symlink — never edited; a codec need is a report, not a change
    - The adapter never imports SwiftUI and never touches the main actor
  done when:
    - Two transports on the live project, one per anonymous user, exchange twenty `MatchMessage`s in each direction and each side receives all twenty in send order, decoded equal to what was sent
    - A consumer that begins iterating `inboundMessages` after ten sends still receives all twenty, in order
    - The guest calling `leave()` delivers `.disconnected(guest)` on the host's `peerConnectionStates` and then finishes it; the caller's own two streams finish on `leave()`
    - `send(_:delivery: .lossy)` and `.reliable` both arrive; a send before any peer is present neither throws nor blocks
  caution: true
  status: not started

- task: Recording the match outcome. `Willagrams/Online/MatchOutcomeRecorder.swift` takes a `MatchRecord`, the local `PlayerID`, and a `MatchSession`, and observes the session's state. The match's creator (`record.hostID`) updates the `matches` row to `status = 'playing', started_at = now()` when the session enters `.playing`, and to `status = 'finished', finished_at = now(), winner_id = <winner>` when it ends with a winner. Every player, once per finished match, updates their own `profiles` row: `matches_played + 1`, `matches_won + 1` if they won, `tiles_placed + <tiles they placed>`, and `fastest_win_seconds` set only if they won and the elapsed seconds are lower than the current value or the current value is null. Elapsed is measured from `.playing` to finished on the local clock.
  guardrails:
    - A non-creator never issues a `matches` update; RLS would refuse it silently and the test names the reader
    - Exactly one stats update per player per finished match, even if the session's state is observed to change more than once after finishing
    - Never decrement any stat; never write to another player's row
  done when:
    - After a creator-started match that the guest wins, the `matches` row reads `finished` with `winner_id` = guest and both `started_at` and `finished_at` set
    - Both profiles read `matchesPlayed == 1`; the guest reads `matchesWon == 1` and a positive `fastestWinSeconds`; the creator reads `matchesWon == 0` and `fastestWinSeconds == nil`
    - A match whose session never reaches `.playing` leaves the row at `lobby` with null timestamps and both stats rows untouched
  status: not started

- task: The `OnlineMatch` façade shell will wire to. `Willagrams/Online/OnlineMatch.swift`, `@MainActor @Observable public final class OnlineMatch`. `static func host(options: MatchOptions, backend: any BackendClient) async throws -> OnlineMatch` draws a seed in `0...Int64.max`, calls `createMatch`, opens the transport via `backend.transport(for:as:)`, and exposes `inviteCode`, `record`, and a live `lobby: [PlayerID]` fed by the transport's `peerConnectionStates` (the local player is always listed). `func start() async throws -> MatchSession` refuses with a thrown error unless `lobby.count == 2` this version; otherwise it builds the roster sorted ascending by `rawValue`, sends `MatchMessage.start(version: WireFormat.current, seed: record.poolSeed, startingHandSize:, countdownSeconds:, options:, roster:)`, constructs `MatchSession(transport:roster:...)`, attaches a `MatchOutcomeRecorder`, and returns the session. `static func join(code: String, backend:) async throws -> OnlineMatch` calls `joinMatch`, opens the transport, and its `func awaitStart() async throws -> MatchSession` constructs the session with the roster from `players(inMatch:)` sorted the same way and lets the session consume the `start` message off the transport. Hand size and countdown use the same constants shell uses for solo (21 and 3) — read them from one place in this file, not duplicated from `ShellModel`.
  guardrails:
    - The pool host is `roster[0]` by the frozen rule; the façade never assumes the creator hosts the pool
    - No observed stored property is added to `MatchSession`; the façade holds its own state
    - `start()` that refuses writes nothing to the database and sends nothing on the channel
    - The `start` message carries `MatchRecord.poolSeed`, never a locally drawn second seed
  done when:
    - Creator and guest each hold a `MatchSession` that reaches `.playing` with the same seed, the same sorted two-player roster, and the same `MatchOptions`
    - `start()` with an empty lobby throws, and afterwards the `matches` row still reads `lobby`
    - The guest's `lobby` shows two players before the creator calls `start()`, and the creator's `lobby` shows the guest within the transport's presence delivery
  status: not started

- task: Wiring — this lane calls `match`. `Tests/OnlineTests/Cases/LiveMatchTests.swift` plays a whole match through real `MatchSession`s over the live project: two `SupabaseBackend`s with two fresh anonymous users, `OnlineMatch.host` and `OnlineMatch.join`, `start()` and `awaitStart()`, then each session draws through the channel (`drawRequest` → `grant` across the wire, the pool host serving both), the guest claims a win the host pool accepts, and the recorder lands the rows. This is the call site that proves the adapter, the façade and the session agree; every other item's test is a fragment of it.
  guardrails:
    - Never seed `matches`, `match_players` or `profiles` rows by hand; every row is written by the client under test
    - The test skips cleanly with the gate unset and leaves no dangling channel subscription when it finishes
  done when:
    - Both sessions reach `.finished` naming the same winner, and every draw granted on one side was observed on the other
    - The `matches` row reads `finished` with that winner, and both `profiles` rows carry the stats item 5 specifies
    - With `WILLAGRAMS_LIVE_TESTS` unset the case is reported as skipped and the package stays green
  after: match
  status: not started

> **⚠️ AUTONOMOUS RUN — STOP HERE**

- task: Real Sign in with Apple on the concrete client. `SupabaseBackend.signInWithApple(idToken:nonce:)` calls `auth.signInWithIdToken(credentials: .init(provider: .apple, idToken:, nonce:))` and then `ensureProfile()`. It cannot be exercised: the Apple Developer membership is postponed and `com.apple.developer.applesignin` is absent from the entitlements (FOUNDATION.md, 2026-08-25).
  guardrails:
    - No entitlement, xcodeproj, or `Willagrams.entitlements` edit — those are Reviewer calls when the membership is active
    - An empty `idToken` or `nonce` throws before any network call
  done when:
    - The app target compiles with the call in place
    - A unit test asserts that an empty token throws `BackendError.notAuthenticated` without contacting the project
  status: not started
