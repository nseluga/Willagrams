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

    @Test(
        "Two live transports exchange twenty messages each way, in order",
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

        // Decoded equal to what was sent, in send order, and each exactly once.
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

        async let states = withThrowingTaskGroup(of: [PeerConnectionState].self) { group in
            group.addTask {
                var seen: [PeerConnectionState] = []
                for await state in host.peerConnectionStates { seen.append(state) }
                return seen
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw LiveTransportTimedOut()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        guest.leave()

        // The stream finishing at all is half the assertion: a `for await` on a
        // match that is over must end rather than hang.
        let seen = try await states
        #expect(seen.contains(.connected(guestID)))
        #expect(seen.last == .disconnected(guestID))

        host.leave()
    }
}

struct LiveTransportTimedOut: Error {}
