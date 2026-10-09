import SwiftUI

/// Settings › Features: what Ration does beyond showing numbers.
struct FeaturesDetailView: View {
    @ObservedObject var settings: AppSettings
    var onSetFeature: (FeatureSwitch, Bool) -> Void = { _, _ in }
    /// One cell of the Show per provider grid.
    var onSetProviderShow: (ProviderShowItem, Provider, Bool) -> Void = { _, _, _ in }
    /// "Claude plan value"; nil (snapshots, tests) hides its row.
    var tokenBurn: TokenBurnModel? = nil

    var body: some View {
        Form {
            Section(SettingsSectionTitle.features) {
                ForEach(FeatureSwitch.allCases) { feature in
                    let features = settings.features
                    Toggle(
                        feature.title,
                        isOn: Self.featureBinding(feature, settings: settings, onSet: onSetFeature)
                    )
                    .disabled(!feature.isAvailable(in: features))
                    .accessibilityIdentifier("featureToggle-\(feature.rawValue)")

                    Text(feature.isAvailable(in: features) ? feature.summary : FeatureSwitch.switchAdviceNeedsInUseNote)
                        .font(Theme.mono(12))
                        .foregroundStyle(feature.isAvailable(in: features) ? Theme.creamDim : Theme.warn)
                }
                if let tokenBurn {
                    TokenBurnFeatureRow(model: tokenBurn)
                }
                ProviderShowGrid(settings: settings, onSet: onSetProviderShow)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
    }

    /// One Features row's toggle: reads the published switch, writes only
    /// through the callback (which persists via `AppModel`).
    static func featureBinding(
        _ feature: FeatureSwitch,
        settings: AppSettings,
        onSet: @escaping (FeatureSwitch, Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { feature.isOn(in: settings.features) },
            set: { onSet(feature, $0) }
        )
    }
}

/// Settings › Features › Show per provider: a row per item, a column per provider, a checkbox where the
/// provider has that item and a dash where it has none.
struct ProviderShowGrid: View {
    @ObservedObject var settings: AppSettings
    let onSet: (ProviderShowItem, Provider, Bool) -> Void

    static let columnWidth: CGFloat = 76

    var body: some View {
        let columns = ProviderShowItem.columns
        let show = settings.providerShowSwitches
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text(LocalizedStringResource.providerShowTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns) { provider in
                    Text(verbatim: provider.displayName)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.creamDim)
                        .frame(width: Self.columnWidth)
                }
            }
            ForEach(ProviderShowItem.allCases, id: \.self) { item in
                HStack(spacing: 0) {
                    Text(item.title())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(columns) { provider in
                        cell(item, provider, show: show)
                            .frame(width: Self.columnWidth)
                    }
                }
            }
            Text(LocalizedStringResource.providerShowNote)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cell(_ item: ProviderShowItem, _ provider: Provider, show: ProviderShow) -> some View {
        if item.applies(to: provider) {
            Toggle(isOn: Binding(
                get: { show.shows(item, for: provider) },
                set: { onSet(item, provider, $0) }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(LocalizedStringResource.providerShowCellLabel(item.title(), provider.displayName)))
                .accessibilityIdentifier("providerShow-\(provider.rawValue)-\(item.rawValue)")
        } else {
            Text(verbatim: "—")
                .foregroundStyle(Theme.creamFaint)
                .accessibilityLabel(Text(LocalizedStringResource.providerShowNone(item.title(), provider.displayName)))
        }
    }
}
