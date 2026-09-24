import SwiftUI

/// The popover body in the Focus layout: the hero account as one big number, a
/// line per other account in use, a red line per nearly-spent account, a line
/// per switch advice, then a quiet wrapped row of everything else. The header
/// and footer around it are `MenuBarView`'s own. Clicking an account that can
/// be the hero shows it as the hero until the surface is presented again; the
/// hero's × goes back to the automatic one. Every text colour is a Theme text
/// token drawn at full opacity on `ink` — paused entries are "dimmed" with
/// `creamFaint`, never with opacity, so each pair stays ≥ 4.5 : 1.
struct FocusView: View {
    let model: FocusModel
    let now: Date
    /// Show this account as the hero; nil → back to the automatic hero.
    let onShowHero: (UUID?) -> Void
    let onReauthenticate: (UUID) -> Void

    private static let inset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.emptyState == .allPaused {
                allPausedNote
            }

            if let hero = model.hero {
                heroView(hero)
            }

            ForEach(model.otherInUse, id: \.presentation.id) { line in
                separator
                inUseLine(line)
            }

            ForEach(model.warnings, id: \.presentation.id) { warning in
                separator
                warningLine(warning)
            }

            ForEach(model.switchLines, id: \.fromAccountID) { advice in
                separator
                switchLine(advice)
            }

