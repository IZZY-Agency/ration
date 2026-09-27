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

/// Live classification of the pasted key, shown under the field.
private func keyHint(_ raw: String) -> (vendor: APIVendor?, error: String?) {
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, nil) }
    switch APIVendor.classify(raw) {
    case .admin(let vendor): return (vendor, nil)
    case .regular(let vendor): return (nil, APIOrgEditError.regularKey(vendor).message())
    case .invalid: return (nil, APIOrgEditError.invalidKey.message())
    }
}

/// "Add API org…": name, Admin key (secure), optional monthly budget.
/// The key lives only in this sheet's state and is cleared on dismiss.
struct AddAPIOrgSheet: View {
    /// Counts content appearances: a sheet anchored inside the sidebar List
    /// was rebuilt on every row change, so the sheet flickered.
    static var appearancesForTesting = 0

    @ObservedObject var model: APISpendModel
    let onDone: () -> Void
    @State private var label = ""
    @State private var key = ""
    @State private var budgetText = ""
    @State private var errorText: String?
    @State private var busy = false
    /// Cancel cancels it: nothing reaches the Keychain after.
    @State private var operation: Task<Void, Never>?

    private var budget: Result<Int?, APIBudgetInputError> { APIBudgetInput.cents(from: budgetText, locale: .current) }

    var body: some View {
        let hint = keyHint(key)
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource.apiSpendSettingsAddTitle)
                .font(Theme.display(17, .semibold))
                .foregroundStyle(Theme.cream)
            Form {
                TextField(text: $label, prompt: Text(LocalizedStringResource.apiSpendSettingsLabelPlaceholder)) {
                    Text(LocalizedStringResource.apiSpendSettingsLabel)
                }
                SecureField(text: $key, prompt: Text(verbatim: "sk-ant-admin01-… / sk-admin-…")) {
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
            if let vendor = hint.vendor {
                Text(verbatim: vendor.displayName.uppercased())
                    .font(Theme.mono(11)).tracking(0.8).foregroundStyle(vendor.accent)
            }
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
        .padding(20)
        .frame(width: 480)
        .background(Theme.ink)
        .onAppear { Self.appearancesForTesting += 1 }
        .onDisappear { key = "" }
    }

    private var budgetErrorText: String? {
        if case .failure(let error) = budget { return error.message() }
        return nil
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
        let hint = keyHint(key)
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
