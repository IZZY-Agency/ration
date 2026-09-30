import SwiftUI

/// Settings › Claude Code (spec §4.3): the sign-in Claude Code uses now,
/// the remembered sign-ins and their links, automatic switching, privacy.
struct ClaudeCodeDetailView: View {
    @ObservedObject var model: ClaudeCodeModel
    @State private var remembering = false
    @State private var confirmingForgetAll = false

    var body: some View {
        Form {
            if let status = model.state.status {
                Section { statusRow(status) } header: { Text(LocalizedStringResource.claudeCodeSettingsStatusHeader) }
            }
            Section { nowRows } header: { Text(LocalizedStringResource.claudeCodeSettingsNowHeader) }
            Section { rememberedRows } header: { Text(LocalizedStringResource.claudeCodeSettingsRememberedHeader) }
            Section { automaticRows } header: { Text(LocalizedStringResource.claudeCodeSettingsAutoHeader) }
            Section {
                Toggle(isOn: Binding(get: { model.state.notify }, set: { on in Task { await model.setNotify(on) } })) {
                    Text(LocalizedStringResource.claudeCodeSettingsNotify)
                }
                .accessibilityIdentifier("claudeCodeNotifyToggle")
                if let error = model.lastError {
                    Text(Self.message(for: error))
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.warn)
                        .accessibilityIdentifier("claudeCodeError")
                }
                Text(LocalizedStringResource.claudeCodeSettingsPrivacy)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
                Button(role: .destructive) { confirmingForgetAll = true } label: {
                    Text(LocalizedStringResource.claudeCodeSettingsForgetAll)
                }
                .disabled(model.remembered.isEmpty || model.isSwitching)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $remembering) {
            ClaudeCodeRememberSheet(model: model) { remembering = false }
        }
        .confirmationDialog(Text(LocalizedStringResource.claudeCodeSettingsForgetAllConfirm), isPresented: $confirmingForgetAll) {
            Button(role: .destructive) { Task { await model.forgetAll() } } label: {
                Text(LocalizedStringResource.claudeCodeSettingsForgetAll)
            }
        } message: {
            Text(LocalizedStringResource.claudeCodeSettingsForgetAllMessage)
        }
    }

    // MARK: Claude Code now

    @ViewBuilder
    private var nowRows: some View {
        if let current = model.current {
            LabeledContent {
                if model.remembered.contains(where: { $0.uuid == current.uuid }) {
                    Text(LocalizedStringResource.claudeCodeSettingsNowRemembered)
                        .foregroundStyle(Theme.creamDim)
                } else {
                    Button { remembering = true } label: { Text(LocalizedStringResource.claudeCodeSettingsNowRemember) }
                        .disabled(model.isSwitching)
                        .accessibilityIdentifier("claudeCodeRememberButton")
                }
            } label: {
                Text(verbatim: current.organizationName ?? current.uuid)
            }
        } else {
            Text(LocalizedStringResource.claudeCodeSettingsNowNone)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
        }
    }

    // MARK: Remembered sign-ins

