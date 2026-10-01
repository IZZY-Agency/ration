import SwiftUI

extension APIOrgEditError {
    func message(locale: Locale = .current) -> String {
        switch self {
        case .invalidKey: LocalizedStringResource.apiSpendErrorInvalidKey.string(in: locale)
        case .regularKey(let vendor): LocalizedStringResource.apiSpendErrorRegularKey(vendor.consoleName).string(in: locale)
        case .duplicate(let label): LocalizedStringResource.apiSpendErrorDuplicate(label).string(in: locale)
        case .secondOpenAIWithoutIdentity: LocalizedStringResource.apiSpendErrorSecondOpenAI.string(in: locale)
        case .identityMismatch: LocalizedStringResource.apiSpendErrorIdentityMismatch.string(in: locale)
        case .replaceUnavailable: LocalizedStringResource.apiSpendSettingsReplaceUnavailable.string(in: locale)
        case .busy, .saveFailed, .keychain: LocalizedStringResource.apiSpendErrorSaveFailed.string(in: locale)
        case .validation(let error): APISpendStateCopy.text(for: error, locale: locale)
        }
    }
}

/// Live classification of the pasted key, shown under the field. With an
/// `expected` vendor (the Add sheet, where the provider is picked first), an
/// Admin key of the OTHER vendor is refused with a pointer back.
func apiKeyHint(_ raw: String, expected: APIVendor? = nil) -> (vendor: APIVendor?, error: String?) {
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, nil) }
    switch APIVendor.classify(raw) {
    case .admin(let vendor):
        if let expected, vendor != expected {
            return (nil, LocalizedStringResource.apiSpendErrorOtherVendor(vendor.displayName).string(in: .current))
        }
        return (vendor, nil)
    case .regular(let vendor): return (nil, APIOrgEditError.regularKey(vendor).message())
    case .invalid: return (nil, APIOrgEditError.invalidKey.message())
    }
}

/// What Add API Account offers, in order: the Admin-key platforms, then
/// TypeSafe, which signs in instead (its API keys read nothing but the model).
enum APIAccountChoice: Hashable, Sendable {
    case adminKey(APIVendor)
    case signIn(Provider)

    static var all: [APIAccountChoice] {
        APIVendor.allCases.map(Self.adminKey) + Provider.allCases.filter { $0.isAPIAccount && $0.isOffered }.map(Self.signIn)
    }

    /// Brand names — never translated.
    var name: String {
        switch self {
        case .adminKey(let vendor): vendor.displayName
        case .signIn(let provider): provider.displayName
        }
    }

    var markLetter: String {
        switch self {
        case .adminKey(let vendor): vendor.markLetter
        case .signIn(let provider): provider.markLetter
        }
    }

    var accent: Color {
        switch self {
        case .adminKey(let vendor): vendor.accent
        case .signIn(let provider): provider.markAccent
        }
    }

    /// The second step, in one line: "Admin key from the Claude Console".
    func methodLine(locale: Locale = .current) -> String {
        switch self {
        case .adminKey(let vendor): LocalizedStringResource.apiAccountMethodAdminKey(vendor.consoleName).string(in: locale)
        case .signIn: LocalizedStringResource.apiAccountMethodSignIn.string(in: locale)
        }
    }
}

/// "Add API Account", as Add Account works for subscriptions: pick the
/// provider, then its way in — an Admin key (name, key, optional monthly
/// budget) or a sign-in window. The key lives only in this sheet's state and
/// is cleared on dismiss.
struct AddAPIOrgSheet: View {
    /// Counts content appearances: a sheet anchored inside the sidebar List
    /// was rebuilt on every row change, so the sheet flickered.
    static var appearancesForTesting = 0

    @ObservedObject var model: APISpendModel
    /// Opens the sign-in window for a web-session API account (TypeSafe).
    /// The sheet closes first.
    var onSignIn: (Provider) -> Void = { _ in }
    let onDone: () -> Void
    @State private var choice: APIAccountChoice?
    @State private var label = ""
    @State private var key = ""
    @State private var budgetText = ""
    @State private var errorText: String?
    @State private var busy = false
    /// Cancel cancels it: nothing reaches the Keychain after.
    @State private var operation: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    init(
        model: APISpendModel,
        initialChoice: APIAccountChoice? = nil,
        onSignIn: @escaping (Provider) -> Void = { _ in },
        onDone: @escaping () -> Void
    ) {
        self.model = model
        self.onSignIn = onSignIn
        self.onDone = onDone
        _choice = State(initialValue: initialChoice)
    }

