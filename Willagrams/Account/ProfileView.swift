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
    /// moment the keyboard covers it — see `nameCard`.
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            header

            // The header stays put and the rest scrolls, as on `FriendsView`:
            // a phone in landscape is shorter than this screen, and Done must
            // never be the thing that scrolls away.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                        nameCard
                            .id(Self.nameFieldID)

                        stats

                        winRate

                        friendCode
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

    /// The comp's top bar: a small mono kicker where the other screens carry a
    /// title, and Done at the far edge — the same `onBack` every screen reports
    /// through, just drawn to this screen's own layout rather than the shared
    /// `ScreenHeader` (which other screens still use unchanged).
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.m) {
            Text(ProfileModel.title.uppercased())
                .monoLabel()
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: DesignTokens.Space.m)

            doneButton(onBack: onBack)
        }
    }

    /// Named so the call site reads `onBack: onBack` — the same closure every
    /// screen takes and hands straight to its way out, not a route this view
    /// picked for itself.
    private func doneButton(onBack: @escaping () -> Void) -> some View {
        Button(ProfileModel.backLabel, action: onBack)
            .buttonStyle(.brandText)
    }

    /// The avatar, the name, the code beneath it, and — for the signed-in
    /// player — the field and Save button. `canSave` is the model's answer,
    /// not a length check repeated here.
    @ViewBuilder private var nameCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            HStack(spacing: DesignTokens.Space.m) {
                avatar

                VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                    if model.isEditable {
                        @Bindable var model = model
                        TextField(ProfileModel.nameLabel, text: $model.draftName)
                            .textFieldStyle(.plain)
                            .font(DesignTokens.Typography.title)
                            .foregroundStyle(DesignTokens.Palette.textPrimary)
                            .autocorrectionDisabled()
                            .focused($nameFieldFocused)
                            .onSubmit {
                                guard model.canSave else { return }
                                Task { await model.save() }
                            }
                    } else {
                        Text(model.profile.displayName)
                            .font(DesignTokens.Typography.title)
                            .foregroundStyle(DesignTokens.Palette.textPrimary)
                    }

                    Text(model.profile.friendCode)
                        .font(DesignTokens.Typography.monoLabel)
                        .tracking(DesignTokens.Typography.monoLabelTracking)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                }
            }

            if model.isEditable {
                Button(ProfileModel.saveLabel) {
                    Task { await model.save() }
                }
                .buttonStyle(.brandPrimary)
                .frame(maxWidth: .infinity)
                .disabled(!model.canSave)

                if let message = model.message {
                    Text(message)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DesignTokens.Space.l)
        .brandCard()
    }

    /// The accent tile carrying the display name's first letter — the comp's
    /// one splash of color on an otherwise ink-on-ink screen.
    private var avatar: some View {
        Text(avatarInitial)
            .font(DesignTokens.Typography.title)
            .foregroundStyle(DesignTokens.Palette.onAccent)
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .background(DesignTokens.Palette.accent)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.tile, style: .continuous))
            .accessibilityHidden(true)
    }

    private var avatarInitial: String {
        let trimmed = model.profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : String(trimmed.prefix(1)).uppercased()
    }

    /// Three cards over the model's own numbers, plus the fastest win as its
    /// own row underneath — the comp's grid only has room for three, and the
    /// fourth value the model already tracks does not get dropped for it.
    private var stats: some View {
        VStack(spacing: DesignTokens.Space.m) {
            LazyVGrid(columns: Self.statColumns, spacing: DesignTokens.Space.s) {
                ForEach(Array(model.stats.prefix(3).enumerated()), id: \.element) { _, stat in
                    statCard(stat)
                }
            }

            if let fastestWin = model.stats.last {
                StatRow(label: fastestWin.label, value: fastestWin.value, showsDivider: false)
                    .padding(DesignTokens.Space.l)
                    .brandCard()
            }
        }
    }

    private func statCard(_ stat: ProfileStat) -> some View {
        VStack(spacing: DesignTokens.Space.s) {
            Text(stat.value)
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Palette.textPrimary)

            Text(stat.label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Space.m)
        .brandCard()
        .accessibilityElement(children: .combine)
    }

    /// Won ÷ played, as a bar and a whole percent — both read off
    /// `model.winRatePercent`, never worked out again here. Absent entirely
    /// before anything has been played, per the model's own `nil`.
    @ViewBuilder private var winRate: some View {
        if let percent = model.winRatePercent {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
                HStack {
                    Text(ProfileModel.winRateLabel).monoLabel()

                    Spacer(minLength: DesignTokens.Space.m)

                    Text("\(percent)%")
                        .font(DesignTokens.Typography.button)
                        .foregroundStyle(DesignTokens.Palette.accent)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DesignTokens.Palette.hairline)
                        Capsule()
                            .fill(DesignTokens.Palette.accent)
                            .frame(width: geometry.size.width * CGFloat(percent) / 100)
                    }
                }
                .frame(height: DesignTokens.Space.s)
            }
            .padding(DesignTokens.Space.l)
            .brandCard()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ProfileModel.winRateLabel)
            .accessibilityValue("\(percent)%")
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
        .padding(DesignTokens.Space.l)
        .brandCard()
    }

    private static let contentMaxWidth: CGFloat = 620
    private static let nameFieldID = "profile.nameField"
    private static let avatarSize: CGFloat = 64
    private static let statColumns = [
        GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
    ]
}
