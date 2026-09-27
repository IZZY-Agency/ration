import Charts
import SwiftUI

/// Settings › API orgs › one org: name, budget, key, pause, remove,
/// this month by day, tokens by model (+ cost for Anthropic), OpenAI line items.
struct APIOrgDetailView: View {
    @ObservedObject var model: APISpendModel
    let orgID: UUID
    @StateObject private var drafts: APIOrgFieldDrafts
    @FocusState private var focused: Field?
    @State private var showReplace = false
    @State private var confirmRemove = false

    private enum Field { case label, budget }

    /// `SettingsView` gives each org its own pane (`.id(orgID)`), so the
    /// drafts start from that org's saved values.
    init(model: APISpendModel, orgID: UUID) {
        self.model = model
        self.orgID = orgID
        let org = model.org(orgID)
        _drafts = StateObject(wrappedValue: APIOrgFieldDrafts(
            label: org?.label ?? "",
            budgetCents: org?.monthlyBudgetCents,
            onRename: { [weak model] in model?.rename(orgID, to: $0) },
            onBudget: { [weak model] in model?.setBudget(orgID, cents: $0) }
        ))
    }

    var body: some View {
        if let org = model.org(orgID) {
            Form {
                Section { settingsRows(org) } header: { header(org) }
                if let cost = model.snapshots[orgID]?.cost {
                    Section { chart(cost, org: org) } header: { Text(monthTitle(cost)) }
                }
                if hasModelSection(org) {
                    Section { modelTable(org) } header: { Text(LocalizedStringResource.apiSpendSettingsByModel) } footer: { tableFooter(org) }
                }
                if org.vendor == .openAI, let cost = model.snapshots[orgID]?.cost, !cost.byLineItem.isEmpty {
                    Section { lineItemTable(cost) } header: { Text(LocalizedStringResource.apiSpendSettingsByLineItem) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .onChange(of: focused) { previous, _ in
                switch previous {
                case .label?: drafts.commitLabel()
                case .budget?: drafts.commitBudget()
                case nil: break
                }
            }
            .onDisappear { drafts.commitAll() }
            .sheet(isPresented: $showReplace) {
                ReplaceAPIKeySheet(model: model, orgID: orgID) { showReplace = false }
            }
            .confirmationDialog(Text(LocalizedStringResource.apiSpendSettingsRemoveConfirm), isPresented: $confirmRemove) {
                Button(role: .destructive) { Task { _ = await model.removeOrg(orgID) } } label: {
                    Text(LocalizedStringResource.apiSpendSettingsRemove)
                }
            }
        }
    }

    /// Hidden until there is something to show: rows, or a token error.
    private func hasModelSection(_ org: APIOrgRecord) -> Bool {
        let snapshot = model.snapshots[orgID]
        return !(snapshot?.tokens?.byModel ?? []).isEmpty
            || (org.vendor == .anthropic && !(snapshot?.cost?.byModel ?? []).isEmpty)
            || model.tokenErrors[orgID] != nil
    }

    private func header(_ org: APIOrgRecord) -> some View {
        HStack(spacing: 7) {
            Circle().fill(org.vendor.accent).frame(width: 6, height: 6)
            Text(verbatim: org.label).font(Theme.display(15, .semibold)).foregroundStyle(Theme.cream)
            Text(verbatim: org.vendor.displayName.uppercased()).font(Theme.mono(11)).tracking(0.8).foregroundStyle(org.vendor.accent)
            Spacer()
            if let fetched = model.snapshots[orgID]?.cost?.fetchedAt {
                Text(LocalizedStringResource.apiSpendCardAsOf(fetched.formatted(date: .omitted, time: .shortened)))
                    .font(Theme.mono(11)).foregroundStyle(Theme.creamFaint)
            }
        }
    }

    @ViewBuilder
    private func settingsRows(_ org: APIOrgRecord) -> some View {
        TextField(text: $drafts.label, prompt: Text(verbatim: org.label)) { Text(LocalizedStringResource.apiSpendSettingsLabel) }
            .focused($focused, equals: .label)
            .onSubmit { drafts.commitLabel() }
        VStack(alignment: .leading, spacing: 4) {
            TextField(text: $drafts.budget, prompt: Text(LocalizedStringResource.apiSpendSettingsBudgetPlaceholder)) {
                Text(LocalizedStringResource.apiSpendSettingsBudget)
            }
            .focused($focused, equals: .budget)
            .onSubmit { drafts.commitBudget() }
            if case .failure(let error) = APIBudgetInput.cents(from: drafts.budget, locale: .current) {
                Text(error.message()).font(Theme.mono(12)).foregroundStyle(Theme.crit)
            }
        }
        LabeledContent {
            if org.vendorOrgID == nil {
                Text(LocalizedStringResource.apiSpendSettingsReplaceUnavailable).font(Theme.mono(12)).foregroundStyle(Theme.creamDim)
            } else {
                Button { showReplace = true } label: { Text(LocalizedStringResource.apiSpendSettingsReplace) }
                    .disabled(model.replacing[orgID] != nil)
            }
        } label: {
            Text(LocalizedStringResource.apiSpendSettingsInKeychain)
        }
        if let error = model.costErrors[orgID] {
            Text(APISpendStateCopy.text(for: error)).font(Theme.mono(12)).foregroundStyle(Theme.crit)
        }
        Toggle(isOn: Binding(get: { org.isPaused }, set: { paused in Task { await model.setPaused(orgID, paused) } })) {
            Text(LocalizedStringResource.apiSpendSettingsPause)
        }
        HStack {
            if model.removeFailures.contains(orgID) {
                Text(LocalizedStringResource.apiSpendSettingsRemoveFailed).font(Theme.mono(12)).foregroundStyle(Theme.crit)
            }
            Spacer()
            Button(role: .destructive) { confirmRemove = true } label: { Text(LocalizedStringResource.apiSpendSettingsRemove) }
                .disabled(model.replacing[orgID] != nil)
        }
    }

    private func monthTitle(_ cost: APICostReport) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide)
        style.timeZone = TimeZone(identifier: "UTC")!
        return LocalizedStringResource.apiSpendSettingsByDay(cost.month.start.formatted(style)).string(in: .current)
    }

    private func chart(_ cost: APICostReport, org: APIOrgRecord) -> some View {
        let today = UTCDay.start(of: cost.fetchedAt)
        return VStack(alignment: .leading, spacing: 6) {
            Chart(cost.days, id: \.dayStart) { day in
                BarMark(
                    x: .value("Day", day.dayStart, unit: .day),
                    y: .value("USD", NSDecimalNumber(decimal: day.cents / 100).doubleValue)
                )
                .foregroundStyle(day.dayStart == today ? Theme.creamDim : org.vendor.accent)
            }
            .chartXScale(domain: cost.month.start...cost.month.nextStart)
            .frame(height: 140)
            if cost.days.contains(where: { $0.dayStart == today }) {
                Text(LocalizedStringResource.apiSpendSettingsTodayPartial).font(Theme.mono(11)).foregroundStyle(Theme.creamFaint)
            }
        }
    }

    /// One block per model: name and cost, then its token counts — a
    /// six-column grid truncated names and headers at the pane's width.
    @ViewBuilder
    private func modelTable(_ org: APIOrgRecord) -> some View {
        let tokens = model.snapshots[orgID]?.tokens?.byModel ?? []
        let cost = model.snapshots[orgID]?.cost
        let costs = org.vendor == .anthropic ? cost?.byModel ?? [] : []
        let names = tokens.map(\.model) + costs.map(\.model).filter { name in !tokens.contains { $0.model == name } }
        ForEach(names, id: \.self) { name in
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: name).font(Theme.mono(12)).foregroundStyle(Theme.cream)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let cents = costs.first(where: { $0.model == name })?.cents {
                        Text(verbatim: dollars(cents)).font(Theme.mono(12)).foregroundStyle(Theme.cream).monospacedDigit()
                    }
                }
                if let row = tokens.first(where: { $0.model == name }) {
                    Text(verbatim: [
                        (LocalizedStringResource.apiSpendSettingsColInput, row.input),
                        (.apiSpendSettingsColCacheWrite, row.cacheWrite),
                        (.apiSpendSettingsColCacheRead, row.cacheRead),
                        (.apiSpendSettingsColOutput, row.output),
                    ].map { "\($0.0.string(in: .current)) \(count($0.1))" }.joined(separator: " · "))
                        .font(Theme.mono(11)).foregroundStyle(Theme.creamDim).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if org.vendor == .anthropic {
            ForEach(cost?.otherCharges ?? [], id: \.description) { other in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: LocalizedStringResource.apiSpendSettingsOtherCharges.string(in: .current)
                        + (other.description.isEmpty ? "" : " · \(other.description)"))
                        .font(Theme.mono(12)).foregroundStyle(Theme.cream).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(verbatim: dollars(other.cents)).font(Theme.mono(12)).foregroundStyle(Theme.cream).monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func tableFooter(_ org: APIOrgRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if org.vendor == .openAI {
                Text(LocalizedStringResource.apiSpendSettingsCompletionsOnly)
            }
            if let error = model.tokenErrors[orgID] {
                Text(APISpendStateCopy.text(for: error)).foregroundStyle(Theme.crit)
            }
        }
        .font(Theme.mono(11))
        .foregroundStyle(Theme.creamFaint)
    }

    private func lineItemTable(_ cost: APICostReport) -> some View {
        ForEach(cost.byLineItem, id: \.lineItem) { item in
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: item.lineItem).font(Theme.mono(12)).foregroundStyle(Theme.cream)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(verbatim: dollars(item.cents)).font(Theme.mono(12)).foregroundStyle(Theme.cream).monospacedDigit()
            }
        }
    }