    private var budget: Result<Int?, APIBudgetInputError> { APIBudgetInput.cents(from: budgetText, locale: .current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch choice {
            case nil: picker
            case .adminKey(let vendor)?: keyForm(vendor)
            case .signIn(let provider)?: signInStep(provider)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.ink)
        .onAppear { Self.appearancesForTesting += 1 }
        .onDisappear { key = "" }
    }

    // MARK: Step 1 — the provider

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringResource.apiSpendSettingsAddTitle)
                    .font(Theme.display(17, .semibold))
                    .foregroundStyle(Theme.cream)
                Text(LocalizedStringResource.apiAccountPickSubtitle)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(APIAccountChoice.all, id: \.self) { option in
                Button { choose(option) } label: {
                    HStack(spacing: 12) {
                        mark(option)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: option.name)
                                .font(Theme.display(16, .semibold))
                                .foregroundStyle(Theme.cream)
                            Text(option.methodLine())
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.creamDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.creamFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(option.name), \(option.methodLine())"))
                .accessibilityIdentifier("addAPIAccountChoice.\(option.name)")
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line2, lineWidth: 1))
            }
            HStack {
                Spacer()
                Button { close() } label: { Text(LocalizedStringResource.apiSpendSettingsCancel) }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func mark(_ option: APIAccountChoice) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(option.accent.opacity(Theme.markFillOpacity(colorScheme)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(option.accent.opacity(0.4)))
            .frame(width: 28, height: 28)
            .overlay(Text(verbatim: option.markLetter).font(Theme.mono(14, bold: true)).foregroundStyle(option.accent))
            .accessibilityHidden(true)
    }

    private func stepHeader(_ option: APIAccountChoice) -> some View {
        HStack(spacing: 10) {
            Button { back() } label: {
                Label { Text(LocalizedStringResource.apiAccountBack) } icon: { Image(systemName: "chevron.left") }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .accessibilityIdentifier("addAPIAccountBack")
            mark(option)
            Text(verbatim: option.name)
                .font(Theme.display(17, .semibold))
                .foregroundStyle(Theme.cream)
        }
    }

    // MARK: Step 2 — an Admin key

    private func keyForm(_ vendor: APIVendor) -> some View {
        let hint = apiKeyHint(key, expected: vendor)
        return VStack(alignment: .leading, spacing: 12) {
            stepHeader(.adminKey(vendor))
            Form {
                TextField(text: $label, prompt: Text(LocalizedStringResource.apiSpendSettingsLabelPlaceholder)) {
                    Text(LocalizedStringResource.apiSpendSettingsLabel)
                }
                SecureField(text: $key, prompt: Text(verbatim: Self.keyPlaceholder(vendor))) {
                    Text(LocalizedStringResource.apiSpendSettingsKey)
                }
                TextField(text: $budgetText, prompt: Text(LocalizedStringResource.apiSpendSettingsBudgetPlaceholder)) {
                    Text(LocalizedStringResource.apiSpendSettingsBudget)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            ForEach([hint.error, budgetErrorText, errorText].compactMap { $0 }, id: \.self) { message in
                Text(message).font(Theme.mono(12)).foregroundStyle(Theme.crit).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button { close() } label: { Text(LocalizedStringResource.apiSpendSettingsCancel) }
                    .keyboardShortcut(.cancelAction)
                Button { add() } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(LocalizedStringResource.apiSpendSettingsAddButton) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || hint.vendor == nil || budgetErrorText != nil)
            }
        }
    }

    /// The vendor's Admin-key prefix, so the field says which key it wants.
    static func keyPlaceholder(_ vendor: APIVendor) -> String {
        switch vendor {
        case .anthropic: "sk-ant-admin01-…"
        case .openAI: "sk-admin-…"
        }
    }

    // MARK: Step 2 — a sign-in

    private func signInStep(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(.signIn(provider))
            Text(Self.signInNote(provider))
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button { close() } label: { Text(LocalizedStringResource.apiSpendSettingsCancel) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    close()
                    onSignIn(provider)
                } label: {
                    Text(LocalizedStringResource.apiAccountSignIn)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("addAPIAccountSignIn")
            }
        }
    }

    /// Why a sign-in and not a key, and how to get through it.
    static func signInNote(_ provider: Provider, locale: Locale = .current) -> String {
        LocalizedStringResource.apiAccountSignInNoteTypeSafe.string(in: locale)
    }

    // MARK: Actions

    private var budgetErrorText: String? {
        if case .failure(let error) = budget { return error.message() }
        return nil
    }

    private func choose(_ option: APIAccountChoice) {
        errorText = nil
        choice = option
    }

    private func back() {
        operation?.cancel()
        operation = nil
        key = ""
        errorText = nil
        choice = nil
    }

    private func close() {
        operation?.cancel()
        operation = nil
        key = ""
        onDone()
    }

    private func add() {
        guard case .success(let cents) = budget else { return }
        busy = true
        errorText = nil
        operation = Task {
            defer { busy = false }
            do {
                _ = try await model.addOrg(label: label, rawKey: key, budgetCents: cents)
                close()
            } catch is CancellationError {
            } catch let error as APIOrgEditError {
                errorText = error.message()
            } catch {
                errorText = APIOrgEditError.saveFailed.message()
            }
        }
    }
}

/// "Replace…": a new Admin key for the same organization.
struct ReplaceAPIKeySheet: View {
    @ObservedObject var model: APISpendModel
    let orgID: UUID
    let onDone: () -> Void
    @State private var key = ""
    @State private var errorText: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        let hint = apiKeyHint(key)
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource.apiSpendSettingsReplaceTitle)
                .font(Theme.display(17, .semibold))
                .foregroundStyle(Theme.cream)
            Form {
                SecureField(text: $key, prompt: Text(verbatim: "sk-ant-admin01-… / sk-admin-…")) {
                    Text(LocalizedStringResource.apiSpendSettingsKey)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            ForEach([hint.error, errorText].compactMap { $0 }, id: \.self) { message in
                Text(message).font(Theme.mono(12)).foregroundStyle(Theme.crit).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button { close() } label: { Text(LocalizedStringResource.apiSpendSettingsCancel) }
                    .keyboardShortcut(.cancelAction)
                Button { replace() } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text(LocalizedStringResource.apiSpendSettingsReplace) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || hint.vendor == nil || model.replacing[orgID] != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.ink)
        .onDisappear { key = "" }
    }

    private func close() {
        operation?.cancel()
        operation = nil
        key = ""
        onDone()
    }

    private func replace() {
        busy = true
        errorText = nil
        operation = Task {
            defer { busy = false }
            do {
                try await model.replaceKey(orgID, rawKey: key)
                close()
            } catch is CancellationError {
            } catch let error as APIOrgEditError {
                errorText = error.message()
            } catch {
                errorText = APIOrgEditError.saveFailed.message()
            }
        }
    }
}
