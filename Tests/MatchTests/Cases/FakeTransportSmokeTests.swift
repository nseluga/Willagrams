import Testing
import WillagramsRules
@testable import Match

@Suite("Match transport smoke")
struct FakeTransportSmokeTests {

    /// Sends before any consumer exists, then starts iterating — proves both
    /// the round trip and that a late consumer neither deadlocks nor loses the
    /// message.
    @Test("A message sent from one paired endpoint arrives unchanged at the other")
    func messageArrivesUnchanged() async throws {
        let (host, client) = FakeTransport.pair(
            PlayerID(rawValue: "host"),
            PlayerID(rawValue: "client")
        )

        let sent = MatchMessage.rejected(reason: .poolEmpty)
        try await host.send(sent, delivery: .reliable)
        // Finishes the stream behind the buffered send, so a message that never
        // arrives reads as `nil` and fails rather than hanging the run.
        host.leave()

        var inbound = client.inboundMessages.makeAsyncIterator()
        #expect(await inbound.next() == sent)
    }
}
