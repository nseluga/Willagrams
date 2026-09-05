//
//  MatchInviteChannelLiveTests.swift
//
//  The invite crossing the real socket, between two real anonymous users.
//
//  Irreducibly live: the offline suite proves the framing, but only the project
//  proves the topic, the authorized socket and the `payload` hop agree with each
//  other. This is the same trap that took `SupabaseMatchChannel` a live run to
//  find, so it is worth a live case of its own.
//
//  Gated by the one `LiveProject.isEnabled` gate, like every other live case.
//

import Foundation
import Testing

@testable import Online

@Suite("Invite channel, live project")
struct MatchInviteChannelLiveTests {

    /// The banner has five seconds to appear on the far device, so the wire is
    /// given the same budget here.
    private static let budget: Double = 5

    /// A whole second, so `sentAt` survives the frame's `Double` exactly and
    /// these cases compare invites rather than float precision. Freshness is
    /// `ShellModel`'s rule and is proved offline; nothing here depends on the
    /// instant being now.
    private static let sentAt = Date(timeIntervalSince1970: 1_756_000_000)

    private static func first(
        _ stream: AsyncStream<MatchInvite>, seconds: Double
    ) async throws -> MatchInvite? {
        try await withThrowingTaskGroup(of: MatchInvite?.self) { group in
            group.addTask {
                for await invite in stream { return invite }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test("An invite reaches the recipient's own channel within five seconds",
          .enabled(if: LiveProject.isEnabled))
    func anInviteCrossesTheSocket() async throws {
        let hostBackend = LiveProject.fresh()
        let host = try await hostBackend.signInAnonymously()
        let guestBackend = LiveProject.fresh()
        let guest = try await guestBackend.signInAnonymously()

        let listening = guestBackend.inviteChannel(for: guest.id)
        try await listening.subscribe()
        defer { listening.leave() }

        let sending = hostBackend.inviteChannel(for: host.id)
        try await sending.subscribe()
        defer { sending.leave() }

        let invite = MatchInvite(
            matchID: UUID(), inviteCode: "LIVE01", hostID: host.id,
            hostName: host.displayName, sentAt: Self.sentAt)
        try await sending.send(invite, to: guest.id)

        let received = try #require(
            await Self.first(listening.invites, seconds: Self.budget),
            "no invite arrived within \(Int(Self.budget)) seconds")
        #expect(received == invite)
    }

    /// The other half of the addressing rule: a channel named for one user does
    /// not carry another's invites. Without this, a topic that accidentally
    /// collapsed to a single shared room would still pass the case above.
    @Test("An invite addressed elsewhere never reaches this channel",
          .enabled(if: LiveProject.isEnabled))
    func anInviteAddressedElsewhereDoesNotArrive() async throws {
        let hostBackend = LiveProject.fresh()
        let host = try await hostBackend.signInAnonymously()
        let guestBackend = LiveProject.fresh()
        let guest = try await guestBackend.signInAnonymously()

        let listening = guestBackend.inviteChannel(for: guest.id)
        try await listening.subscribe()
        defer { listening.leave() }

        let sending = hostBackend.inviteChannel(for: host.id)
        try await sending.subscribe()
        defer { sending.leave() }

        let elsewhere = UUID()
        let missed = MatchInvite(
            matchID: UUID(), inviteCode: "LIVE02", hostID: host.id,
            hostName: host.displayName, sentAt: Self.sentAt)
        try await sending.send(missed, to: elsewhere)

        // One consumer, not two: `AsyncStream` has a single iterator, and the
        // positive twin is what makes the negative readable. The misaddressed
        // invite left first, so if the guest's channel carried it at all it
        // would be the one that arrives here.
        let addressed = MatchInvite(
            matchID: UUID(), inviteCode: "LIVE03", hostID: host.id,
            hostName: host.displayName, sentAt: Self.sentAt)
        try await sending.send(addressed, to: guest.id)

        let received = try #require(
            await Self.first(listening.invites, seconds: Self.budget),
            "not even the addressed invite arrived")
        #expect(received == addressed, "an invite addressed elsewhere reached this channel")
    }
}
