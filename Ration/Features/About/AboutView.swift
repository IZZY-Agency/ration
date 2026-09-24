import AppKit
import SwiftUI

struct AboutView: View {
    let info: AboutAppInfo

    init(info: AboutAppInfo = .current) {
        self.info = info
    }

    var body: some View {
        VStack(spacing: 13) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            Text(info.displayName)
                .font(Theme.display(24, .bold))
                .foregroundStyle(Theme.cream)
                .accessibilityIdentifier("aboutProductName")

            Text(info.versionText)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.gold)
                .accessibilityIdentifier("aboutVersion")

            Text(info.copyrightText)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.creamFaint)
                .accessibilityIdentifier("aboutCopyright")

            HStack(spacing: 8) {
                ForEach(Array(AppLinks.all.enumerated()), id: \.element.url) { index, entry in
                    if index > 0 {
                        Text("·")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.creamFaint)
                            .accessibilityHidden(true)
                    }
                    Link(destination: entry.url) {
                        Text(entry.title)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.gold)
                            .underline()
                    }
                    .accessibilityIdentifier(entry.accessibilityIdentifier)
                }
            }
            .padding(.top, 2)
        }
        .padding(28)
        .frame(width: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }
}
