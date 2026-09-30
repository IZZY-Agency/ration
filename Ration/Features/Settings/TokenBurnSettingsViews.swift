import AppKit
import SwiftUI

/// Settings › General › Features: the "Claude plan value" row (spec §4.1).
/// Its switch is the model's state — on means consented and granted — so
/// turning it on opens the consent sheet, and turning it off asks before it
/// deletes what Ration counted.
struct TokenBurnFeatureRow: View {
    @ObservedObject var model: TokenBurnModel
    @State private var consenting = false
    @State private var confirmingForget = false
    @State private var forgetFailed = false

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.isEnabled },
            set: { on in
                if on { consenting = true } else { confirmingForget = true }
            }
        )) {
            Text(LocalizedStringResource.tokenBurnFeatureTitle)
        }
        .accessibilityIdentifier("featureToggle-claudePlanValue")
        .sheet(isPresented: $consenting) {
            TokenBurnConsentSheet { folder in
                consenting = false
                guard let folder else { return }
                Task { _ = await model.enable(folder: folder) }
            }
        }
        .confirmationDialog(Text(LocalizedStringResource.tokenBurnForgetQuestion), isPresented: $confirmingForget) {
            Button(role: .destructive) {
                Task { forgetFailed = !(await model.stopAndForget()) }
            } label: {
                Text(LocalizedStringResource.tokenBurnForget)
            }
        }

        Text(LocalizedStringResource.tokenBurnFeatureSummary)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.creamDim)

        if model.isEnabled {
            TokenBurnStatusView(model: model, onGrantAgain: { consenting = true })
        } else if let problem = model.enableProblem {
            Text(problem == .noSignIn ? LocalizedStringResource.tokenBurnEnableNoSignIn : LocalizedStringResource.tokenBurnEnableFailed)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.warn)
                .accessibilityIdentifier("tokenBurnEnableProblem")
        }
        if forgetFailed {
            Text(LocalizedStringResource.tokenBurnForgetFailed)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.crit)
        }
    }
}

/// What is granted and how far counting got.
struct TokenBurnStatusView: View {
    @ObservedObject var model: TokenBurnModel
    let onGrantAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.phase {
            case .counting(let done, let total):
                Text(LocalizedStringResource.tokenBurnCounting(done, total))
                    .foregroundStyle(Theme.creamDim)
            case .grantLost:
                Text(LocalizedStringResource.tokenBurnGrantLost)
                    .foregroundStyle(Theme.warn)
                Button(action: onGrantAgain) { Text(LocalizedStringResource.tokenBurnGrantAgain) }
                    .accessibilityIdentifier("tokenBurnGrantAgain")
            case .failed:
                Text(LocalizedStringResource.tokenBurnFailed)
                    .foregroundStyle(Theme.crit)
            case .ready, .off:
                EmptyView()
            }
            if let folderName = model.folderName {
                Text(LocalizedStringResource.tokenBurnFolder(folderName))
                    .foregroundStyle(Theme.creamDim)
            }
            if let countedThrough = model.countedThrough {
                Text(LocalizedStringResource.tokenBurnCountedThrough(countedThrough.formatted(date: .abbreviated, time: .shortened)))
                    .foregroundStyle(Theme.creamDim)
            }
            let unreadable = model.lastReport?.filesUnreadable ?? 0
            let malformed = model.summary?.malformedLines ?? 0
            let oversized = model.summary?.oversizedLines ?? 0
            if unreadable + malformed + oversized > 0 {
                Text(LocalizedStringResource.tokenBurnSkipped(unreadable, malformed, oversized))
                    .foregroundStyle(Theme.creamDim)
            }
        }
        .font(Theme.mono(12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tokenBurnStatus")
    }
}

/// Spec §4.1 and §10: what Ration opens, keeps and never keeps, before any
/// file is touched; then the folder picker. `onDone(nil)` on cancel.
struct TokenBurnConsentSheet: View {
    let onDone: (URL?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringResource.tokenBurnConsentTitle)
                .font(Theme.display(17, .semibold))
            ForEach(Array(Self.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(Theme.mono(12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button { onDone(nil) } label: { Text(LocalizedStringResource.tokenBurnConsentCancel) }
                    .keyboardShortcut(.cancelAction)
                Button { onDone(Self.chooseFolder()) } label: { Text(LocalizedStringResource.tokenBurnConsentChoose) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("tokenBurnConsentChoose")
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    static let paragraphs: [LocalizedStringResource] = [
        .tokenBurnConsentReads, .tokenBurnConsentKeeps, .tokenBurnConsentNever,
        .tokenBurnConsentSignInFile, .tokenBurnConsentLocal,
    ]

    /// The open panel, pre-pointed at `~/.claude/projects`.
    @MainActor
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = ClaudeCodeConfigFile.userHome.appending(path: ".claude/projects", directoryHint: .isDirectory)
        panel.message = String(localized: LocalizedStringResource.tokenBurnPanelMessage)
        panel.prompt = String(localized: LocalizedStringResource.tokenBurnPanelPrompt)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
