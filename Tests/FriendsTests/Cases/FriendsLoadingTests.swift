import Foundation
import Observation
import Testing
@testable import Friends
@testable import Match

/// What the model does *while* it is loading, and what two overlapping loads do
/// to each other.
///
/// Every case here drives the model against a backend that really withholds its
/// answer. A double that answers immediately would make all of this vacuous: the
/// load is over before the assertion runs, so "the spinner is up" and "the older
/// load lost the race" would both pass against a model that did neither.
@MainActor
@Suite("Friends loading")
struct FriendsLoadingTests {

    @Test("isLoading is true while the load is still in flight")
    func loadingIsTrueMidFlight() async throws {
        let f = try await FriendsFixture.make()
        let gate = Gate()
        let backend = GatedBackend(inner: f.backend, friendshipsGate: gate)
        let model = FriendsModel(me: f.me, backend: backend)

        #expect(!model.isLoading)
        let load = Task { await model.load() }
        await gate.waitForArrivals(1)
        #expect(model.isLoading, "the spinner must be up while the read is parked")

        await gate.open()
        await load.value
        #expect(!model.isLoading)
    }

    /// The view disables every row on `isLoading`, so a spinner that goes down
    /// between an action and its reload re-arms the buttons mid-write.
    @Test("An action holds the spinner across its own write")
    func actionsHoldTheSpinner() async throws {
        let f = try await FriendsFixture.make()
        let gate = Gate()
        let backend = GatedBackend(inner: f.backend, writeGate: gate)
        let model = FriendsModel(me: f.me, backend: backend)
        await model.load()
        #expect(!model.isLoading)

        let request = try #require(model.incoming.first)
        let action = Task { await model.accept(request) }
        await gate.waitForArrivals(1)
        #expect(model.isLoading, "the spinner must be up while the write is parked")

        await gate.open()
        await action.value
        #expect(!model.isLoading)
    }

