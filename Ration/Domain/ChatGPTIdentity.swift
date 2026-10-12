import Foundation

/// Who a ChatGPT web session is: the account (workspace) and the user in it.
/// Memory only, like `organizationID`: never written to `snapshots.json`.
///
/// The pair (`accountID`, `userID`) is what a Codex login links by: a Team
/// workspace shares its account id across seats, the user id tells the seats
/// apart. `email` and `planType` are display only.
struct ChatGPTIdentity: Equatable, Sendable {
    let accountID: String
    let userID: String
    let email: String?
    let planType: String?
}

extension ChatGPTIdentity {
    /// The ChatGPT fetch script's `identity` value, read leniently: anything
    /// but an object holding both ids as non-empty strings is no identity,
    /// never an error. `email` and `planType` are kept only as non-empty
    /// strings.
    init?(scriptValue: Any?) {
        guard
            let object = scriptValue as? [String: Any],
            let accountID = Self.text(object["accountID"]),
            let userID = Self.text(object["userID"])
        else { return nil }
        self.init(
            accountID: accountID,
            userID: userID,
            email: Self.text(object["email"]),
            planType: Self.text(object["planType"])
        )
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
