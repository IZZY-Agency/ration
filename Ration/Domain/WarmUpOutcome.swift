import Foundation

/// What one Claude warm-up attempt ended as. Kept per account (the newest
/// `WarmUpOutcome.capacity`) so a refused keep-alive leaves a trace outside
/// the transient popover row.
///
/// PRIVACY: status codes and closed-set kinds only. No response body, no
/// organization / conversation / message ids, no model string. Even an SSE
/// error event's `type` is never stored as provider text: it is mapped onto
/// the closed `StreamErrorKind` set, anything unrecognised becoming `unknown`.
struct WarmUpOutcome: Codable, Equatable, Sendable {
    /// The documented Anthropic API error types. A stream error whose type is
    /// not one of these is `unknown`, so no provider string (a token, an id,
    /// a word of content) can reach `accounts.json`.
    enum StreamErrorKind: String, Codable, CaseIterable, Sendable {
        case invalidRequest = "invalid_request_error"
        case authentication = "authentication_error"
        case billing = "billing_error"
        case permission = "permission_error"
        case notFound = "not_found_error"
        case requestTooLarge = "request_too_large"
        case rateLimit = "rate_limit_error"
        case api = "api_error"
        case timeout = "timeout_error"
        case overloaded = "overloaded_error"
        case unknown

        /// nil for no error; a recognised kind; else `unknown`.
        static func recognising(_ raw: String?) -> StreamErrorKind? {
            guard let raw else { return nil }
            guard let kind = StreamErrorKind(rawValue: raw) else { return .unknown }
            return kind
        }

        /// A refusal that says the session is signed out.
        var meansSignedOut: Bool {
            self == .authentication || self == .permission
        }
    }

    enum Kind: String, Codable, Sendable {
        /// The completion POST returned 2xx and its stream showed no error.
        case sent
        /// Warm-up was due but deliberately not sent (`skipReason`).
        case skipped
        /// Claude answered with a non-2xx status (`httpStatus`).
        case rejected
        /// The completion POST returned 2xx, but its stream carried an error
        /// event (`streamErrorType`).
        case rejectedInStream
        /// Nothing usable came back (transport, timeout, discovery).
        case failed
    }

    enum ErrorKind: String, Codable, Sendable {
        /// 401 / 403: the session is signed out.
        case authentication
        /// Any other non-2xx status.
        case http
        /// An error event inside a 2xx completion stream.
        case stream
        case transport
        case timedOut
        case organizationNotFound
        case modelNotFound
        case other
    }

    enum SkipReason: String, Codable, Sendable {
        /// The weekly allowance was spent (`AutoStartPolicy.blockedByWeeklyLimit`).
        case weeklyLimitSpent
        /// The triggering snapshot carried no organization (fail closed).
        case organizationUnknown
        /// The warm-up switch went off after the attempt was reserved.
        case warmUpTurnedOff
    }

    /// How many outcomes an account keeps.
    static let capacity = 5

    let at: Date
    let kind: Kind
    let httpStatus: Int?
    let errorKind: ErrorKind?
    let skipReason: SkipReason?
    let streamErrorType: StreamErrorKind?
    /// Whether the once-per-window reservation (`lastAutoStartedAt`) had
    /// already been taken when this outcome happened — i.e. whether it cost
    /// the account its warm-up for this window.
    let reserved: Bool

