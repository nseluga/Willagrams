//
//  RealtimeMatchTransportLiveTests.swift
//
//  Criterion 1: two transports on the live project, one per anonymous user,
//  exchanging twenty messages each way. Irreducibly live — it is the only case
//  in this lane that proves the Realtime SDK, the channel topic, `self: false`,
//  presence and the RLS-authorized socket all agree with each other.
//
//  Gated by the one `LiveProject.isEnabled` gate, like every other live case.
//

import Foundation
import Testing
import WillagramsRules

@testable import Online

@Suite("Realtime transport, live project")
struct RealtimeMatchTransportLiveTests {

    private static func signedIn() async throws -> (SupabaseBackend, UUID) {
        let backend = LiveProject.fresh()
        let profile = try await backend.signInAnonymously()
        return (backend, profile.id)
    }

    /// Twenty distinguishable messages, so send order and exactly-once are both
    /// readable off the received sequence.
    private static func script(_ tag: String) -> [MatchMessage] {
        (0 ..< 20).map { .drawRequest(player: PlayerID(rawValue: "\(tag)-\($0)")) }
    }

    /// Collects `count` elements or gives up, so a message that never lands
    /// fails the case rather than hanging the run.
    private static func collect(
        _ stream: AsyncStream<MatchMessage>,
        count: Int,
        seconds: Double = 30
    ) async throws -> [MatchMessage] {
        try await withThrowingTaskGroup(of: [MatchMessage].self) { group in
            group.addTask {
                var received: [MatchMessage] = []
                for await message in stream {
                    received.append(message)
                    if received.count == count { break }
                }
                return received
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LiveTransportTimedOut()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Polls until the condition holds or the deadline passes. Each phase gets
    /// its own deadline, so a timeout names which one ran out instead of
    /// reporting one budget spanning presence sync and a grace window together.
    private static func waitFor(
        _ deadline: Duration, _ what: String, _ condition: @Sendable () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while await !condition() {
            if ContinuousClock.now - start > deadline {
                throw LiveTransportTimedOut(waitingFor: what)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test(
        "Two live transports exchange twenty messages each way, exactly once",
        .enabled(if: LiveProject.isEnabled))
    func twentyEachWayOverTheLiveProject() async throws {
        let (hostBackend, hostUser) = try await Self.signedIn()
        let match = try await hostBackend.createMatchRow(
            options: .standard, seed: Int64.random(in: 0 ... Int64.max))

        let (guestBackend, guestUser) = try await Self.signedIn()
        _ = try await guestBackend.joinMatchRow(inviteCode: match.inviteCode)

        let hostID = PlayerID(rawValue: hostUser.uuidString)
        let guestID = PlayerID(rawValue: guestUser.uuidString)

        // `transport(for:as:)` returns only once the subscription is confirmed,
        // so nothing below needs to wait for a channel to come up.
        let host = try await hostBackend.transport(for: match, as: hostID)
        let guest = try await guestBackend.transport(for: match, as: guestID)

        let fromHost = Self.script("host")
        let fromGuest = Self.script("guest")

        async let hostReceived = Self.collect(host.inboundMessages, count: fromGuest.count)
        async let guestReceived = Self.collect(guest.inboundMessages, count: fromHost.count)

        for index in 0 ..< 20 {
            try await host.send(fromHost[index], delivery: .reliable)
            try await guest.send(fromGuest[index], delivery: .reliable)
        }

        let atHost = try await hostReceived
        let atGuest = try await guestReceived

        // Strict order, not a multiset. This assertion was narrowed once,
        // because Supabase Realtime broadcast is best-effort ordered and a
        // fan-out transposes arrivals about one run in two. That is now the
        // transport's problem rather than this case's: `WireEnvelope` carries
        // a per-sender sequence and `RealtimeMatchTransport` re-orders by it.
        // If this goes red intermittently again, the reordering has stopped
        // working — do not narrow it a second time.
        #expect(atHost == fromGuest)
        #expect(atGuest == fromHost)

        host.leave()
        guest.leave()
    }

    @Test(
        "The guest leaving disconnects it on the host's stream, and ends it",
        .enabled(if: LiveProject.isEnabled))
    func guestLeavingReachesTheHostLive() async throws {
        let (hostBackend, hostUser) = try await Self.signedIn()
        let match = try await hostBackend.createMatchRow(
            options: .standard, seed: Int64.random(in: 0 ... Int64.max))

        let (guestBackend, guestUser) = try await Self.signedIn()
        _ = try await guestBackend.joinMatchRow(inviteCode: match.inviteCode)

        let hostID = PlayerID(rawValue: hostUser.uuidString)
        let guestID = PlayerID(rawValue: guestUser.uuidString)

        let host = try await hostBackend.transport(for: match, as: hostID)
        let guest = try await guestBackend.transport(for: match, as: guestID)

        let seen = ObservedStates()
        let collector = Task {
            for await state in host.peerConnectionStates { await seen.append(state) }
            await seen.markFinished()
        }

        // The host must observe the guest before the guest goes. Leaving inside
        // the window before presence sync lands means the host never saw a
        // peer, so there is no disconnect to report and the stream never ends —
        // a race in this case, not in the transport. It used to leave here
        // immediately and hung for the whole deadline whenever the project was
        // slow enough for presence to take more than a moment.
        try await Self.waitFor(.seconds(20), "the host to see the guest") {
            await seen.states.contains(.connected(guestID))
        }
        guest.leave()

        // The stream finishing at all is half the assertion: a `for await` on a
        // match that is over must end rather than hang. Derived, not a literal:
        // the host's stream finishes a whole grace window after the disconnect,
        // so moving the production default moves this with it.
        try await Self.waitFor(
            RealtimeMatchTransport.defaultPeerGrace + .seconds(25), "the stream to finish"
        ) { await seen.isFinished }

        let observed = await seen.states
        #expect(observed.contains(.connected(guestID)))
        #expect(observed.last == .disconnected(guestID))

        collector.cancel()
        host.leave()
    }
}

struct LiveTransportTimedOut: Error {
    var waitingFor: String = "a live response"
}

/// The host's states, collected off the stream. An actor because the stream is
/// drained by one task while the case reads it from another.
private actor ObservedStates {
    private(set) var states: [PeerConnectionState] = []
    private(set) var isFinished = false
    func append(_ state: PeerConnectionState) { states.append(state) }
    func markFinished() { isFinished = true }
}
