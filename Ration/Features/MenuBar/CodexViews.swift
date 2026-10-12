import SwiftUI

/// A ChatGPT card's Codex control, on the name line (spec §4.4; teal): a
/// filled tag on the account Codex uses now, an outlined button on the
/// other linked, unpaused ones.
struct CodexCardRow: View {
    let state: CodexCardState
    let accountLabel: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .current:
            chip(Text(LocalizedStringResource.codexCardCurrent), foreground: Theme.onCodex, fill: Theme.codex)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(LocalizedStringResource.codexCardCurrentAccessibility))
                .accessibilityIdentifier("codexCurrentTag")
        case .canSwitch(let sameWorkspace):
            let help = CodexSwitchHelp.text(to: accountLabel, sameWorkspace: sameWorkspace)
            Button(action: action) {
                chip(Text(LocalizedStringResource.codexCardUse), foreground: Theme.codex, fill: nil)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
            .help(Text(help))
            .accessibilityLabel(Text(help))
            .accessibilityIdentifier("useInCodexButton")
        case .switching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(LocalizedStringResource.codexCardSwitching)
                    .font(Theme.mono(10))
                    .tracking(1)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .foregroundStyle(Theme.codex)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Filled (`fill` set) or outlined in `foreground`.
    private func chip(_ text: Text, foreground: Color, fill: Color?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: CodexSymbol.name)
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

/// Codex's glyph on its controls: code brackets, where Claude Code has a
/// terminal.
enum CodexSymbol {
    static let name = "chevron.left.forwardslash.chevron.right"
}

/// What a switch button says aloud and in its tooltip: another seat of the
/// workspace Codex is on warns that running sessions may follow (spec §1,
/// §4.5).
enum CodexSwitchHelp {
    static func text(to label: String, sameWorkspace: Bool) -> LocalizedStringResource {
        sameWorkspace ? .codexCardUseSameWorkspaceAccessibility(label) : .codexCardUseAccessibility(label)
    }
}

/// The Focus layout's Codex line: which account Codex is on, and a button
/// to the account with the most room.
struct CodexFocusLineView: View {
    let line: CodexFocusLine
    let busy: Bool
    let action: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: CodexSymbol.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.codex)
                .accessibilityHidden(true)
            // Plain text: an account label must not turn into a link.
            Text(verbatim: String(localized: LocalizedStringResource.codexFocusOn(line.currentLabel)))
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
                        Text(verbatim: String(localized: LocalizedStringResource.codexFocusSwitch(target.label)))
                            .font(Theme.mono(10))
                            .tracking(1)
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(Theme.codex)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.codex, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(CodexSwitchHelp.text(to: target.label, sameWorkspace: target.sameWorkspace)))
                    .accessibilityLabel(Text(CodexSwitchHelp.text(to: target.label, sameWorkspace: target.sameWorkspace)))
                    .accessibilityIdentifier("focusCodexSwitch")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("focusCodexLine")
    }
}

/// The line under the ChatGPT section header; a click opens Settings.
struct CodexStatusLineView: View {
    let line: CodexStatusLine
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                // Plain text: an email address must not turn into a mail link.
                // Wraps rather than cutting a caveat's "restart" off; a short
                // line keeps its single line.
                Text(verbatim: String(localized: text))
                    .font(Theme.mono(11))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 13)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("codexStatusLine")
    }

    var text: LocalizedStringResource {
        switch line {
        case .needsAttention: .codexStatusNeedsAttention
        case .paused: .codexStatusPaused
        case .failed: .codexStatusFailed
        case .noRoom: .codexStatusNoRoom
        case .waiting: .codexStatusWaiting
        case .stale(let account): .codexStatusStale(account)
        case .damaged: .codexStatusDamaged
        case .rememberPrompt(let email): .codexStatusRemember(email)
        case .switched(let to, _, _, true): .codexStatusSwitchedSameWorkspace(to)
        case .switched(let to, _, false, false): .codexStatusSwitchedUnverified(to)
        case .switched(let to, true, true, false): .codexStatusSwitchedAutomatic(to)
        case .switched(let to, false, true, false): .codexStatusSwitchedManual(to)
        }
    }

    var symbol: String {
        switch line {
        case .needsAttention, .failed, .stale, .damaged: "exclamationmark.triangle"
        case .switched where Self.hasCaveat(line): "exclamationmark.triangle"
        case .paused: "pause.circle"
        case .noRoom: "gauge.with.dots.needle.100percent"
        case .waiting: "hourglass"
        case .rememberPrompt: "plus.circle"
        case .switched: CodexSymbol.name
        }
    }

    /// Red when Codex is stuck, amber when the user has something to do
    /// (a switch with a caveat among them), quiet while waiting, Codex's
    /// teal for a plain switch.
    var color: Color {
        switch line {
        case .needsAttention, .failed: Theme.crit
        case .stale, .damaged, .paused, .noRoom: Theme.warn
        case .switched where Self.hasCaveat(line): Theme.warn
        case .waiting, .rememberPrompt: Theme.creamDim
        case .switched: Theme.codex
        }
    }

    /// A switch whose copy carries a caveat to act on: Codex refreshed the
    /// sign-in meanwhile, or another seat of the workspace, which
    /// running sessions may follow.
    static func hasCaveat(_ line: CodexStatusLine) -> Bool {
        guard case .switched(_, _, let verified, let sameWorkspace) = line else { return false }
        return !verified || sameWorkspace
    }
}