    @ViewBuilder
    private var rememberedRows: some View {
        if model.signIns.isEmpty {
            Text(LocalizedStringResource.claudeCodeSettingsRememberedEmpty)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
        }
        ForEach(model.signIns) { signIn in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: signIn.account.organizationName ?? signIn.id)
                        .lineLimit(1)
                    if signIn.id == model.current?.uuid {
                        Text(LocalizedStringResource.claudeCodeSettingsCurrentTag)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.gold)
                            .padding(.horizontal, 5)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.gold.opacity(0.55), lineWidth: 1))
                    }
                    Spacer(minLength: 8)
                    if signIn.id != model.current?.uuid, let accountID = signIn.linkedAccountID {
                        Button { Task { await model.useInClaudeCode(accountID: accountID) } } label: {
                            Text(LocalizedStringResource.claudeCodeSettingsSwitch)
                        }
                        .disabled(model.isSwitching)
                    }
                    Button(role: .destructive) { Task { await model.forget(signIn.id) } } label: {
                        Text(LocalizedStringResource.claudeCodeSettingsForget)
                    }
                    .disabled(model.isSwitching)
                }
                Picker(selection: Binding(
                    get: { signIn.linkedAccountID },
                    set: { id in Task { await model.link(signIn.id, to: id) } }
                )) {
                    Text(LocalizedStringResource.claudeCodeSettingsLinkNone).tag(UUID?.none)
                    ForEach(model.candidates, id: \.accountID) { candidate in
                        Text(verbatim: candidate.label).tag(UUID?.some(candidate.accountID))
                    }
                } label: {
                    Text(LocalizedStringResource.claudeCodeSettingsLinkLabel)
                }
                if signIn.linkedAccountID != nil {
                    Text(signIn.verified ? LocalizedStringResource.claudeCodeSettingsLinkVerified : .claudeCodeSettingsLinkChosen)
                        .font(Theme.mono(11))
                        .foregroundStyle(signIn.verified ? Theme.active : Theme.creamFaint)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Switch automatically

    @ViewBuilder
    private var automaticRows: some View {
        Toggle(isOn: Binding(
            get: { model.state.autoSwitchEnabled },
            set: { on in Task { await model.setAutoSwitch(enabled: on, rule: model.state.rule) } }
        )) {
            Text(LocalizedStringResource.claudeCodeSettingsAutoToggle)
        }
        .accessibilityIdentifier("claudeCodeAutoToggle")
        Stepper(value: Binding(
            get: { model.state.rule.percent },
            set: { percent in
                var rule = model.state.rule
                rule.percent = percent
                Task { await model.setAutoSwitch(enabled: model.state.autoSwitchEnabled, rule: rule) }
            }
        ), in: Self.percentRange, step: 5) {
            LabeledContent {
                Text(LocalizedStringResource.claudeCodeSettingsAutoPercent(model.state.rule.percent))
                    .font(Theme.mono(13))
            } label: {
                Text(LocalizedStringResource.claudeCodeSettingsAutoThreshold)
            }
        }
        Picker(selection: Binding(
            get: { model.state.rule.kind },
            set: { kind in
                var rule = model.state.rule
                rule.kind = kind
                Task { await model.setAutoSwitch(enabled: model.state.autoSwitchEnabled, rule: rule) }
            }
        )) {
            Text(LocalizedStringResource.claudeCodeSettingsLimitWeekly).tag(UsageWindowKind.weekly)
            Text(LocalizedStringResource.claudeCodeSettingsLimitFiveHour).tag(UsageWindowKind.fiveHour)
            Text(LocalizedStringResource.claudeCodeSettingsLimitFable).tag(UsageWindowKind.modelWeekly)
        } label: {
            Text(LocalizedStringResource.claudeCodeSettingsAutoLimit)
        }
        Text(LocalizedStringResource.claudeCodeSettingsAutoExplain)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.creamDim)
        if model.stateSaveFailed {
            Text(LocalizedStringResource.claudeCodeSettingsSaveFailed)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.warn)
        }
        if model.state.autoSwitchPaused {
            HStack {
                Text(LocalizedStringResource.claudeCodeSettingsAutoPaused)
                    .foregroundStyle(Theme.warn)
                Spacer(minLength: 8)
                Button { Task { await model.resumeAutoSwitch() } } label: {
                    Text(LocalizedStringResource.claudeCodeSettingsAutoResume)
                }
                .accessibilityIdentifier("claudeCodeResumeButton")
            }
        }
    }

    // MARK: Last event

    /// The saved status, whatever the notification settings (spec §4.6), with
    /// what to do when something needs attention.
    private func statusRow(_ status: ClaudeCodeStatus) -> some View {
        let (text, at, color) = Self.statusText(status, label: model.displayLabel(forSignIn:))
        return LabeledContent {
            Text(at.formatted(date: .abbreviated, time: .shortened))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.creamFaint)
        } label: {
            Text(text).foregroundStyle(color)
        }
        .accessibilityIdentifier("claudeCodeLastEvent")
    }

    static func statusText(_ status: ClaudeCodeStatus, label: (String) -> String) -> (LocalizedStringResource, Date, Color) {
        switch status {
        case .switched(let at, _, let to, true): (.claudeCodeStatusSwitchedAutomatic(label(to)), at, Theme.active)
        case .switched(let at, _, let to, false): (.claudeCodeStatusSwitchedManual(label(to)), at, Theme.active)
        case .failed(let at): (.claudeCodeErrorFailed, at, Theme.crit)
        case .conflict(let at): (.claudeCodeErrorConflict, at, Theme.crit)
        case .needsAttention(let at): (.claudeCodeErrorNeedsAttention, at, Theme.crit)
        case .noRoom(let at): (.claudeCodeStatusNoRoom, at, Theme.warn)
        case .waiting(let at): (.claudeCodeStatusWaiting, at, Theme.creamDim)
        case .paused(let at): (.claudeCodeStatusPaused, at, Theme.warn)
        }
    }

    // MARK: Pure helpers

    /// 5% steps; the default is 75%.
    static let percentRange = 5...95

    /// The one Ration account whose latest snapshot reports the sign-in's
    /// organization; none (the user chooses) when zero or several match.
    static func suggestedLink(for account: ClaudeCodeAccount, candidates: [ClaudeCodeCandidate]) -> UUID? {
        guard let organization = account.organizationUUID else { return nil }
        let matches = candidates.filter { $0.organizationID == organization }
        return matches.count == 1 ? matches[0].accountID : nil
    }

    static func message(for failure: ClaudeCodeSwitcher.Failure) -> LocalizedStringResource {
        switch failure {
        case .notSignedIn, .configUnreadable: .claudeCodeErrorNotSignedIn
        case .signInChanging: .claudeCodeErrorChanging
        case .leftAccountNotRemembered: .claudeCodeErrorRememberFirst
        case .targetNotRemembered, .failed: .claudeCodeErrorFailed
        case .conflict: .claudeCodeErrorConflict
        case .needsAttention, .unverified: .claudeCodeErrorNeedsAttention
        }
    }
}

