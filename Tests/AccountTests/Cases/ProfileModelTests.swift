import Foundation
import Testing
import WillagramsRules
@testable import Account
@testable import Match

/// The profile screen's model: the row it renders, the one field it can change,
/// and the clamp that keeps a bad name off the wire.
@MainActor
@Suite("Profile")
struct ProfileModelTests {

    struct Fixture {
        let backend: RecordingBackend
        let profile: Profile
        let model: ProfileModel
    }

    /// A signed-in player and their screen, editing on.
    static func make(isEditable: Bool = true) async throws -> Fixture {
        let fake = FakeBackend()
        let profile = try await fake.signInWithApple(idToken: "profile-owner", nonce: "n")
        let backend = RecordingBackend(inner: fake)
        return Fixture(
            backend: backend,
            profile: profile,
            model: ProfileModel(profile: profile, isEditable: isEditable, backend: backend)
        )
    }

    // MARK: - done when: saves a new name and re-reads it

    @Test("Saving a new name stores it and the screen shows what came back")
    func savingStoresAndRereads() async throws {
        let f = try await Self.make()
        #expect(f.model.draftName == f.profile.displayName)

        f.model.draftName = "Ada"
        #expect(f.model.canSave)
        await f.model.save()

        #expect(await f.backend.updateDisplayNameCalls == ["Ada"])
        #expect(f.model.profile.displayName == "Ada")
        #expect(f.model.draftName == "Ada")
        #expect(f.model.message == ProfileModel.savedMessage)
        #expect(f.model.isSaving == false)

        // Re-read through the backend, not off the model: the stored row moved,
        // not just the copy on screen.
        let stored = try await f.backend.profile(id: f.profile.id)
        #expect(stored.displayName == "Ada")

        // And a screen rebuilt from that row opens on it.
        let reopened = ProfileModel(profile: stored, isEditable: true, backend: f.backend)
        #expect(reopened.draftName == "Ada")
    }

    /// The edges are trimmed before the length is judged and before the row is
    /// written, so a name is never stored with the whitespace a keyboard added.
    @Test("The draft is trimmed before it is sent")
    func draftIsTrimmed() async throws {
        let f = try await Self.make()

        f.model.draftName = "  Grace  "
        await f.model.save()

        #expect(await f.backend.updateDisplayNameCalls == ["Grace"])
        #expect(f.model.profile.displayName == "Grace")
    }

    // MARK: - done when: a 25-character draft is refused before any call

    @Test("A 25-character draft is refused before the backend is called")
    func tooLongIsRefusedWithoutACall() async throws {
        let f = try await Self.make()
        let tooLong = String(repeating: "a", count: 25)
        #expect(tooLong.count == ProfileModel.nameLength.upperBound + 1)

        f.model.draftName = tooLong
        #expect(f.model.canSave == false)

        await f.model.save()

        // The negative side effect, read off a recorder rather than re-derived:
        // the call never happened.
        #expect(await f.backend.updateDisplayNameCalls.isEmpty)
        #expect(f.model.message == ProfileModel.nameLengthMessage)
        #expect(f.model.profile.displayName == f.profile.displayName)
        let stored = try await f.backend.profile(id: f.profile.id)
        #expect(stored.displayName == f.profile.displayName)
    }

    @Test("An empty draft is refused before the backend is called")
    func emptyIsRefusedWithoutACall() async throws {
        let f = try await Self.make()

        f.model.draftName = "   "
        #expect(f.model.canSave == false)
        await f.model.save()

        #expect(await f.backend.updateDisplayNameCalls.isEmpty)
        #expect(f.model.message == ProfileModel.nameLengthMessage)
    }

    /// The boundaries themselves, so the clamp is 1–24 and not 1–23 or 1–25.
    @Test("The clamp is exactly 1 through 24")
    func clampBoundaries() async throws {
        for length in [1, 24] {
            let f = try await Self.make()
            f.model.draftName = String(repeating: "x", count: length)
            #expect(f.model.canSave, "\(length) characters should be savable")
            await f.model.save()
            #expect(await f.backend.updateDisplayNameCalls.count == 1)
        }
    }

