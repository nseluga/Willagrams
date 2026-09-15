import SwiftUI

/// One player's profile: their name, their friend code, and the four numbers
/// the database keeps for them.
///
/// It knows nothing about routes. The way out is the `onBack` closure its owner
/// hands it, exactly as `ScreenHeader` takes one — `Willagrams/Account` holds no
/// navigation and the shell owns every transition.
///
/// The same screen serves the local player and a friend: `isEditable` on the
/// model is the only difference, so the read-only case is this view with the
/// field left out rather than a second file.
///
/// Must stay listed in the `Account` target's `exclude:` in
/// `Tests/AccountTests/Package.swift` and in `Tests/ShellTests/Package.swift` —
/// `SourceGuardrailTests` says so in both.
struct ProfileView: View {

    let model: ProfileModel
    let onBack: () -> Void

    /// Tracks the name field so its container can be scrolled into view the
    /// moment the keyboard covers it — see `name`.
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            ScreenHeader(
                title: ProfileModel.title,
                backTitle: ProfileModel.backLabel,
                onBack: onBack
            )

            // The header stays put and the rest scrolls, as on `FriendsView`:
            // a phone in landscape is shorter than this screen, and Done must
            // never be the thing that scrolls away.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                        name
                            .id(Self.nameFieldID)

                        friendCode

                        stats
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: nameFieldFocused) { _, isFocused in
                    guard isFocused else { return }
                    withAnimation {
                        proxy.scrollTo(Self.nameFieldID, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenPadding()
        .background {
            LinearGradient(
                colors: [DesignTokens.Palette.canvasTop, DesignTokens.Palette.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// The one editable thing on the row, or just the name when it is somebody
    /// else's. `canSave` is the model's answer, not a length check repeated
    /// here.
    @ViewBuilder private var name: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text(ProfileModel.nameLabel).monoLabel()

            if model.isEditable {
                @Bindable var model = model
                HStack(spacing: DesignTokens.Space.m) {
                    TextField(ProfileModel.nameLabel, text: $model.draftName)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.title)
                        .foregroundStyle(DesignTokens.Palette.textPrimary)
                        .autocorrectionDisabled()
                        .focused($nameFieldFocused)

                    Button(ProfileModel.saveLabel) {
                        Task { await model.save() }
                    }
                    .buttonStyle(.brandQuiet)
                    .disabled(!model.canSave)
                }

                if let message = model.message {
                    Text(message)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(model.profile.displayName)
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
            }
        }
    }

    /// Monospaced for the same reason the invite code is: an O and a 0 are read
    /// off the glass by a person.
    private var friendCode: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text(ProfileModel.friendCodeLabel).monoLabel()

            HStack(spacing: DesignTokens.Space.m) {
                Text(model.profile.friendCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(DesignTokens.Palette.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityLabel(
                        Text(model.profile.friendCode.map(String.init).joined(separator: " "))
                    )

                Button(model.didCopyCode ? ProfileModel.copiedLabel : ProfileModel.copyLabel) {
                    model.copyFriendCode()
                }
                .buttonStyle(.brandQuiet)

                ShareLink(item: model.shareMessage) {
                    Label(ProfileModel.shareLabel, systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.brandQuiet)
            }
        }
    }

    /// The stats lane's row, over the model's four values. No number is worked
    /// out here — `stats` is the row as read.
    private var stats: some View {
        VStack(spacing: DesignTokens.Space.s) {
            ForEach(Array(model.stats.enumerated()), id: \.element) { index, stat in
                StatRow(
                    label: stat.label,
                    value: stat.value,
                    showsDivider: index < model.stats.count - 1
                )
            }
        }
    }

    private static let contentMaxWidth: CGFloat = 620
    private static let nameFieldID = "profile.nameField"
}
