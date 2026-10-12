import SwiftUI

/// Settings › Codex (Codex spec §4.3): the login Codex uses now, the
/// remembered logins and their links, automatic switching behind the
/// configuration acknowledgement (§4.2), the running-sessions line, privacy
/// (§4.7). Claude Code's pane, section by section.
struct CodexDetailView: View {
    @ObservedObject var model: CodexModel
    @State private var remembering = false
    @State private var confirmingForgetAll = false

    var body: some View {
        Form {
            if let status = model.state.status {
                Section { statusRow(status) } header: { Text(LocalizedStringResource.codexSettingsStatusHeader) }
            }
            Section { nowRows } header: { Text(LocalizedStringResource.codexSettingsNowHeader) }
            Section { rememberedRows } header: { Text(LocalizedStringResource.codexSettingsRememberedHeader) }
            Section { automaticRows } header: { Text(LocalizedStringResource.codexSettingsAutoHeader) }
            Section {
                Toggle(isOn: Binding(get: { model.state.notify }, set: { on in Task { await model.setNotify(on) } })) {
                    Text(LocalizedStringResource.codexSettingsNotify)
                }
                .accessibilityIdentifier("codexNotifyToggle")
                Text(LocalizedStringResource.codexSettingsRestart)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
                    .accessibilityIdentifier("codexRestartLine")
                Text(LocalizedStringResource.codexSettingsPrivacy)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
                Button(role: .destructive) { confirmingForgetAll = true } label: {
                    Text(LocalizedStringResource.codexSettingsForgetAll)
                }
                .disabled(model.remembered.isEmpty || model.isSwitching || forgetBlocked)
                .accessibilityIdentifier("codexForgetAllButton")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $remembering) {
            CodexRememberSheet(model: model) { remembering = false }
        }
        .confirmationDialog(Text(LocalizedStringResource.codexSettingsForgetAllConfirm), isPresented: $confirmingForgetAll) {
            Button(role: .destructive) { Task { await model.forgetAll() } } label: {
                Text(LocalizedStringResource.codexSettingsForgetAll)
            }
        } message: {
            Text(LocalizedStringResource.codexSettingsForgetAllMessage)
        }
    }

    /// A switch needs attention: the model refuses Switch and Forget until
    /// Resume finds the journal resolved (spec §4.1).
    private var forgetBlocked: Bool { Self.forgetBlocked(model.state.status) }

    // MARK: Codex now

    @ViewBuilder
    private var nowRows: some View {
        if let current = model.current {
            LabeledContent {
                if model.remembered.contains(where: { $0.id == current.id }) {
                    HStack(spacing: 10) {
                        Text(LocalizedStringResource.codexSettingsNowRemembered)
                            .foregroundStyle(Theme.creamDim)
                        // After signing in to it again in Codex (the stale
                        // hint's way out): a fresh copy, its link kept.
                        Button {
                            Task { await model.rememberCurrent(linkTo: model.state.links[current.id]) }
                        } label: {
                            Text(LocalizedStringResource.codexSettingsNowRememberAgain)
                        }
                        .disabled(model.isSwitching)
                        .accessibilityIdentifier("codexRememberAgainButton")
                    }
                } else {
                    Button { remembering = true } label: { Text(LocalizedStringResource.codexSettingsNowRemember) }
                        .disabled(model.isSwitching)
                        .accessibilityIdentifier("codexRememberButton")
                }
            } label: {
                Self.loginLabel(current)
            }
        } else {
            Text(LocalizedStringResource.codexSettingsNowNone)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
                .accessibilityIdentifier("codexNowNone")
        }
        if let error = model.lastError {
            Text(Self.message(for: error))
                .font(Theme.mono(12))
                .foregroundStyle(Theme.warn)
                .accessibilityIdentifier("codexError")
        }
    }

    /// The login's email (else its id) over its plan. Plain text: an email
    /// must not turn into a mail link.
    static func loginLabel(_ login: CodexLogin) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: login.email ?? login.id)
                .lineLimit(1)
                .truncationMode(.middle)
            if let plan = planName(login.planType) {
                Text(verbatim: plan)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.creamDim)
            }
        }
    }

    // MARK: Remembered sign-ins

    @ViewBuilder
    private var rememberedRows: some View {
        if model.signIns.isEmpty {
            Text(LocalizedStringResource.codexSettingsRememberedEmpty)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
        } else if forgetBlocked {
            Text(LocalizedStringResource.codexSettingsForgetBlocked)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.warn)
                .accessibilityIdentifier("codexForgetBlocked")
        }
        ForEach(model.signIns) { signIn in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Self.loginLabel(signIn.login)
                    if signIn.id == model.current?.id {
                        Text(LocalizedStringResource.codexSettingsCurrentTag)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.codex)
                            .padding(.horizontal, 5)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.codex.opacity(0.55), lineWidth: 1))
                    }
                    Spacer(minLength: 8)
                    if signIn.id != model.current?.id, let accountID = signIn.linkedAccountID {
                        Button { Task { await model.useInCodex(accountID: accountID) } } label: {
                            Text(LocalizedStringResource.codexSettingsSwitch)
                        }
                        .disabled(model.isSwitching || forgetBlocked)
                        .accessibilityIdentifier("codexSwitchButton")
                    }
                    Button(role: .destructive) { Task { await model.forget(signIn.id) } } label: {
                        Text(LocalizedStringResource.codexSettingsForget)
                    }
                    .disabled(model.isSwitching || forgetBlocked)
                    .accessibilityIdentifier("codexForgetButton")
                }
                Picker(selection: Binding(
                    get: { signIn.linkedAccountID },
                    set: { id in Task { await model.link(signIn.id, to: id) } }
                )) {
                    Text(LocalizedStringResource.codexSettingsLinkNone).tag(UUID?.none)
                    ForEach(model.candidates, id: \.accountID) { candidate in
                        Text(verbatim: candidate.label).tag(UUID?.some(candidate.accountID))
                    }
                } label: {
                    Text(LocalizedStringResource.codexSettingsLinkLabel)
                }
                if signIn.linkedAccountID != nil {
                    Text(signIn.verified ? LocalizedStringResource.codexSettingsLinkVerified : .codexSettingsLinkChosen)
                        .font(Theme.mono(11))
                        .foregroundStyle(signIn.verified ? Theme.active : Theme.creamFaint)
                        .accessibilityIdentifier(signIn.verified ? "codexLinkVerified" : "codexLinkChosen")
                }
                if signIn.validityUnknown {
                    Text(LocalizedStringResource.codexSettingsLinkValidityUnknown)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("codexValidityUnknown")
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Switch automatically

    @ViewBuilder
    private var automaticRows: some View {
        Toggle(isOn: Binding(
            get: { model.state.configurationAcknowledged },
            set: { on in Task { await model.setConfigurationAcknowledged(on) } }
        )) {
            Text(LocalizedStringResource.codexSettingsAutoAcknowledge)
        }
        .accessibilityIdentifier("codexAcknowledgeToggle")
        Toggle(isOn: Binding(
            get: { model.state.autoSwitchEnabled },
            set: { on in Task { await model.setAutoSwitch(enabled: on, rule: model.state.rule) } }
        )) {
            Text(LocalizedStringResource.codexSettingsAutoToggle)
        }
        .disabled(!model.state.configurationAcknowledged)
        .accessibilityIdentifier("codexAutoToggle")
        if !model.state.configurationAcknowledged {
            Text(LocalizedStringResource.codexSettingsAutoNeedsAcknowledge)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
                .accessibilityIdentifier("codexNeedsAcknowledge")
        }
        // The weekly limit only (spec §4.5): no limit picker.
        Stepper(value: Binding(
            get: { model.state.rule.percent },
            set: { percent in
                var rule = model.state.rule
                rule.percent = percent
                Task { await model.setAutoSwitch(enabled: model.state.autoSwitchEnabled, rule: rule) }
            }
        ), in: Self.percentRange) {
            LabeledContent {
                Text(LocalizedStringResource.codexSettingsAutoPercent(model.state.rule.percent))
                    .font(Theme.mono(13))
            } label: {
                Text(LocalizedStringResource.codexSettingsAutoThreshold)
            }
        }
        .accessibilityIdentifier("codexPercentStepper")
        Text(LocalizedStringResource.codexSettingsAutoExplain)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.creamDim)
        if model.stateSaveFailed {
            Text(LocalizedStringResource.codexSettingsSaveFailed)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.warn)
        }
        // Resume is also the way out of needs-attention, which pauses nothing
        // by itself but blocks every switch.
        if model.state.autoSwitchPaused || forgetBlocked {
            HStack {
                Text(LocalizedStringResource.codexSettingsAutoPaused)
                    .foregroundStyle(Theme.warn)
                Spacer(minLength: 8)
                Button { Task { await model.resumeAutoSwitch() } } label: {
                    Text(LocalizedStringResource.codexSettingsAutoResume)
                }
                .accessibilityIdentifier("codexResumeButton")
            }
        }
    }

    // MARK: Last event

    /// The saved status, whatever the notification settings (spec §4.6).
    private func statusRow(_ status: CodexStatus) -> some View {
        let (text, at, color) = Self.statusText(status, label: model.displayLabel(forSignIn:))
        return LabeledContent {
            Text(at.formatted(date: .abbreviated, time: .shortened))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.creamFaint)
        } label: {
            Text(text).foregroundStyle(color)
        }
        .accessibilityIdentifier("codexLastEvent")
    }

    static func statusText(_ status: CodexStatus, label: (String) -> String) -> (LocalizedStringResource, Date, Color) {
        switch status {
        // The popover line's precedence and colours (`CodexStatusLineView`).
        case .switched(let at, _, let to, _, _, true): (.codexStatusSwitchedSameWorkspace(label(to)), at, Theme.warn)
        case .switched(let at, _, let to, _, false, false): (.codexStatusSwitchedUnverified(label(to)), at, Theme.warn)
        case .switched(let at, _, let to, true, true, false): (.codexStatusSwitchedAutomatic(label(to)), at, Theme.codex)
        case .switched(let at, _, let to, false, true, false): (.codexStatusSwitchedManual(label(to)), at, Theme.codex)
        case .failed(let at): (.codexErrorFailed, at, Theme.crit)
        case .conflict(let at): (.codexErrorConflict, at, Theme.crit)
        case .needsAttention(let at): (.codexErrorNeedsAttention, at, Theme.crit)
        case .noRoom(let at): (.codexStatusNoRoom, at, Theme.warn)
        case .waiting(let at): (.codexStatusWaiting, at, Theme.creamDim)
        case .paused(let at): (.codexStatusPaused, at, Theme.warn)
        case .stale(let at, let login): (.codexStatusStale(label(login)), at, Theme.warn)
        case .damaged(let at): (.codexStatusDamaged, at, Theme.warn)
        }
    }

    // MARK: Pure helpers

    /// Any whole percent; the default is 75%.
    static let percentRange = 1...99

    static func forgetBlocked(_ status: CodexStatus?) -> Bool {
        if case .needsAttention = status { true } else { false }
    }

    /// The plan as the cards name it ("Pro 20x"), else as Codex wrote it.
    static func planName(_ planType: String?) -> String? {
        guard let planType, !planType.isEmpty else { return nil }
        return PlanTier.fromChatGPT(planType: planType)?.displayName ?? planType
    }

    /// The one Ration account whose latest session is this login — its
    /// account id AND user id (two seats of a workspace share the account
    /// id); none (the user chooses) when zero or several match.
    static func suggestedLink(for login: CodexLogin, candidates: [CodexCandidate]) -> UUID? {
        let matches = candidates.filter { $0.identity?.accountID == login.accountID && $0.identity?.userID == login.userID }
        return matches.count == 1 ? matches[0].accountID : nil
    }

    static func message(for failure: CodexSwitcher.Failure) -> LocalizedStringResource {
        switch failure {
        case .notSignedIn: .codexErrorNotSignedIn
        case .unsupported: .codexErrorUnsupported
        // Unreadable twice: Codex was rewriting it.
        case .unreadable, .signInChanging: .codexErrorChanging
        case .damaged: .codexStatusDamaged
        case .leftAccountNotRemembered: .codexErrorRememberFirst
        case .targetNotRemembered, .failed: .codexErrorFailed
        case .conflict: .codexErrorConflict
        case .journalUnresolved, .needsAttention: .codexErrorNeedsAttention
        }
    }
}