    init(
        at: Date,
        kind: Kind,
        httpStatus: Int? = nil,
        errorKind: ErrorKind? = nil,
        skipReason: SkipReason? = nil,
        streamErrorType: StreamErrorKind? = nil,
        reserved: Bool
    ) {
        self.at = at
        self.kind = kind
        self.httpStatus = httpStatus
        self.errorKind = errorKind
        self.skipReason = skipReason
        self.streamErrorType = streamErrorType
        self.reserved = reserved
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Date.self, forKey: .at)
        kind = try container.decode(Kind.self, forKey: .kind)
        httpStatus = try? container.decodeIfPresent(Int.self, forKey: .httpStatus)
        errorKind = try? container.decodeIfPresent(ErrorKind.self, forKey: .errorKind)
        skipReason = try? container.decodeIfPresent(SkipReason.self, forKey: .skipReason)
        let rawType = try? container.decodeIfPresent(String.self, forKey: .streamErrorType)
        streamErrorType = StreamErrorKind.recognising(rawType)
        reserved = (try? container.decodeIfPresent(Bool.self, forKey: .reserved)) ?? false
    }

    static func sent(at date: Date, status: Int, reserved: Bool = true) -> WarmUpOutcome {
        WarmUpOutcome(at: date, kind: .sent, httpStatus: status, reserved: reserved)
    }

    static func rejectedInStream(
        at date: Date,
        status: Int,
        type: StreamErrorKind,
        reserved: Bool = true
    ) -> WarmUpOutcome {
        WarmUpOutcome(
            at: date,
            kind: .rejectedInStream,
            httpStatus: status,
            errorKind: .stream,
            streamErrorType: type,
            reserved: reserved
        )
    }

    /// The ONE classification of a completion POST that landed (2xx): sent,
    /// or refused inside its stream. Every send path (the automatic warm-up
    /// and the debug send) goes through it, so none can call a refusal a
    /// started window.
    static func landed(
        _ receipt: ClaudeMessageSender.Receipt,
        at date: Date,
        reserved: Bool
    ) -> WarmUpOutcome {
        if let type = receipt.streamErrorType {
            return .rejectedInStream(at: date, status: receipt.status, type: type, reserved: reserved)
        }
        return .sent(at: date, status: receipt.status, reserved: reserved)
    }

    static func skipped(_ reason: SkipReason, at date: Date, reserved: Bool) -> WarmUpOutcome {
        WarmUpOutcome(at: date, kind: .skipped, skipReason: reason, reserved: reserved)
    }

    /// A thrown send / discovery error, reduced to its status and kind.
    static func failure(_ error: Error, at date: Date, reserved: Bool) -> WarmUpOutcome {
        if case let ClaudeMessageSender.SendError.rejected(status) = error {
            let isAuth = status == 401 || status == 403
            return WarmUpOutcome(
                at: date,
                kind: .rejected,
                httpStatus: status,
                errorKind: isAuth ? .authentication : .http,
                reserved: reserved
            )
        }
        return WarmUpOutcome(
            at: date,
            kind: .failed,
            errorKind: failureKind(error),
            reserved: reserved
        )
    }

    private static func failureKind(_ error: Error) -> ErrorKind {
        if let sendError = error as? ClaudeMessageSender.SendError {
            switch sendError {
            case .transport: return .transport
            case .organizationNotFound: return .organizationNotFound
            case .modelNotFound: return .modelNotFound
            case .rejected: return .http
            }
        }
        if let clientError = error as? WebUsageClientError, clientError == .timedOut {
            return .timedOut
        }
        return .other
    }

    /// Same outcome apart from its time — used to fold repeats.
    func matches(_ other: WarmUpOutcome) -> Bool {
        kind == other.kind
            && httpStatus == other.httpStatus
            && errorKind == other.errorKind
            && skipReason == other.skipReason
            && streamErrorType == other.streamErrorType
            && reserved == other.reserved
    }

    /// The ring after recording `outcome`, oldest first, at most `capacity`.
    /// Returns nil when nothing changes.
    ///
    /// An UNRESERVED outcome (a discovery failure, a weekly-limit hold) is
    /// re-evaluated on every poll while it lasts; a repeat of the newest entry
    /// is folded into it (the entry keeps the time it started) instead of
    /// pushing real sends out of the ring and rewriting `accounts.json` every
    /// few minutes. A reserved outcome happens at most once per window and is
    /// always kept.
    static func recording(
        _ outcome: WarmUpOutcome,
        into ring: [WarmUpOutcome]
    ) -> [WarmUpOutcome]? {
        if !outcome.reserved, let newest = ring.last, newest.matches(outcome) {
            return nil
        }
        var updated = ring
        updated.append(outcome)
        if updated.count > capacity {
            updated.removeFirst(updated.count - capacity)
        }
        return updated
    }
}
