import Foundation

/// What a NEWLY added account starts with. Existing accounts keep their
/// stored value; a legacy record without the key still decodes as off.
enum WarmUpDefaults {
    static func autoStartForNewAccount(provider: Provider) -> Bool {
        provider == .claude
    }

    /// Shown wherever a Claude account is connected — default-on sends a real
    /// message, so it must never be a surprise.
    static let newClaudeAccountDisclosure =
        "Warm-up is on: Ration will start your 5-hour window automatically. Turn it off per account under Auto-start 5h window in Settings."
}
