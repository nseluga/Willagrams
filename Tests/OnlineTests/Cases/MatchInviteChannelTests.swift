//
//  MatchInviteChannelTests.swift
//
//  The invite frame's wire shape, proved without a project.
//
//  The live half — two signed-in devices, one invite crossing between them — is
//  irreducibly live and is not simulated here. What is provable offline is the
//  framing, and framing is exactly where this channel's one known trap is: the
//  broadcast callback receives the whole `{type, event, payload}` message and
//  the frame lives under `payload`. `SupabaseMatchChannel` had to be fixed live
//  on 2026-09-02 for decoding the top level instead, and this file pins the
//  invite channel against repeating it.
//

import Foundation
import Realtime
import Testing

@testable import Online

@Suite("Invite channel framing")
struct MatchInviteChannelTests {

    static let invite = MatchInvite(
        matchID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        inviteCode: "ABC123",
        hostID: UUID(uuidString: "66666666-7777-8888-9999-000000000000")!,
        hostName: "Ada",
        // Whole seconds: the frame carries the instant as a `Double`, and a
        // fractional one would make this a float-equality test rather than a
        // round-trip one.
        sentAt: Date(timeIntervalSince1970: 1_756_000_000))

    @Test("A frame round-trips, and a malformed one decodes to nil rather than trapping")
    func frameRoundTrips() throws {
        let frame = SupabaseMatchInviteChannel.payload(for: Self.invite)
        #expect(frame.code == "ABC123")
        #expect(frame.name == "Ada")

        let decoded = try #require(SupabaseMatchInviteChannel.invite(from: frame))
        #expect(decoded == Self.invite)

        // A peer can put anything on the channel: a bad id is a dropped invite,
        // not a crash.
        var broken = frame
        broken = .init(
            match: "not-a-uuid", code: frame.code, host: frame.host,
            name: frame.name, sent: frame.sent)
        #expect(SupabaseMatchInviteChannel.invite(from: broken) == nil)
        broken = .init(
            match: frame.match, code: frame.code, host: "not-a-uuid",
            name: frame.name, sent: frame.sent)
        #expect(SupabaseMatchInviteChannel.invite(from: broken) == nil)
    }

    @Test("A broadcast message carries the frame under `payload`, not at the top level")
    func broadcastMessageShape() throws {
        let frame = SupabaseMatchInviteChannel.payload(for: Self.invite)
        let body: JSONObject = [
            "match": .string(frame.match),
            "code": .string(frame.code),
            "host": .string(frame.host),
            "name": .string(frame.name),
            "sent": .double(frame.sent),
        ]
        // Exactly the shape the SDK hands `onBroadcast`.
        let message: JSONObject = [
            "type": "broadcast",
            "event": .string(SupabaseMatchInviteChannel.inviteEvent),
            "payload": .object(body),
        ]
        let decoded = try #require(SupabaseMatchInviteChannel.invite(fromBroadcast: message))
        #expect(decoded == Self.invite)

        // The trap itself: the same fields at the top level are not an invite.
        #expect(SupabaseMatchInviteChannel.invite(fromBroadcast: body) == nil)
        // And neither is anything else that arrives on the channel.
        #expect(
            SupabaseMatchInviteChannel.invite(
                fromBroadcast: ["type": "broadcast", "payload": .object(["hello": "world"])])
                == nil)
        #expect(SupabaseMatchInviteChannel.invite(fromBroadcast: [:]) == nil)
    }

    @Test("The topic is the recipient's id, lowercased, and nobody else's")
    func topicNamesTheRecipient() {
        let one = UUID()
        let two = UUID()
        #expect(SupabaseMatchInviteChannel.topic(for: one)
            == "invites:\(one.uuidString.lowercased())")
        #expect(SupabaseMatchInviteChannel.topic(for: one)
            != SupabaseMatchInviteChannel.topic(for: two))
        #expect(!SupabaseMatchInviteChannel.topic(for: one).contains(one.uuidString.uppercased()))
    }

    /// A source fence over the one line that cannot be asserted twice: the
    /// `payload` hop above proves the decode works, and this proves it is still
    /// reading the nested object rather than having been "simplified" back to
    /// the top level by something that made the test above pass by accident.
    @Test("The decode still reaches through `payload`")
    func theDecodeStillReachesThroughPayload() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Cases
            .deletingLastPathComponent()   // OnlineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Willagrams/Online/SupabaseMatchInviteChannel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("message[\"payload\"]"), "the payload hop is gone")
        #expect(source.contains("onBroadcast(event: Self.inviteEvent)"))
    }
}
