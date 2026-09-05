import Foundation
import Testing
@testable import Friends
@testable import Match

/// Adding a friend by the code they gave you.
///
/// Every case drives `FriendsModel`. The clamp is never asserted on its own: a
/// pure function that normalizes correctly says nothing about whether the screen
/// that types into it ever calls it.
@MainActor
@Suite("Friends by code")
struct FriendsLookupTests {

    /// A fixture wrapped in the counting double, so "no call was made" is a
    /// thing a test can actually see.
    static func counting() async throws -> (FriendsFixture, GatedBackend, FriendsModel) {
        let f = try await FriendsFixture.make()
        let backend = GatedBackend(inner: f.backend)
        return (f, backend, FriendsModel(me: f.me, backend: backend))
    }

    // MARK: - done when: a seeded code publishes that profile

    @Test("Looking up a seeded friend code publishes that player")
    func lookupPublishesTheProfile() async throws {
        let (f, backend, model) = try await Self.counting()

        await model.lookup(code: f.friend.friendCode)

        #expect(model.lookupResult == f.friend)
        #expect(model.message == nil)
        #expect(await backend.friendCodeLookups == [f.friend.friendCode])
    }

    @Test("A code typed in lower case, spaced and over-long still finds the player")
    func lookupNormalizesWhatWasTyped() async throws {
        let (f, backend, model) = try await Self.counting()

        // Lower case, punctuation, and two characters past the end. The backend
        // matches the stored code exactly, so anything but the clamp misses.
        await model.lookup(code: " \(f.friend.friendCode.lowercased())-xy ")

        #expect(model.lookupResult == f.friend)
        #expect(await backend.friendCodeLookups == [f.friend.friendCode])
    }

    @Test("The field clamps to eight code characters and gates the lookup")
    func fieldClampsAndGates() async throws {
        let (_, _, model) = try await Self.counting()

        model.setLookupCode("ab-3d")
        #expect(model.lookupCode == "AB3D")
        #expect(!model.canLookup, "four characters is not a friend code")

        model.setLookupCode("ab-3d ef 9 zzz")
        #expect(model.lookupCode == "AB3DEF9Z")
        #expect(model.canLookup)
    }

    @Test("A code that is too short is refused without a call")
    func shortCodeMakesNoCall() async throws {
        let (_, backend, model) = try await Self.counting()

        await model.lookup(code: "AB3")

        #expect(model.lookupResult == nil)
        #expect(model.message == FriendsModel.codeLengthMessage)
        #expect(await backend.friendCodeLookups.isEmpty)
    }

    @Test("A code nobody has publishes no result and says so")
    func unknownCodeSaysSo() async throws {
        let (_, _, model) = try await Self.counting()

        await model.lookup(code: "ZZZZZZZZ")

        #expect(model.lookupResult == nil)
        #expect(model.message == FriendsModel.noSuchCodeMessage)
    }

    // MARK: - done when: requesting the looked-up player makes a pending row

    @Test("Requesting a looked-up player puts a pending row in the outgoing section")
    func requestCreatesAnOutgoingRow() async throws {
        let (f, backend, model) = try await Self.counting()

        // Somebody with no row against `me` yet: everyone in the fixture already
        // has one, and an existing row is what `.alreadyExists` covers below.
        let stranger = try await f.backend.signIn("stranger")
        _ = try await f.backend.signIn("me")

        await model.load()
        #expect(!model.outgoing.contains { $0.profile.id == stranger.id })

        await model.lookup(code: stranger.friendCode)
        let found = try #require(model.lookupResult)
        await model.request(found)

        let row = try #require(
            model.outgoing.first { $0.profile.id == stranger.id },
            "the request never reached the outgoing section"
        )
        #expect(row.friendship.status == .pending)
        #expect(row.friendship.requesterID == f.me.id)
        #expect(await backend.requestCalls == [stranger.id])
        // The row is cleared only on success, so the field is empty again.
        #expect(model.lookupResult == nil)
        #expect(model.lookupCode.isEmpty)
    }

    // MARK: - done when: the player's own code is refused with no backend call

    @Test("Looking up the player's own code refuses and makes no backend call")
    func ownCodeIsRefusedWithoutACall() async throws {
        let (f, backend, model) = try await Self.counting()

        await model.lookup(code: f.me.friendCode)

        #expect(model.lookupResult == nil)
        #expect(model.message == FriendsModel.ownCodeMessage)
        #expect(
            await backend.friendCodeLookups.isEmpty,
            "the model asked the backend who owns a code it already holds"
        )
    }

    @Test("Requesting the player themself refuses and makes no backend call")
    func requestingYourselfIsRefusedWithoutACall() async throws {
        let (f, backend, model) = try await Self.counting()

        await model.request(f.me)

        #expect(model.message == FriendsModel.ownCodeMessage)
        #expect(await backend.requestCalls.isEmpty)
        #expect(!model.outgoing.contains { $0.profile.id == f.me.id })
    }

    // MARK: - guardrail: an overtaken lookup publishes nothing

    @Test("An overtaken lookup does not put its result over the newer one's")
    func overtakenLookupPublishesNothing() async throws {
        let f = try await FriendsFixture.make()
        let gate = Gate()
        let backend = GatedBackend(inner: f.backend, lookupGate: gate)
        let model = FriendsModel(me: f.me, backend: backend)

        // Two lookups in flight at once, the second for a different player.
        let first = Task { await model.lookup(code: f.friend.friendCode) }
        await gate.waitForArrivals(1)
        let second = Task { await model.lookup(code: f.asked.friendCode) }
        await gate.waitForArrivals(2)

        // Newer finishes first, then the older one is let go.
        await gate.release(1)
        await second.value
        await gate.release(0)
        await first.value

        #expect(model.lookupResult == f.asked, "the overtaken lookup published its stale result")
    }

    @Test("An overtaken lookup that fails does not put its error over the newer one's result")
    func overtakenFailingLookupPublishesNothing() async throws {
        let f = try await FriendsFixture.make()
        let gate = Gate()
        let backend = GatedBackend(inner: f.backend, lookupGate: gate)
        let model = FriendsModel(me: f.me, backend: backend)

        let first = Task { await model.lookup(code: f.friend.friendCode) }
        await gate.waitForArrivals(1)
        let second = Task { await model.lookup(code: f.asked.friendCode) }
        await gate.waitForArrivals(2)

        await gate.release(1)
        await second.value

        // Only the older, already-overtaken call fails.
        await backend.setLookupFailing(true)
        await gate.release(0)
        await first.value

        #expect(model.lookupResult == f.asked, "the failed older lookup cleared the newer result")
        #expect(model.message == nil, "the overtaken lookup stamped its error over a good result")
    }

    // MARK: - the two refusals with real copy

    @Test("A player already asked maps to one line, and the row stays up")
    func alreadyAskedSaysSo() async throws {
        let (f, _, model) = try await Self.counting()

        await model.lookup(code: f.asked.friendCode)
        let found = try #require(model.lookupResult)
        await model.request(found)

        #expect(model.message == FriendsModel.alreadyKnownMessage)
        #expect(model.lookupResult == found, "a refused request must not clear the row")
    }

    @Test("A blocked player maps to one line")
    func blockedSaysSo() async throws {
        let (f, _, model) = try await Self.counting()

        await model.lookup(code: f.blockedByMe.friendCode)
        let found = try #require(model.lookupResult)
        await model.request(found)

        #expect(model.message == FriendsModel.blockedMessage)
    }
}