            if !model.others.isEmpty {
                if model.hero != nil || !model.otherInUse.isEmpty || !model.warnings.isEmpty
                    || !model.switchLines.isEmpty {
                    separator
                }
                FocusFlowLayout(horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(model.others, id: \.presentation.id) { entry in
                        entryView(entry)
                    }
                }
                .padding(.horizontal, Self.inset)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var separator: some View {
        Divider()
            .overlay(Theme.line)
            .padding(.horizontal, Self.inset)
    }

    // MARK: Hero

    private func heroView(_ hero: FocusModel.Hero) -> some View {
        let tint: Color = Theme.tierColor(usedFraction: hero.usedFraction)
        let limits: String = FocusModel.limitsLine(
            resetsAt: hero.resetsAt,
            limits: hero.otherLimits,
            now: now
        )
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                providerDot(hero.account.provider, size: 7)
                Text(hero.account.label)
                    .font(Theme.display(15, .semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let planTag = PlanChoice.tag(for: hero.account) {
                    PlanTagView(tag: planTag)
                }
                if let tag = Self.tagText(hero.tag) {
                    Text(tag)
                        .font(Theme.mono(10, bold: true))
                        .tracking(0.8)
                        .foregroundStyle(hero.isInUse ? Theme.active : Theme.creamDim)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(Self.heroProviderCaption(hero.account))
                    .font(Theme.mono(10, bold: true))
                    .tracking(0.8)
                    .foregroundStyle(Theme.creamFaint)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                if hero.isPinned {
                    // Room for the × AUTO button overlaid on this row (kept
                    // outside the hero's single VoiceOver element).
                    Color.clear.frame(width: 64, height: 1)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(FocusModel.percentText(hero.headroom))
                    .font(Theme.display(44, .bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(FocusModel.caption(hero.bindingKind, label: hero.bindingLabel))
                    .font(Theme.display(15))
                    .foregroundStyle(Theme.creamDim)
            }
            .padding(.top, 2)

            if !limits.isEmpty {
                Text(limits)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.creamDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * CGFloat(min(max(hero.usedFraction, 0), 1)))
                }
            }
            .frame(height: 5)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.heroAccessibilityLabel(hero, now: now))
        .accessibilityIdentifier("focusHero")
        .overlay(alignment: .topTrailing) {
            if hero.isPinned {
                Button {
                    onShowHero(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("AUTO")
                            .font(Theme.mono(10, bold: true))
                            .tracking(0.8)
                    }
                    .foregroundStyle(Theme.creamDim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to the account you're using")
                .accessibilityLabel("Back to the automatic account")
                .accessibilityIdentifier("focusHeroUnpin")
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    /// "CLAUDE". The plan is shown as its own tag (`PlanTagView`, as on the
    /// cards) next to the name, never repeated here.
    static func heroProviderCaption(_ account: AccountRecord) -> String {
        account.provider.displayName.uppercased()
    }

    /// An in-use line's prefix: the provider only ("ChatGPT: "); the plan is
    /// the tag after the name.
    static func linePrefix(_ account: AccountRecord) -> String {
        "\(account.provider.displayName): "
    }

    /// The switch line's action: show the advised TARGET as the hero — the
    /// same pin an entry click sets; the hero's × AUTO returns.
    static func showSwitchTarget(_ advice: SwitchAdvice, onShowHero: (UUID?) -> Void) {
        onShowHero(advice.toAccountID)
    }

    static func switchLineAccessibilityLabel(_ advice: SwitchAdvice) -> String {
        "Show \(advice.toLabel)"
    }

    /// "Claude", or "Claude Max 20x" once the plan is known.
    static func providerAndPlan(_ account: AccountRecord) -> String {
        guard let plan = account.effectivePlan else { return account.provider.displayName }
        return "\(account.provider.displayName) \(plan.displayName)"
    }

    static func tagText(_ tag: FocusModel.Hero.Tag) -> String? {
        switch tag {
        case .inUse: "IN USE"
        case .lastUsed: "LAST USED"
        case .none: nil
        }
    }

    static func heroAccessibilityLabel(_ hero: FocusModel.Hero, now: Date) -> String {
        var parts: [String] = [hero.account.label]
        switch hero.tag {
        case .inUse: parts.append("in use")
        case .lastUsed: parts.append("last used")
        case .none: break
        }
        parts.append(Self.providerAndPlan(hero.account))
        let percent: String = FocusModel.percentText(hero.headroom)
        parts.append("\(percent) \(FocusModel.caption(hero.bindingKind, label: hero.bindingLabel))")
        if let resetsAt = hero.resetsAt {
            parts.append("resets \(UsageFormatters.relativeReset(resetsAt, relativeTo: now))")
        }
        for limit in hero.otherLimits {
            let percent = Int((limit.headroom * 100).rounded())
            parts.append("\(percent) percent of the \(limit.kind.spokenName(label: limit.label)) limit left")
        }
        if hero.isPinned {
            parts.append("chosen by you")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Lines

    /// A row that shows its account as the hero when it can be one; plain
    /// otherwise. VoiceOver: "Show <name>" with the row's content as value.
    @ViewBuilder
    private func showButton<Content: View>(
        id: UUID,
        name: String,
        canBeHero: Bool,
        spoken: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if canBeHero {
            Button {
                onShowHero(id)
            } label: {
                content().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Show \(name)")
            .accessibilityValue(spoken)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
        } else {
            content()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name), \(spoken)")
                .accessibilityIdentifier(identifier)
        }
    }

    private func inUseLine(_ line: FocusModel.Line) -> some View {
        HStack(spacing: 10) {
            showButton(
                id: line.presentation.id,
                name: line.account.label,
                canBeHero: line.canBeHero,
                spoken: "\(Self.providerAndPlan(line.account)), in use, "
                    + Self.spokenValue(line.value, snapshot: line.presentation.snapshot),
                identifier: "focusLine.\(line.presentation.id)"
            ) {
                HStack(spacing: 10) {
                    // The plan tag only where it fits; the name truncates
                    // before the tag is allowed to crowd it.
                    ViewThatFits(in: .horizontal) {
                        inUseName(line.account, planTag: PlanChoice.tag(for: line.account))
                        inUseName(line.account, planTag: nil)
                    }
                    // The cards' IN USE pill — one component everywhere. Lines
                    // exist only for `.inUse` phases, so with in-use detection
                    // off there is no line and no pill.
                    InUseMarkerContent(phase: .inUse(age: 0), date: now, style: .pillOnly)
                    Spacer(minLength: 8)
                    lineValue(line)
                }
            }

            if case let .state(state) = line.value {
                // Outside the row's button, as on entries: the card's badge
                // and, for re-authentication, its Sign In.
                AccountStateBadge(
                    state: state,
                    style: .compact,
                    now: now,
                    onReauthenticate: { onReauthenticate(line.presentation.id) }
                )
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 10)
    }

    private func inUseName(_ account: AccountRecord, planTag: String?) -> some View {
        HStack(spacing: 0) {
            Text(Self.linePrefix(account))
                .font(Theme.display(14))
                .foregroundStyle(Theme.creamDim)
                .fixedSize()
            Text(account.label)
                .font(Theme.display(14, .semibold))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
                .truncationMode(.tail)
            if let planTag {
                PlanTagView(tag: planTag)
                    .padding(.leading, 8)
            }
        }
    }

    @ViewBuilder
    private func lineValue(_ line: FocusModel.Line) -> some View {
        switch line.value {
        case let .headroom(headroom, _):
            Text(FocusModel.lineRight(headroom: headroom, resetsAt: line.resetsAt, now: now))
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.tierColor(usedFraction: 1 - headroom))
                .fixedSize()
        default:
            valueText(line.value)
        }
    }

    private func warningLine(_ warning: FocusModel.Warning) -> some View {
        let text: String = FocusModel.warningText(
            label: warning.account.label,
            headroom: warning.headroom,
            kind: warning.kind,
            windowLabel: warning.label
        )
        let reset: String? = FocusModel.resetText(warning.resetsAt, now: now)
        let percent = Int((warning.headroom * 100).rounded())
        var spoken: String = "nearly spent, \(percent) percent of the "
            + "\(warning.kind.spokenName(label: warning.label)) limit left"
        if let resetsAt = warning.resetsAt {
            spoken += ", resets \(UsageFormatters.relativeReset(resetsAt, relativeTo: now))"
        }
        return showButton(
            id: warning.presentation.id,
            name: warning.account.label,
            canBeHero: true,
            spoken: spoken,
            identifier: "focusWarning.\(warning.presentation.id)"
        ) {
            HStack(spacing: 10) {
                Text(text)
                    .font(Theme.display(14))
                    .foregroundStyle(Theme.crit)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let reset {
                    Text(reset)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.crit)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 10)
    }

    private func switchLine(_ advice: SwitchAdvice) -> some View {
        Button {
            Self.showSwitchTarget(advice, onShowHero: onShowHero)
        } label: {
            switchLineContent(advice).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(advice.toLabel)")
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.switchLineAccessibilityLabel(advice))
        .accessibilityValue(SwitchAdviceCopy.spokenHeader(advice))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("focusSwitch.\(advice.provider)")
    }

    private func switchLineContent(_ advice: SwitchAdvice) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Text("Next \(advice.provider.displayName): ")
                    .font(Theme.display(14))
                    .foregroundStyle(Theme.creamDim)
                    .fixedSize()
                Text(advice.toLabel)
                    .font(Theme.display(14, .semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text("\(SwitchAdviceCopy.percent(advice))% left →")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.active)
                .fixedSize()
        }
    }

    // MARK: Entries

    @ViewBuilder
    private func entryView(_ entry: FocusModel.Entry) -> some View {
        HStack(spacing: 6) {
            showButton(
                id: entry.presentation.id,
                name: entry.account.label,
                canBeHero: entry.canBeHero,
                spoken: "\(entry.account.provider.displayName), "
                    + Self.spokenValue(entry.value, snapshot: entry.presentation.snapshot),
                identifier: "focusEntry.\(entry.presentation.id)"
            ) {
                HStack(spacing: 6) {
                    providerDot(entry.account.provider, size: 6)
                    Text(entry.account.label)
                        .font(Theme.display(12.5))
                        .foregroundStyle(entry.isDimmed ? Theme.creamFaint : Theme.creamDim)
                        .lineLimit(1)
                    switch entry.value {
                    case .state:
                        EmptyView()
                    default:
                        valueText(entry.value)
                    }
                }
            }

            if case let .state(state) = entry.value {
                // The card's own badge — same text, and the same Sign In
                // callback for an account that needs re-authentication.
                AccountStateBadge(
                    state: state,
                    style: .compact,
                    now: now,
                    onReauthenticate: { onReauthenticate(entry.presentation.id) }
                )
            }
        }
    }

    @ViewBuilder
    private func valueText(_ value: FocusModel.Value) -> some View {
        switch value {
        case let .headroom(headroom, _):
            Text(FocusModel.percentText(headroom))
                .font(Theme.display(12.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.cream)
        case let .spent(cents):
            Text(FocusModel.dollarsText(cents: cents))
                .font(Theme.display(12.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.cream)
        case .paused:
            Text("paused")
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.creamFaint)
        case .noData:
            Text("—")
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.creamFaint)
        case .state:
            EmptyView()
        }
    }

    /// `snapshot` supplies the binding window's own name (Fable's label).
    static func spokenValue(_ value: FocusModel.Value, snapshot: UsageSnapshot? = nil) -> String {
        switch value {
        case let .headroom(headroom, kind):
            let percent: Int = Int((headroom * 100).rounded())
            let label: String? = snapshot?.window(for: kind)?.label
            return "\(percent) percent of the \(kind.spokenName(label: label)) limit left"
        case let .spent(cents):
            return "\(FocusModel.dollarsText(cents: cents)) spent"
        case .paused:
            return "paused"
        case .noData:
            return "no current data"
        case let .state(state):
            switch state {
            case .stale: return "stale"
            case .reauthenticationRequired: return "sign-in needed"
            case .rateLimited: return "rate limited"
            case .integrationChanged: return "needs update"
            case .unavailable: return "unavailable"
            case .loading: return "refreshing"
            case .current: return "current"
            }
        }
    }

    // MARK: Pieces

    private var allPausedNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("All accounts are paused")
                .font(Theme.display(15, .semibold))
                .foregroundStyle(Theme.cream)
            Text("Resume one in Settings to track it again.")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 8)
        // Nothing follows it: paused accounts are not listed in Focus.
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private func providerDot(_ provider: Provider, size: CGFloat) -> some View {
        Circle()
            .fill(provider.markAccent)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Left-to-right rows that wrap when the next item does not fit. An item
/// wider than the whole row gets the row to itself, clipped to it.
struct FocusFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    /// Origins for items of `sizes` in a row `width` wide (nil → one line),
    /// plus the total size. Pure, so the wrapping rule is testable.
    static func arrange(
        sizes: [CGSize],
        width: CGFloat?,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for size in sizes {
            let itemWidth: CGFloat = width.map { min(size.width, $0) } ?? size.width
            if let width, x > 0, x + itemWidth > width {
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            let right: CGFloat = x + itemWidth
            widest = max(widest, right)
            x = right + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        let height: CGFloat = sizes.isEmpty ? 0 : y + rowHeight
        return (origins, CGSize(width: width ?? widest, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes: [CGSize] = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.arrange(
            sizes: sizes,
            width: proposal.width,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes: [CGSize] = subviews.map { $0.sizeThatFits(.unspecified) }
        let arranged = Self.arrange(
            sizes: sizes,
            width: bounds.width,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
        for index in subviews.indices {
            let origin: CGPoint = arranged.origins[index]
            let width: CGFloat = min(sizes[index].width, bounds.width)
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(width: width, height: sizes[index].height)
            )
        }
    }
}