/// Remember the login Codex uses now (spec §4.2, §4.7): which Ration account
/// it belongs to (preselected when one session is this login), and what
/// Ration keeps — disclosed before the first copy.
struct CodexRememberSheet: View {
    @ObservedObject var model: CodexModel
    let onDone: () -> Void
    @State private var link: UUID?
    @State private var suggested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringResource.codexRememberTitle)
                .font(Theme.display(17, .semibold))
            if let current = model.current {
                CodexDetailView.loginLabel(current)
                    .font(Theme.mono(13))
            }
            Picker(selection: $link) {
                Text(LocalizedStringResource.codexSettingsLinkNone).tag(UUID?.none)
                ForEach(model.candidates, id: \.accountID) { candidate in
                    Text(verbatim: candidate.label).tag(UUID?.some(candidate.accountID))
                }
            } label: {
                Text(LocalizedStringResource.codexRememberAccount)
            }
            Text(LocalizedStringResource.codexRememberDisclosure)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.creamDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: onDone) { Text(LocalizedStringResource.codexRememberNotNow) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await model.rememberCurrent(linkTo: link)
                        onDone()
                    }
                } label: {
                    Text(LocalizedStringResource.codexRememberConfirm)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("codexRememberConfirm")
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard !suggested, let current = model.current else { return }
            suggested = true
            link = CodexDetailView.suggestedLink(for: current, candidates: model.candidates)
        }
    }
}