    /// Two loads overlap the moment the view's `.task` and an action's reload
    /// meet. The newer one owns the screen whichever order they finish in, and
    /// the spinner belongs to whichever is still running.
    @Test("An overtaken load publishes nothing, and does not put the spinner away")
    func theNewerLoadWins() async throws {
        let f = try await FriendsFixture.make()
        let gate = Gate()
        let backend = GatedBackend(inner: f.backend, friendshipsGate: gate)
        let model = FriendsModel(me: f.me, backend: backend)

        // The first load reads the rows as they are now, then parks holding them.
        let first = Task { await model.load() }
        await gate.waitForArrivals(1)

        // The database moves on underneath it.
        _ = try await f.backend.respondToFriendRequest(requesterID: f.asker.id, accept: true)

        let second = Task { await model.load() }
        await gate.waitForArrivals(2)

        // The newer read finishes first; the older one is still running.
        await gate.release(1)
        await second.value
        #expect(model.accepted.contains { $0.profile.id == f.asker.id })
        #expect(model.isLoading, "a load that is still running keeps the spinner up")

        await gate.release(0)
        await first.value
        #expect(
            model.accepted.contains { $0.profile.id == f.asker.id },
            "the overtaken load must not put its stale sections on screen"
        )
        #expect(!model.isLoading)
    }

    /// The failure branch of a load is a publish too — of a message. An older
    /// load whose read blips must not stamp "Couldn't load your friends" over a
    /// screen the newer load just filled correctly.
    @Test("An overtaken load that fails does not put its error over the newer one's sections")
    func theOvertakenLoadsFailureIsNotShown() async throws {
        let f = try await FriendsFixture.make()
        let gate = Gate()
        let backend = GatedBackend(inner: f.backend, friendshipsGate: gate)
        let model = FriendsModel(me: f.me, backend: backend)

        let first = Task { await model.load() }
        await gate.waitForArrivals(1)

        // The database moves on, then the newer load reads it and parks too.
        _ = try await f.backend.respondToFriendRequest(requesterID: f.asker.id, accept: true)
        let second = Task { await model.load() }
        await gate.waitForArrivals(2)

        // The newer one finishes first and owns the screen.
        await gate.release(1)
        await second.value
        #expect(model.accepted.contains { $0.profile.id == f.asker.id })
        #expect(model.message == nil)

        // Only the older, already-overtaken read fails.
        await backend.setFriendshipsFailing(true)
        await gate.release(0)
        await first.value

        #expect(
            model.message == nil,
            "the overtaken load's failure clobbered the newer load's screen with an error"
        )
        #expect(
            model.accepted.contains { $0.profile.id == f.asker.id },
            "the sections the newer load published must still be on screen"
        )
        #expect(!model.isLoading)
    }

    @Test("A cancelled load does not assign its rows over the sections")
    func cancelledLoadsPublishNothing() async throws {
        let f = try await FriendsFixture.make()
        let gate = Gate()
        let backend = GatedBackend(inner: f.backend, friendshipsGate: gate)
        let model = FriendsModel(me: f.me, backend: backend)

        let first = Task { await model.load() }
        await gate.waitForArrivals(1)
        await gate.release()
        await first.value
        #expect(!model.accepted.contains { $0.profile.id == f.asker.id }, "the state before")

        _ = try await f.backend.respondToFriendRequest(requesterID: f.asker.id, accept: true)
        let cancelled = Task { await model.load() }
        await gate.waitForArrivals(2)
        cancelled.cancel()
        await gate.release()
        await cancelled.value

        #expect(
            !model.accepted.contains { $0.profile.id == f.asker.id },
            "a cancelled load's rows may be truncated and must not be published"
        )
        #expect(!model.isLoading)
    }

    // MARK: - How many reads a load costs

    @Test("Each counterpart is read once, and an action re-reads none of them")
    func profilesAreReadOnceAndKept() async throws {
        let f = try await FriendsFixture.make()
        let backend = GatedBackend(inner: f.backend)
        let model = FriendsModel(me: f.me, backend: backend)
        await model.load()

        let afterLoad = await backend.profileCalls
        #expect(Set(afterLoad).count == afterLoad.count, "a counterpart must not be read twice")
        #expect(
            Set(afterLoad) == [f.friend.id, f.asker.id, f.asked.id],
            "exactly the counterparts that are shown, and no blocked one"
        )

        await model.accept(try #require(model.incoming.first))
        #expect(
            await backend.profileCalls.count == afterLoad.count,
            "an action must not re-read every profile on the screen"
        )
    }

    /// Serial resolution parks the first read and never reaches the third, so
    /// the count below is polled with a ceiling rather than awaited: waiting on
    /// an arrival that will never come hangs the suite instead of failing it.
    @Test("Counterpart profiles are read at the same time")
    func profilesAreReadTogether() async throws {
        let f = try await FriendsFixture.make()
        let gate = Gate()
        let backend = GatedBackend(inner: f.backend, profileGate: gate)
        let model = FriendsModel(me: f.me, backend: backend)

        let load = Task { await model.load() }
        var parked = 0
        for _ in 0..<200 where parked < 3 {
            parked = await gate.arrivalCount
            if parked < 3 { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(parked == 3, "all three counterparts must be in flight at once")

        await gate.open()
        await load.value

        #expect(model.accepted.map(\.profile.id) == [f.friend.id])
    }

    // MARK: - A read that fails for one row only

    @Test("A counterpart whose profile refuses is dropped and said out loud")
    func partialLoadsSaySo() async throws {
        let f = try await FriendsFixture.make()
        let backend = GatedBackend(inner: f.backend, failingProfiles: [f.friend.id])
        let model = FriendsModel(me: f.me, backend: backend)
        await model.load()

        #expect(model.accepted.isEmpty, "the unreadable row is dropped")
        #expect(model.incoming.map(\.profile.id) == [f.asker.id], "the readable ones still arrive")
        #expect(
            model.message == FriendsModel.partialLoadMessage,
            "a friend that silently vanishes is worse than a slow list"
        )
    }

    // MARK: - Identity and copy

    @Test("Two rows for the same counterpart are two entries")
    func entriesAreIdentifiedByTheirRow() async throws {
        let f = try await FriendsFixture.make()
        let one = FriendEntry(
            profile: f.friend,
            friendship: Friendship(
                requesterID: f.me.id,
                addresseeID: f.friend.id,
                status: .pending,
                createdAt: .distantPast
            )
        )
        let other = FriendEntry(
            profile: f.friend,
            friendship: Friendship(
                requesterID: f.friend.id,
                addresseeID: f.me.id,
                status: .pending,
                createdAt: .distantPast
            )
        )
        #expect(one.id != other.id, "two rows collapsing to one id would drop a row from the list")
    }

    /// Declining calls `respondToFriendRequest(accept: false)`, which the seam
    /// answers with a block that nothing on this screen can take back. The
    /// button has to say so before it is tapped.
    @Test("The decline button says that it blocks")
    func declineSaysItBlocks() {
        #expect(FriendsModel.declineLabel.lowercased().contains("block"))
        #expect(FriendsModel.declineFootnote.lowercased().contains("block"))
        #expect(FriendsModel.declineFootnote.lowercased().contains("undone"))
    }
}