    private func count(_ value: Int?) -> String {
        value.map { UsageFormatters.tokenCount($0) } ?? "—"
    }

    private func dollars(_ cents: Decimal) -> String { UsageFormatters.usd(cents: APIMoney.roundedCents(cents)) }
}

/// One API account's row in the Settings sidebar's Accounts list.
struct APIAccountSidebarRow: View {
    let org: APIOrgRecord
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6)
                .fill(org.vendor.accent.opacity(Theme.markFillOpacity(colorScheme)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(org.vendor.accent.opacity(0.4)))
                .frame(width: 22, height: 22)
                .overlay(Text(verbatim: org.vendor.markLetter).font(Theme.mono(13, bold: true)).foregroundStyle(org.vendor.accent))
            Text(verbatim: org.label).font(Theme.display(15, .medium)).foregroundStyle(Theme.cream).lineLimit(1)
            Spacer(minLength: 6)
        }
    }
}

/// Settings banner while a removed org's key is still being deleted.
struct APIPendingKeyBanner: View {
    @ObservedObject var model: APISpendModel

    var body: some View {
        if model.hasPendingKeyDeletions {
            Label { Text(LocalizedStringResource.apiSpendSettingsPendingKeyBanner) } icon: { Image(systemName: "key.slash") }
                .font(Theme.mono(12))
                .foregroundStyle(Theme.warn)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
        }
    }
}
