import SwiftUI

/// A Claude card's Claude Code control, on the name line (spec §4.4;
/// lavender): a filled tag on the account Claude Code uses now, an outlined
/// button on the others.
struct ClaudeCodeCardRow: View {
    let state: ClaudeCodeCardState
    let accountLabel: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .current:
            chip(Text(LocalizedStringResource.claudeCodeCardCurrent), foreground: Theme.onClaudeCode, fill: Theme.claudeCode)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(LocalizedStringResource.claudeCodeCardCurrentAccessibility))
                .accessibilityIdentifier("claudeCodeCurrentTag")
        case .canSwitch:
            Button(action: action) {
                chip(Text(LocalizedStringResource.claudeCodeCardUse), foreground: Theme.claudeCode, fill: nil)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
            .help(Text(LocalizedStringResource.claudeCodeCardUseAccessibility(accountLabel)))
            .accessibilityLabel(Text(LocalizedStringResource.claudeCodeCardUseAccessibility(accountLabel)))
            .accessibilityIdentifier("useInClaudeCodeButton")
        case .switching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(LocalizedStringResource.claudeCodeCardSwitching)
                    .font(Theme.mono(10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .foregroundStyle(Theme.claudeCode)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Filled (`fill` set) or outlined in `foreground`.
    private func chip(_ text: Text, foreground: Color, fill: Color?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            text
                .font(Theme.mono(10))
                .tracking(1)
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(fill ?? .clear))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(fill ?? foreground, lineWidth: 1))
    }
}

/// The Focus layout's Claude Code line: which account Claude Code is on, and
/// a button to the account with the most room.
struct ClaudeCodeFocusLineView: View {
    let line: ClaudeCodeFocusLine
    let busy: Bool
    let action: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.claudeCode)
                .accessibilityHidden(true)
            // Plain text: an organization name must not turn into a link.
            Text(verbatim: String(localized: LocalizedStringResource.claudeCodeFocusOn(line.currentLabel)))
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let target = line.target {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        action(target.accountID)
                    } label: {
                        // Truncates rather than pushing the line past the
                        // popover when the account's name is long.
                        Text(verbatim: String(localized: LocalizedStringResource.claudeCodeFocusSwitch(target.label)))
                            .font(Theme.mono(10))
                            .tracking(1)
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(Theme.claudeCode)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.claudeCode, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(LocalizedStringResource.claudeCodeCardUseAccessibility(target.label)))
                    .accessibilityLabel(Text(LocalizedStringResource.claudeCodeCardUseAccessibility(target.label)))
                    .accessibilityIdentifier("focusClaudeCodeSwitch")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("focusClaudeCodeLine")
    }
}

/// The line under the Claude section header; a click opens Settings.
struct ClaudeCodeStatusLineView: View {
    let line: ClaudeCodeStatusLine
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                // Plain text: an organization name like "you@example.com's
                // Organization" must not turn into a mail link.
                Text(verbatim: String(localized: text))
                    .font(Theme.mono(11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 13)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("claudeCodeStatusLine")
    }

    private var text: LocalizedStringResource {
        switch line {
        case .needsAttention: .claudeCodeStatusNeedsAttention
        case .paused: .claudeCodeStatusPaused
        case .failed: .claudeCodeStatusFailed
        case .noRoom: .claudeCodeStatusNoRoom
        case .waiting: .claudeCodeStatusWaiting
        case .rememberPrompt(let organization): .claudeCodeStatusRemember(organization)
        case .switched(let to, true): .claudeCodeStatusSwitchedAutomatic(to)
        case .switched(let to, false): .claudeCodeStatusSwitchedManual(to)
        }
    }

    private var symbol: String {
        switch line {
        case .needsAttention, .failed: "exclamationmark.triangle"
        case .paused: "pause.circle"
        case .noRoom: "gauge.with.dots.needle.100percent"
        case .waiting: "hourglass"
        case .rememberPrompt: "plus.circle"
        case .switched: "terminal"
        }
    }

    private var color: Color {
        switch line {
        case .needsAttention, .failed: Theme.crit
        case .paused, .noRoom: Theme.warn
        case .waiting: Theme.creamDim
        case .rememberPrompt: Theme.creamDim
        case .switched: Theme.claudeCode
        }
    }
}