    // MARK: - guardrail: no stat is computed client-side

    @Test("The four stats are the row as read, and there is no fifth")
    func statsAreTheRowAsRead() throws {
        let row = Profile(
            id: UUID(),
            displayName: "Reader",
            friendCode: "ABCD1234",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            matchesPlayed: 7,
            matchesWon: 3,
            tilesPlaced: 214,
            fastestWinSeconds: 96
        )
        let model = ProfileModel(profile: row, isEditable: false)

        #expect(model.stats == [
            ProfileStat(label: ProfileModel.matchesPlayedLabel, value: "7"),
            ProfileStat(label: ProfileModel.matchesWonLabel, value: "3"),
            ProfileStat(label: ProfileModel.tilesPlacedLabel, value: "214"),
            ProfileStat(label: ProfileModel.fastestWinLabel, value: "96s"),
        ])
    }

    @Test("A player who has never won shows a placeholder, not a zero")
    func fastestWinIsAbsentUntilThereIsOne() throws {
        let row = Profile(
            id: UUID(),
            displayName: "New",
            friendCode: "ZZZZ0000",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let model = ProfileModel(profile: row, isEditable: false)
        #expect(model.stats.last?.value == ProfileModel.noValue)
        #expect(model.stats.map(\.value) == ["0", "0", "0", ProfileModel.noValue])
    }

    // MARK: - guardrail: the screen renders for any profile, read-only

    @Test("A read-only screen renders the row and never calls the backend")
    func readOnlyScreenSavesNothing() async throws {
        let f = try await Self.make(isEditable: false)

        #expect(f.model.canSave == false)
        f.model.draftName = "Somebody Else"
        await f.model.save()

        #expect(await f.backend.updateDisplayNameCalls.isEmpty)
        #expect(f.model.profile.displayName == f.profile.displayName)
        // Everything the screen shows is still there — read-only is a missing
        // field, not a missing screen.
        #expect(f.model.stats.count == 4)
        #expect(f.model.profile.friendCode == f.profile.friendCode)
    }

    /// Item 9 opens this screen for a friend, on a backend the viewer cannot
    /// write that friend's row through. Nothing about that case needs a backend
    /// at all.
    @Test("A profile that is nobody's local row renders with no backend")
    func rendersSomebodyElsesRow() async throws {
        let stranger = Profile(
            id: UUID(),
            displayName: "Stranger",
            friendCode: "QQQQ9999",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            matchesPlayed: 2,
            matchesWon: 1,
            tilesPlaced: 40
        )
        let model = ProfileModel(profile: stranger, isEditable: false)

        #expect(model.profile == stranger)
        #expect(model.stats.first?.value == "2")
        await model.save()
        #expect(model.message == nil, "a read-only screen has nothing to say about saving")
    }

    // MARK: - the friend code

    @Test("Copying puts the friend code, not the share sentence, on the clipboard")
    func copyingCopiesTheCode() throws {
        let f = ProfileModel(
            profile: Profile(
                id: UUID(),
                displayName: "Ada",
                friendCode: "ABCD1234",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            isEditable: true,
            pasteboard: { Pasteboard.shared.text = $0 }
        )

        #expect(f.didCopyCode == false)
        f.copyFriendCode()
        #expect(Pasteboard.shared.text == "ABCD1234")
        #expect(f.didCopyCode)

        // The share sheet sends the code with a sentence around it, so the
        // recipient knows what the eight characters are for.
        #expect(f.shareMessage.contains("ABCD1234"))
        #expect(f.shareMessage != "ABCD1234")
    }

    /// Somewhere for the injected clipboard closure to land. `UIPasteboard` is
    /// UIKit and this package builds for macOS, which is exactly why the closure
    /// is injected rather than called from `Willagrams/Account`.
    @MainActor
    final class Pasteboard {
        static let shared = Pasteboard()
        var text: String?
    }
}
