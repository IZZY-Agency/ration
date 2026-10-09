import SwiftUI

/// Settings › Display › Rings: a row per account, a checkbox per surface
/// (menu bar, ring bar), or the reason it has no gauge.
struct RingsGrid: View {
    let groups: [RingsGridGroup]
    let onSet: (GaugeSurface, UUID, Bool) -> Void

    static let columnWidth: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("Account")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(GaugeSurface.allCases, id: \.self) { surface in
                    Text(Self.title(surface))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.creamDim)
                        .multilineTextAlignment(.center)
                        .frame(width: Self.columnWidth)
                }
            }
            ForEach(groups) { group in
                Text(verbatim: group.source.displayName.uppercased())
                    .font(Theme.mono(10.5, bold: true))
                    .foregroundStyle(group.source.accent)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.rows) { row in
                    rowView(row)
                }
            }
            Text(LocalizedStringResource.ringsGridNote)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func rowView(_ row: RingsGridRow) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: row.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let reason = Self.reason(row.state) {
                    Text(reason)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.creamFaint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(GaugeSurface.allCases, id: \.self) { surface in
                cell(row, surface)
                    .frame(width: Self.columnWidth)
            }
        }
        .foregroundStyle(Self.reason(row.state) == nil ? Theme.cream : Theme.creamFaint)
    }

    @ViewBuilder
    private func cell(_ row: RingsGridRow, _ surface: GaugeSurface) -> some View {
        if case .available(let menuBar, let ringBar) = row.state {
            Toggle(isOn: Binding(
                get: { surface == .menuBar ? menuBar : ringBar },
                set: { onSet(surface, row.id, $0) }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(Self.cellLabel(row.label, surface)))
                .accessibilityIdentifier("ringsGrid-\(surface.rawValue)-\(row.id.uuidString)")
        } else {
            Text(verbatim: "—")
                .foregroundStyle(Theme.creamFaint)
                .accessibilityHidden(true)
        }
    }

    static func title(_ surface: GaugeSurface, locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = surface == .menuBar ? .ringsGridMenuBar : .ringsGridRingBar
        return resource.string(in: locale)
    }

    static func cellLabel(_ label: String, _ surface: GaugeSurface, locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = surface == .menuBar ? .ringsGridCellMenuBar(label) : .ringsGridCellRingBar(label)
        return resource.string(in: locale)
    }

    static func reason(_ state: RingsGridRow.State, locale: Locale = .current) -> String? {
        let resource: LocalizedStringResource? = switch state {
        case .available: nil
        case .noLimit: .ringsGridNoLimit
        case .paused: .ringsGridPaused
        case .noBudget: .ringsGridNoBudget
        }
        return resource?.string(in: locale)
    }
}