// MARK: - Watching the spinner between two synchronous statements

/// The values `isLoading` held, in order.
@MainActor
final class LoadingLog {
    var values: [Bool] = []
}

/// Records every assignment to `isLoading`, re-arming inside `onChange`.
///
/// `onChange` runs in `willSet`, so what it reads is the value *before* the
/// write — the log is the history shifted by one, which is what makes a value
/// the model held only between two synchronous statements visible at all. An
/// after-the-fact `#expect(model.isLoading)` cannot see it: no other task can
/// run between `end()` and `begin()` on the same actor.
@MainActor
func trackLoading(_ model: FriendsModel, into log: LoadingLog) {
    withObservationTracking {
        _ = model.isLoading
    } onChange: {
        MainActor.assumeIsolated {
            log.values.append(model.isLoading)
            trackLoading(model, into: log)
        }
    }
}

@MainActor
@Suite("Friends spinner continuity")
struct FriendsSpinnerTests {

    /// The seam the MINOR fix exists to close: the write finishes, the reload
    /// starts, and the spinner must not blink off in between. Both gates are
    /// armed so the action is observed *across* that seam and not only on
    /// either side of it.
    @Test("The spinner never drops between an action's write and its reload")
    func spinnerSurvivesTheWriteReloadSeam() async throws {
        let f = try await FriendsFixture.make()
        let writes = Gate()
        let reads = Gate()
        let backend = GatedBackend(inner: f.backend, friendshipsGate: reads, writeGate: writes)
        let model = FriendsModel(me: f.me, backend: backend)

        // The opening load, let through one read at a time so the gate stays
        // shut for the reload the action triggers.
        let initial = Task { await model.load() }
        await reads.waitForArrivals(1)
        await reads.release()
        await initial.value
        #expect(!model.isLoading)

        let request = try #require(model.incoming.first)
        let log = LoadingLog()
        trackLoading(model, into: log)

        let action = Task { await model.accept(request) }
        await writes.waitForArrivals(1)
        #expect(model.isLoading, "the spinner is up while the write is parked")

        await writes.release()
        await reads.waitForArrivals(2)
        #expect(model.isLoading, "the spinner is up while the reload is parked")

        await reads.release()
        await action.value
        #expect(!model.isLoading)

        // The first entry is the value before the action began. Everything
        // after it is a value the screen actually showed mid-action, and a
        // `false` in there is the spinner blinking off under the buttons.
        #expect(
            !log.values.dropFirst().contains(false),
            "the spinner dropped mid-action: \(log.values)"
        )
    }

    @Test("The spinner goes down after an action that fails")
    func failedActionsPutTheSpinnerAway() async throws {
        let f = try await FriendsFixture.make()
        let model = FriendsModel(me: f.me, backend: f.backend)
        await model.load()
        let request = try #require(model.incoming.first)

        // Nobody signed in: the write throws before the reload is reached.
        try await f.backend.signOut()
        await model.accept(request)

        #expect(model.message == FriendsModel.acceptFailedMessage)
        #expect(!model.isLoading, "an action that fails must still put the spinner away")
    }
}
