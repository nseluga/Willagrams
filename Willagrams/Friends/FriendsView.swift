import SwiftUI

/// The friends list: who you play with, who has asked, and who you have asked.
///
/// It knows nothing about routes. The way out is the `onBack` closure its owner
/// hands it, exactly as `ProfileView` takes one — `Willagrams/Friends` holds no
/// navigation and the shell owns every transition.
///
/// Three sections, drawn from the three the model publishes. No filtering and no
/// status check happens here: a view that decided which section a row belonged
/// in would be a second copy of the rule `FriendsModel.load()` already owns.
///
/// Must stay listed in the `Friends` target's `exclude:` in
/// `Tests/FriendsTests/Package.swift` and in `Tests/ShellTests/Package.swift` —
/// `SourceGuardrailTests` says so in both.
struct FriendsView: View {

    let model: FriendsModel
    let onBack: () -> Void

    /// Where a tap on an accepted friend goes. The screen reports it and the
    /// shell decides what it means, exactly as `onBack` works.
    let onOpen: (FriendEntry) -> Void

    /// The code field, written through the model so the `A–Z0–9` clamp is the
    /// model's one rule rather than a second copy of it here.
    private var code: Binding<String> {
        Binding(get: { model.lookupCode }, set: { model.setLookupCode($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            ScreenHeader(
                title: FriendsModel.title,
                backTitle: FriendsModel.backLabel,
                onBack: onBack
            )

            if let message = model.message {
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                    addByCode

                    // Requests first: the only rows on this screen that are
                    // waiting on the player are the ones they can answer.
                    section(FriendsModel.incomingSectionTitle, model.incoming) { entry in
                        Button(FriendsModel.acceptLabel) {
                            Task { await model.accept(entry) }
                        }
                        .buttonStyle(.brandPrimary)

                        Button(FriendsModel.declineLabel) {
                            Task { await model.decline(entry) }
                        }
                        .buttonStyle(.brandQuiet)
                    }

                    // Said before the tap, not after it: a decline is a block at
                    // the seam and nothing on this screen takes one back.
                    if !model.incoming.isEmpty {
                        Text(FriendsModel.declineFootnote)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section(
                        FriendsModel.acceptedSectionTitle,
                        model.accepted,
                        onOpen: onOpen
                    ) { entry in
                        Button(FriendsModel.blockLabel) {
                            Task { await model.block(entry) }
                        }
                        .buttonStyle(.brandQuiet)
                    }

                    // Nothing to do to a request nobody has answered — it is
                    // here so the player knows it was sent, not so they can
                    // poke it.
                    section(FriendsModel.outgoingSectionTitle, model.outgoing) { _ in }

                    if model.isEmpty && !model.isLoading {
                        Text(FriendsModel.emptyMessage)
                            .font(DesignTokens.Typography.body)
                            .foregroundStyle(DesignTokens.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Space.xl)
        .background {
            LinearGradient(
                colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .task { await model.load() }
    }

    /// Adding a friend by the code they gave you. One field and one button, plus
    /// the row the lookup found — every decision on it (is the code long enough,
    /// is it mine, did it match anyone) is the model's.
    @ViewBuilder private var addByCode: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text(FriendsModel.addSectionTitle).monoLabel()

            HStack(spacing: DesignTokens.Space.m) {
                TextField(FriendsModel.codeFieldPrompt, text: code)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityLabel(FriendsModel.codeFieldLabel)

                Button(FriendsModel.lookupLabel) {
                    Task { await model.lookup(code: model.lookupCode) }
                }
                .buttonStyle(.brandQuiet)
                .disabled(!model.canLookup || model.isLoading)
            }

            if let found = model.lookupResult {
                HStack(spacing: DesignTokens.Space.m) {
                    Text(found.displayName)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Palette.textPrimary)

                    Spacer(minLength: DesignTokens.Space.m)

                    Button(FriendsModel.requestLabel) {
                        Task { await model.request(found) }
                    }
                    .buttonStyle(.brandPrimary)
                }
                .disabled(model.isLoading)
            }
        }
    }

    /// One titled section, or nothing at all when it is empty — an empty heading
    /// is a promise of rows that are not there.
    @ViewBuilder private func section<Actions: View>(
        _ title: String,
        _ entries: [FriendEntry],
        onOpen: ((FriendEntry) -> Void)? = nil,
        @ViewBuilder actions: @escaping (FriendEntry) -> Actions
    ) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
                Text(title).monoLabel()

                ForEach(entries) { entry in
                    HStack(spacing: DesignTokens.Space.m) {
                        if let onOpen {
                            Button { onOpen(entry) } label: {
                                Text(entry.profile.displayName)
                                    .font(DesignTokens.Typography.body)
                                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(entry.profile.displayName)
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(DesignTokens.Palette.textPrimary)
                        }

                        Spacer(minLength: DesignTokens.Space.m)

                        actions(entry)
                    }
                    .disabled(model.isLoading)
                }
            }
        }
    }

    private static let contentMaxWidth: CGFloat = 620
}
