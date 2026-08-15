# Willagrams — Lane: match

Lane: match — GameKit multiplayer — Game Center auth, friend invite, GKMatch lifecycle, message codec, host-authoritative pool, draw/grow broadcast, win claim, disconnect + reconnect.

Protected — do not edit. Stop and report if an item requires changing one:
  Sources/WillagramsRules/Contracts.swift
  Sources/WillagramsRules/BoardAnalysis.swift
  Sources/WillagramsRules/Pool.swift
  Sources/WillagramsRules/GameState.swift
  Sources/WillagramsRules/MatchMessage.swift
  Sources/WillagramsRules/WordList.swift
  Sources/WillagramsRules/Resources/dictionary.txt
  Tests/WillagramsRulesTests/**
  Willagrams/Style/DesignTokens.swift
  Willagrams/Style/Terminology.swift
  Willagrams.entitlements
  Package.swift

Frozen contracts — build and test against these; they will not move:
  Sources/WillagramsRules/MatchMessage.swift — the wire enum
    fixture: Tests/WillagramsRulesTests/Fixtures/wire-v1.json
  Sources/WillagramsRules/Pool.swift — host-side draw/swap
  Sources/WillagramsRules/Contracts.swift — Tile, Coord, Placement, PlayerID, Board
  Sources/WillagramsRules/GameState.swift — GameState.canDraw(against:)

Test against the fixture, not the producing lane. Do not wait for it to exist.

Items scope to this lane only. This lane owns `Willagrams/Match/**` and
`Tests/MatchTests/**` and nothing else.

Global rules:
  - Never edit project.pbxproj. The target uses PBXFileSystemSynchronizedRootGroup,
    so new files are picked up automatically. Anything needing a build-setting
    change is a stop-and-report, not a workaround.
  - Only the GameKit adapter file may `import GameKit`. Every other file under
    Willagrams/Match/ must compile and be testable without it.
  - Terminology.swift is the IP fence. The mechanic is **Draw**, never "peel".
    The banned words — bunch, split, peel, dump, bananas, rotten — must not appear
    as player-facing strings *or* as source identifiers, comments, or test names.
  - Decoding anything that arrived from a peer is a trust boundary. No force
    unwraps, no `try!`, no fatalError on a decode path.
  - Two players per match this round. Do not build for N.

Tests for this lane go in `Tests/MatchTests/`. Root `Package.swift` and
`Tests/WillagramsRulesTests/**` are protected — if the test target cannot be
declared without editing them, stop and report rather than editing either.

---

- task: Define the transport seam every other item builds on — `Willagrams/Match/MatchTransport.swift`.
    A protocol carrying typed `MatchMessage` values, never bytes: send a message
    with a reliable/lossy flag, an async stream of inbound messages, a stream of
    peer connection-state changes, and `localPlayerID: PlayerID`. Ship
    `Willagrams/Match/FakeTransport.swift` alongside it — two endpoints paired in
    memory so one test process can drive both sides of a match, with hooks to
    simulate a peer disconnect and to drop a message in flight. This is what makes
    items 2–5 verifiable with no device and no Game Center account.
  guardrails:
    - The protocol carries `MatchMessage`, never `Data` — encoding belongs to the
      codec and the GameKit adapter, so nothing downstream can depend on wire bytes
    - Do not import GameKit in either file
    - FakeTransport must never be reachable from a shipping code path — it exists
      for tests and previews only
  done when:
    - A test pairs two FakeTransport endpoints and a MatchMessage sent from one arrives
      at the other unchanged, with no GameKit import anywhere in the test or the files under test
    - Simulating a peer disconnect emits a disconnected state on the surviving endpoint's
      connection-state stream
    - A message marked dropped by the test hook never arrives, and the sender does not hang
  status: done
  parallel-group: a

- task: Build the wire codec — `Willagrams/Match/MatchCodec.swift`. Encode and
    decode `MatchMessage` to and from `Data` with JSONEncoder/JSONDecoder, and
    enforce the version gate: a received `start` whose `version` differs from
    `WireFormat.current` is refused with a defined error rather than decoded and
    played. Validate against the frozen golden fixture at
    `Tests/WillagramsRulesTests/Fixtures/wire-v1.json`, which already covers all
    nine cases and all four `RejectionReason` values.
  guardrails:
    - Never edit wire-v1.json or MatchMessage. If a case appears to be missing,
      stop and report — it is an amendment, not a lane item
    - Every decode failure path returns an error. A peer can send arbitrary bytes;
      nothing here may trap, force-unwrap, or fatalError
    - Do not add a compatibility shim for a version this build does not know —
      refusing is the defined behavior
  done when:
    - Each of the nine MatchMessage cases round-trips encode→decode unchanged,
      including all four RejectionReason values
    - Every element of wire-v1.json decodes to the expected MatchMessage value
    - A start carrying a version other than WireFormat.current is refused with a
      defined error and no match state is entered
    - Truncated and structurally invalid Data return a decode error rather than trapping
  status: done
  parallel-group: a

- task: Build host authority over the pool — `Willagrams/Match/HostPool.swift`.
    The host holds the only real `Pool` and answers requests; peers never draw
    from a local copy. On `drawRequest`, take one tile per player from the pool
    and send a `grant` to each of the two players, so both racks grow by exactly
    one from a single request. On `swapRequest`, call the frozen
    `Pool.swap(_:using:)` and reply `swapGrant`, or `rejected(.notEnoughTilesToSwap)`
    when fewer than three remain. When the pool holds fewer tiles than there are
    players, broadcast `poolExhausted` instead of granting. Include a deterministic
    host-election function over two `PlayerID`s — a pure, testable rule (lower
    `rawValue` wins) so both devices independently agree on the same host with no
    negotiation message.
  guardrails:
    - The host's Pool is the single source of truth. No code path may draw from a
      client-side copy or synthesize a Tile outside the pool
    - Use the frozen Pool.draw and Pool.swap. Do not reimplement drawing, and do
      not reach into Pool.tiles
    - A rejected request must leave the pool byte-identical to what it was before
    - Host election is a pure function of the two PlayerIDs — never a timestamp,
      random value, or connection order
  done when:
    - One drawRequest against a pool of N produces exactly one grant to each of the
      two players and leaves the pool at N-2, with no tile appearing in two grants
    - A swapRequest with fewer than three tiles left yields rejected(.notEnoughTilesToSwap)
      and the pool is unchanged
    - A drawRequest against a pool holding fewer tiles than players yields poolExhausted
      and no grant
    - Host election over the same two PlayerIDs returns the same host regardless of
      argument order or which device evaluates it
  status: not started

- task: Build the client-side match state machine — `Willagrams/Match/MatchSession.swift`.
    An observable object that shell and board read. On `start`, enter
    `MatchStatus.countdown` and count down locally from receipt — not from an absolute
    timestamp, since two devices' clocks are not synchronized — then transition to
    `.playing`. Apply incoming `grant` and `swapGrant` to the local hand. Model the
    Draw obligation: when a grant arrives because the *opponent* drew, the tile is held
    behind a pending-draw flag, and while that flag is set the player may not rearrange
    their board — they must press Draw to accept it, so both players take a tile for the
    same event. Expose `canDraw` by calling the frozen `GameState.canDraw(against:)`
    rather than reimplementing the predicate. Send `drawRequest` and `swapRequest`
    through the transport.
  guardrails:
    - Never reimplement board validity. `GameState.canDraw(against:)` is frozen and
      is the only definition of "board is complete"
    - Never name the pending-draw state or its button "peel" — that word is banned by
      Terminology.swift, in identifiers as well as strings
    - The countdown counts from message receipt. Do not send, compare, or depend on
      a wall-clock timestamp from the other device
    - This type owns state only. It presents no UI and imports no SwiftUI view code
  done when:
    - Receiving start moves the session to .countdown and then to .playing after
      countdownSeconds elapse, driven by an injectable clock so the test does not sleep
    - A grant arriving from the opponent's draw sets the pending-draw flag, and board
      rearrangement is refused while it is set
    - Accepting the pending draw clears the flag, moves the tile into the hand, and
      board rearrangement is permitted again
    - canDraw returns false while any tile remains in hand, matching GameState.canDraw
      against the same state
  status: not started

- task: Build the terminal states — win, resign, and peer-disconnect freeze, in
    `Willagrams/Match/MatchSession.swift`. Sending a win transmits
    `win(player:placements:)` carrying `Board.placementList`. Receiving one moves the
    session to `MatchStatus.finished(winner:)`. Receiving `resign` does the same with
    the other player as winner. When the connection-state stream reports the peer gone,
    freeze: the board locks, no messages are sent, and the session exposes a
    reconnecting state with a deadline so shell can show a banner and a countdown.
    When the deadline passes with no reconnection, end the match. All of this is driven
    through the transport, so FakeTransport's disconnect hook tests it with no device.
  guardrails:
    - A frozen session sends nothing and mutates no game state — when the peer returns,
      the match is exactly where it was
    - Never declare a winner locally on disconnect. A dropped peer ends the match
      without a winner; only an explicit win or resign names one
    - .finished is terminal. No message received after it may move the session back
      into play
  done when:
    - Receiving win moves the session to .finished(winner:) carrying the claiming player,
      and the placements decode back into a Board equal to the sender's
    - Receiving resign moves the session to .finished with the other player as winner
    - A simulated peer disconnect freezes the session — attempts to place a tile or send
      a request are refused — and the exposed reconnecting deadline is in the future
    - Letting the deadline pass ends the match with no winner named
  status: not started

> **⚠️ AUTONOMOUS RUN — STOP HERE**

Everything below needs two physical iOS devices, two Game Center accounts, and a
build signed with the Game Center entitlement. GKMatch real-time multiplayer does
not run in the Simulator, so none of these criteria can be verified unattended.
They are written and ready; run them interactively when the hardware exists.

- task: Wrap Game Center sign-in — `Willagrams/Match/GameCenterAuth.swift`. Install
    `GKLocalPlayer.local.authenticateHandler` once per launch and publish an observable
    state: unknown, authenticating, authenticated carrying a `PlayerID` built from
    `gamePlayerID`, or unavailable with a reason. Publish the view controller GameKit
    hands back rather than presenting it here, so the shell lane owns presentation.
  guardrails:
    - Never block launch on authentication — a signed-out player still reaches the menu
      and solo practice
    - Present no UI from this type; publish the controller and let shell present it
    - Install the authenticate handler exactly once per launch, however many views observe it
  done when:
    - After a successful sign-in the state is authenticated carrying a PlayerID whose
      rawValue equals GKLocalPlayer.local.gamePlayerID
    - With Game Center signed out, the state is unavailable with a reason and the app
      remains navigable
    - Observing the auth state from two views installs the handler once, verified by a
      counter or log assertion
  status: not started

- task: Conform GKMatch to the transport — `Willagrams/Match/GKMatchTransport.swift`,
    the only file in this lane that imports GameKit. Implement `MatchTransport` over
    `GKMatch`: send through `send(_:to:dataMode:)` using `.reliable` for every
    state-changing message, encode and decode with the item-2 codec, surface
    `GKMatchDelegate` callbacks as the inbound and connection-state streams. Drive
    friend invites through `GKMatchmakerViewController` with a two-player
    `GKMatchRequest`. The host sends `start` only once GKMatch reports the peer
    connected — this, not tick broadcasting, is what prevents one device playing while
    the other waits.
  guardrails:
    - Every state-changing message goes reliable. Lossy mode is not used in this lane
    - Do not send start before GKMatch reports the peer connected
    - GameKit types must not leak through the MatchTransport protocol surface — the
      seam stays GameKit-free so the fake remains a valid substitute
  done when:
    - Two devices signed into different Game Center accounts complete a friend invite
      and both reach .playing
    - A drawRequest sent from one device results in both racks growing by exactly one
    - Killing the app on one device surfaces a disconnected state on the other within
      the GKMatch timeout
  status: not started

- task: Implement the real reconnect attempt behind the freeze built in item 5 —
    when GKMatch reports the peer gone, attempt reconnection for the freeze window,
    and end the match cleanly if it expires. The state machine already exists; this
    item wires it to GKMatch's actual reconnection behavior and confirms the frozen
    state survives a real drop rather than a simulated one.
  guardrails:
    - Do not extend the freeze window indefinitely — an unreachable peer must end the
      match rather than hang the app
    - Both devices must reach the same terminal state. A match that ends on one device
      and continues on the other is a failure, not a partial success
  done when:
    - Backgrounding the app on one device and returning within the window resumes the
      match with both boards and both racks unchanged
    - Leaving one device disconnected past the window ends the match on both devices
      with the same result and no winner named
    - Neither device is left on a frozen board with no way forward after the window expires
  status: not started

## Not yet specified

- Whether a reconnecting player needs a state catch-up message. The frozen wire enum
  has no resync case, and the freeze-on-disconnect design avoids needing one because
  nothing changes while the peer is gone. Revisit if item 8 shows real GKMatch
  reconnection loses messages sent during the drop.

## Out of scope

- Host-side verification of a win claim. The client disables the Win button on an
  invalid board and that was judged sufficient; the host accepts any win it receives.
- Matchmaking with strangers, ranked play, and leaderboards — this round is
  friend-to-friend invite only.
- Matches of more than two players — decided this round; the host draw fan-out is
  written for two.
- Button enablement and board input locking. The match lane publishes the state
  (pendingDraw, canDraw, frozen); board and shell own the controls that read it.
- Solo practice mode — shell owns it, and it needs no transport.
