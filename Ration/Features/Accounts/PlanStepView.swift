import SwiftUI

/// "Which plan is this?" — the optional last step of adding an account.
/// Shown only while the plan is unknown or the billing day is unset
/// (`PlanStep.isNeeded`); asks only for what is missing. Both answers are
/// skippable, and nothing is written unless the user picks it.
struct PlanStepView: View {
    let account: AccountRecord
    /// Persists the answers (nil = not answered). Awaited so the window only
    /// closes once they landed; a failure is shown instead.
    let onSave: @MainActor (PlanTier?, Int?) async throws -> Void
    let onSkip: () -> Void

    @State private var plan: PlanTier?
    @State private var billingDay: Int = 0          // 0 = not set
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        account: AccountRecord,
        onSave: @escaping @MainActor (PlanTier?, Int?) async throws -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.account = account
        self.onSave = onSave
        self.onSkip = onSkip
    }

    static var title: String { title(locale: .current) }
    static var subtitle: String { subtitle(locale: .current) }

    static func title(locale: Locale) -> String {
        LocalizedStringResource.planStepTitle.string(in: locale)
    }

    static func subtitle(locale: Locale) -> String {
        LocalizedStringResource.planStepSubtitle.string(in: locale)
    }

    /// The "no idea" chip, passed to `optionButton` next to plan names
    /// (which are never translated).
    static func notSure(locale: Locale = .current) -> String {
        LocalizedStringResource.planStepNotSure.string(in: locale)
    }

    var asksPlan: Bool { account.effectivePlan == nil }
    var asksBillingDay: Bool {
        account.billingRenewalDay == nil && BillingCycleEligibility.supports(account.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(Self.title)
                    .font(Theme.display(23, .bold))
                    .foregroundStyle(Theme.cream)
                Text(Self.subtitle)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                if asksPlan {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(account.provider.displayName) plan")
                            .font(Theme.mono(12, bold: true))
                            .foregroundStyle(Theme.cream)
                        HStack(spacing: 8) {
                            optionButton(title: Self.notSure(), value: nil)
                            ForEach(PlanTier.options(for: account.provider), id: \.self) { tier in
                                optionButton(title: tier.displayName, value: tier)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(account.provider.displayName) plan")
                        .accessibilityIdentifier("planStepPicker")
                    }
                } else if let detected = account.effectivePlan {
                    HStack(spacing: 8) {
                        Text("Plan")
                            .font(Theme.mono(12, bold: true))
                            .foregroundStyle(Theme.cream)
                        PlanTagView(tag: detected.tag)
                        Text("detected")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.creamDim)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Plan \(detected.displayName), detected")
                }

                if asksBillingDay {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(
                            selection: $billingDay,
                            label: Text("Billing renews on day")
                                .font(Theme.mono(12, bold: true))
                                .foregroundStyle(Theme.cream)
                        ) {
                            Text("Not set").tag(0)
                            ForEach(1...31, id: \.self) { day in
                                Text(verbatim: String(day)).tag(day)
                            }
                        }
                        .fixedSize()
                        .accessibilityIdentifier("planStepBillingDayPicker")
                        Text("Used for per-cycle utilisation in History.")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.creamDim)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line2, lineWidth: 1))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.crit)
                    .textSelection(.enabled)
            }

            HStack {
                Text("You can change both later in Settings.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.creamDim)
                Spacer()
                Button("Skip", action: onSkip)
                    .disabled(isSaving)
                Button("Save") { save() }
                    .buttonStyle(.goldProminent)
                    .disabled(isSaving)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.ink)
        .tint(Theme.gold)
    }

    /// One plan option as a chip — a SwiftUI control (a segmented NSControl
    /// doesn't draw in the offscreen snapshot renderer) in the gold accent
    /// the rest of the add-account flow uses.
    private func optionButton(title: String, value: PlanTier?) -> some View {
        let selected: Bool = plan == value
        return Button {
            plan = value
        } label: {
            Text(title)
                .font(Theme.mono(12, bold: selected))
                .foregroundStyle(selected ? Theme.cream : Theme.creamDim)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Theme.gold.opacity(0.16) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(selected ? Theme.gold : Theme.line2, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        let chosenPlan: PlanTier? = asksPlan ? plan : nil
        let chosenDay: Int? = asksBillingDay && billingDay > 0 ? billingDay : nil
        Task { @MainActor in
            do {
                try await onSave(chosenPlan, chosenDay)
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
