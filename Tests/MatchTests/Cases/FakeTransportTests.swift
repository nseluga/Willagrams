import Testing
import WillagramsRules
@testable import Match

/// Runs `work` in a detached task and waits at most `seconds` for its result,
/// returning `nil` when the deadline wins instead.
///
/// The waiter never awaits the work task itself, so work that genuinely never
/// returns fails the test on the deadline rather than hanging the whole run.
/// This is the only place `Task.sleep` appears in these tests — as the
/// deadline, never as synchronisation between two sides of a match.
func outcome<T: Sendable>(
    within seconds: Double = 2,
    of work: @escaping @Sendable () async -> T
) async -> T? {
    let signal = AsyncStream.makeStream(of: T?.self, bufferingPolicy: .unbounded)
    let continuation = signal.continuation

    let worker = Task.detached { continuation.yield(await work()) }
    let timer = Task.detached {
        try? await Task.sleep(for: .seconds(seconds))
        continuation.yield(nil)
    }

    var results = signal.stream.makeAsyncIterator()
    let first = await results.next() ?? nil
    worker.cancel()
    timer.cancel()
    return first
}

@Suite("Match transport")
struct FakeTransportTests {

    private let hostID = PlayerID(rawValue: "host")
    private let guestID = PlayerID(rawValue: "guest")

    // MARK: - Round trip

    /// Whole-value equality on a case that carries real payload — a check that
    /// only compares the case would pass on a transport that lost the tiles.
    @Test("A message with payload arrives at the peer unchanged, and only at the peer")
    func roundTripCarriesTheWholeValue() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)

        let granted = MatchMessage.grant(
            player: guestID,
            tiles: [Tile(letter: "Q"), Tile(letter: "I"), Tile(letter: "Z")]
        )
        let conceded = MatchMessage.resign(player: guestID)

        try await host.send(granted, delivery: .reliable)
        try await guest.send(conceded, delivery: .lossy)

        // Leaving finishes both endpoints' streams behind the buffered sends,
        // so a message the seam failed to deliver reads as `nil` and fails the
        // expectation instead of suspending this test forever.
        host.leave()

        var guestInbound = guest.inboundMessages.makeAsyncIterator()
        #expect(await guestInbound.next() == granted)

        // The host's *first* inbound element is the guest's message. Had the
        // host received its own send, this would be `granted` instead.
        var hostInbound = host.inboundMessages.makeAsyncIterator()
        #expect(await hostInbound.next() == conceded)
    }

    // MARK: - Late subscriber

    /// Items 3–5 subscribe after their state machine is built, so anything
    /// sent before that first `for await` has to survive. If this regresses,
    /// those items go flaky rather than failing here.
    @Test("Messages sent before anyone iterates are still delivered, in order")
    func lateConsumerReceivesBufferedMessages() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)

        let sent: [MatchMessage] = [
            .start(version: WireFormat.current, seed: 42, startingHandSize: 21, countdownSeconds: 3, options: .standard),
            .drawRequest(player: hostID),
            .poolExhausted,
        ]
        for message in sent {
            try await host.send(message, delivery: .reliable)
        }
        // Ends the streams behind the buffered sends: a message that went
        // missing reads as `nil` here rather than hanging the run.
        host.leave()

        var inbound = guest.inboundMessages.makeAsyncIterator()
        var received: [MatchMessage] = []
        for _ in sent {
            if let next = await inbound.next() { received.append(next) }
        }
        #expect(received == sent)

        // The state buffered by `pair` reaches a late subscriber the same way.
        var states = guest.peerConnectionStates.makeAsyncIterator()
        #expect(await states.next() == .connected(hostID))
    }

    // MARK: - Disconnect

    @Test("One endpoint leaving reaches the surviving endpoint and ends its streams")
    func disconnectReachesSurvivor() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        host.leave()

        // Draining to completion under a deadline checks both halves at once:
        // the survivor is told who left, and its loop ends instead of hanging.
        let states = await outcome {
            var seen: [PeerConnectionState] = []
            for await state in guest.peerConnectionStates { seen.append(state) }
            return seen
        }
        #expect(states == [.connected(self.hostID), .disconnected(self.hostID)])

        let inboundEnded = await outcome { () -> Bool in
            for await _ in guest.inboundMessages {}
            return true
        }
        #expect(inboundEnded == true, "the survivor's inbound stream never finished")
    }

    // MARK: - Drop hook

    @Test("A message the drop hook discards never arrives, and the send returns promptly")
    func droppedMessageNeverArrives() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)

        let lost = MatchMessage.drawRequest(player: hostID)
        let kept = MatchMessage.poolExhausted
        await host.setDropFilter { $0 == lost }

        // `nil` means the send hung past the deadline; `false` means it threw.
        let returnedCleanly = await outcome { () -> Bool in
            do {
                try await host.send(lost, delivery: .reliable)
                return true
            } catch {
                return false
            }
        }
        #expect(returnedCleanly == true, "sending a discarded message did not return cleanly in time")

        try await host.send(kept, delivery: .reliable)
        host.leave()

        // The peer's first element is the message that was kept, and after the
        // stream finishes there is nothing behind it — so the discarded one
        // never arrived, rather than merely not having arrived yet.
        var inbound = guest.inboundMessages.makeAsyncIterator()
        #expect(await inbound.next() == kept)
        #expect(await inbound.next() == nil)
    }

    // MARK: - Sending to a peer that is gone

    @Test("A send after the peer is gone throws rather than hanging")
    func sendAfterDisconnectThrows() async throws {
        let (host, guest) = FakeTransport.pair(hostID, guestID)
        guest.leave()

        let message = MatchMessage.rejected(reason: .notYourTurn)
        let threw = await outcome { () -> Bool in
            do {
                try await host.send(message, delivery: .reliable)
                return false
            } catch {
                return true
            }
        }
        #expect(threw == true, "sending to a departed peer neither threw nor returned in time")

        await #expect(throws: MatchTransportError.peerDisconnected) {
            try await host.send(message, delivery: .reliable)
        }
    }
}