/// Remember the sign-in Claude Code uses now (spec §4.2, §4.7): which Ration
/// account it belongs to, and what Ration keeps — disclosed before the first copy.
struct ClaudeCodeRememberSheet: View {
    @ObservedObject var model: ClaudeCodeModel
    let onDone: () -> Void
    @State private var link: UUID?
    @State private var suggested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringResource.claudeCodeRememberTitle)
                .font(Theme.display(17, .semibold))
            if let current = model.current {
                Text(verbatim: current.organizationName ?? current.uuid)
                    .font(Theme.mono(13))
            }
            Picker(selection: $link) {
                Text(LocalizedStringResource.claudeCodeSettingsLinkNone).tag(UUID?.none)
                ForEach(model.candidates, id: \.accountID) { candidate in
                    Text(verbatim: candidate.label).tag(UUID?.some(candidate.accountID))
                }
            } label: {
                Text(LocalizedStringResource.claudeCodeRememberAccount)
            }
            Text(LocalizedStringResource.claudeCodeRememberDisclosure)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.creamDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: onDone) { Text(LocalizedStringResource.claudeCodeRememberNotNow) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await model.rememberCurrent(linkTo: link)
                        onDone()
                    }
                } label: {
                    Text(LocalizedStringResource.claudeCodeRememberConfirm)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("claudeCodeRememberConfirm")
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard !suggested, let current = model.current else { return }
            suggested = true
            link = ClaudeCodeDetailView.suggestedLink(for: current, candidates: model.candidates)
        }
    }
}
