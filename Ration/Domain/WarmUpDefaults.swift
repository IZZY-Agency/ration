import Foundation

/// What a NEWLY added account starts with. Existing accounts keep their
/// stored value; a legacy record without the key still decodes as off.
enum WarmUpDefaults {
    static func autoStartForNewAccount(provider: Provider) -> Bool {
        provider == .claude
    }

    /// Shown wherever a Claude account is connected — default-on sends a real
    /// message, so it must never be a surprise. While the global Claude
    /// warm-up switch is off nothing is sent, so the "Warm-up is on" promise
    /// would be false and the off wording is shown instead.
    static func newClaudeAccountDisclosure(warmUpEnabled: Bool, locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = warmUpEnabled ? .warmUpDisclosureOn : .warmUpDisclosureOff
        return resource.string(in: locale)
    }
}
