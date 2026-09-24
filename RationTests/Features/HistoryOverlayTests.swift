import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// The History window's multi-account overlay: which accounts a window kind can
/// legitimately compare, how their lines are labelled and coloured, and what the
/// chart must say out loud about the accounts it cannot draw.
final class HistoryOverlayTests: XCTestCase {

    // MARK: Fixtures

    private func account(
        _ provider: Provider,
        _ label: String,
        paused: Bool = false,
        order: Int = 0
    ) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: provider, label: label, webProfileID: UUID(),
            displayOrder: order, createdAt: Date(timeIntervalSince1970: 0),
            isPaused: paused
        )
    }

    private func window(_ kind: UsageWindowKind, _ label: String? = nil) -> UsageWindow {
        UsageWindow(kind: kind, remainingFraction: 0.5, resetsAt: nil, label: label)
    }

    /// A Claude Max presentation: Fable + 5h + weekly.
    private func claudeMax(_ label: String, paused: Bool = false) -> AccountPresentation {
        let record = account(.claude, label, paused: paused)
        return AccountPresentation(
            account: record,
            snapshot: UsageSnapshot(
                accountID: record.id, fetchedAt: Date(timeIntervalSince1970: 0),
                fiveHour: window(.fiveHour), weekly: window(.weekly),
                modelWeekly: window(.modelWeekly, "Fable")
            ),
            state: .current
        )
    }

    /// A non-Max Claude presentation: 5h + weekly, no Fable.
    private func claude(_ label: String, paused: Bool = false) -> AccountPresentation {
        let record = account(.claude, label, paused: paused)
        return AccountPresentation(
            account: record,
            snapshot: UsageSnapshot(
                accountID: record.id, fetchedAt: Date(timeIntervalSince1970: 0),
                fiveHour: window(.fiveHour), weekly: window(.weekly)
            ),
            state: .current
        )
    }

    /// A ChatGPT presentation carrying only a weekly window.
    private func chatGPT(_ label: String) -> AccountPresentation {
        let record = account(.chatGPT, label)
        return AccountPresentation(
            account: record,
            snapshot: UsageSnapshot(
                accountID: record.id, fetchedAt: Date(timeIntervalSince1970: 0),
                fiveHour: nil, weekly: window(.weekly)
            ),
            state: .current
        )
    }

    /// Cursor: dollars-based, so it owns no rolling windows at all.
    private func cursor(_ label: String) -> AccountPresentation {
        let record = account(.cursor, label)
        return AccountPresentation(account: record, snapshot: nil, state: .current)
    }

    private func buckets(days: [Int], consumed: Double = 0.2) -> [UsageHourlyBucket] {
        days.map { day in
            UsageHourlyBucket(
                hourStart: Date(timeIntervalSince1970: Double(day) * 86_400),
                tzOffsetSeconds: 0, consumed: consumed, minRemaining: 0.5, sampleCount: 1
            )
        }
    }

    // MARK: Available kinds

    func testAvailableKindsForAllAccountsIsTheUnionInCanonicalOrder() {
        let kinds = HistoryOverlay.availableKinds(
            presentations: [chatGPT("Work"), claudeMax("AI")], scope: .all
        )
        // Fable leads, exactly as the account card orders its columns.
        XCTAssertEqual(kinds, [.modelWeekly, .fiveHour, .weekly])
    }

    func testAvailableKindsForASingleAccountIsThatAccountsOwnKinds() {
        let work = chatGPT("Work")
        let kinds = HistoryOverlay.availableKinds(
            presentations: [claudeMax("AI"), work], scope: .account(work.id)
        )
        XCTAssertEqual(kinds, [.weekly])
    }

    func testAvailableKindsIsEmptyWhenOnlyCursorAccountsExist() {
        XCTAssertEqual(
            HistoryOverlay.availableKinds(presentations: [cursor("Cu")], scope: .all), []
        )
    }

    // MARK: Inclusion / exclusion

    func testIncludedKeepsOnlyAccountsOwningTheKindPreservingOrder() {
        let ai = claudeMax("AI")
        let personal = claude("Personal")
        let work = chatGPT("Work")
        let included = HistoryOverlay.included(
            presentations: [ai, personal, work, cursor("Cu")], kind: .fiveHour
        )
        XCTAssertEqual(included.map(\.account.label), ["AI", "Personal"])
    }

    func testExclusionNoteIsNilWhenEveryAccountOwnsTheKind() {
        XCTAssertNil(
            HistoryOverlay.exclusionNote(
                presentations: [claudeMax("AI"), claude("Personal")], kind: .fiveHour
            )
        )
    }

    func testExclusionNoteNamesTheAccountsItCannotDraw() {
        let note = HistoryOverlay.exclusionNote(
            presentations: [claudeMax("AI"), cursor("Cu")], kind: .fiveHour
        )
        XCTAssertEqual(note, "Not shown: Cu — no 5h window")
    }

    func testExclusionNoteCountsInsteadOfListingWhenManyAreExcluded() {
        let note = HistoryOverlay.exclusionNote(
            presentations: [
                claudeMax("AI"), cursor("A"), cursor("B"), cursor("C"), cursor("D"),
            ],
            kind: .fiveHour
        )
        XCTAssertEqual(note, "Not shown: 4 accounts with no 5h window")
    }

    func testExclusionNoteUsesTheFableLabelForTheModelWeeklyWindow() {
        let note = HistoryOverlay.exclusionNote(
            presentations: [claudeMax("AI"), claude("Personal")], kind: .modelWeekly
        )
        XCTAssertEqual(note, "Not shown: Personal — no Fable window")
    }

    // MARK: Legend labels

    func testLabelsDisambiguateAccountsSharingALabelAcrossProviders() {
        let claudeWork = claude("Work")
        let gptWork = chatGPT("Work")
        let labels = HistoryOverlay.labels(for: [claudeWork, gptWork])
        XCTAssertEqual(labels[claudeWork.id], "Work · Claude")
        XCTAssertEqual(labels[gptWork.id], "Work · ChatGPT")
    }

    func testLabelsLeaveUniqueLabelsAlone() {
        let ai = claudeMax("AI")
        let work = chatGPT("Work")
        let labels = HistoryOverlay.labels(for: [ai, work])
        XCTAssertEqual(labels[ai.id], "AI")
        XCTAssertEqual(labels[work.id], "Work")
    }

    func testLabelsKeepThePausedSuffixHistorySurfacesUse() {
        let paused = claude("Personal", paused: true)
        let labels = HistoryOverlay.labels(for: [paused])
        XCTAssertEqual(labels[paused.id], "Personal — PAUSED")
    }

    /// The label is also the Swift Charts series key: two series sharing a key
    /// are drawn as ONE line with a duplicated style-scale domain. Uniqueness
    /// therefore has to hold against every generated label, not just the raw
    /// ones — an account literally named "Work · Claude" must not collide with
    /// the qualified form generated for a different account named "Work".
    func testLabelsAreUniqueEvenAgainstAGeneratedQualifiedForm() {
        let workA = claude("Work")
        let workB = chatGPT("Work")
        let literal = claude("Work · Claude")
        let labels = HistoryOverlay.labels(for: [workA, workB, literal])
        XCTAssertEqual(Set(labels.values).count, 3)
    }

    func testLabelsStayUniqueWhenTwoAccountsOfOneProviderShareALabel() {
        let first = claude("Work")
        let second = claude("Work")
        let labels = HistoryOverlay.labels(for: [first, second])
        XCTAssertNotEqual(labels[first.id], labels[second.id])
        XCTAssertEqual(labels[first.id], "Work · Claude")
        XCTAssertEqual(labels[second.id], "Work · Claude (2)")
    }

    // MARK: Series

    func testSeriesAssignsShadeIndexPerProviderGroupNotGlobally() {
        let first = claude("One")
        let second = claude("Two")
        let work = chatGPT("Work")
        let loaded = [
            first.id: buckets(days: [1, 2]),
            second.id: buckets(days: [1, 2]),
            work.id: buckets(days: [1, 2]),
        ]
        let series = HistoryOverlay.series(
            presentations: [first, second, work], kind: .weekly, loaded: loaded
        )
        XCTAssertEqual(series.map(\.shadeIndex), [0, 1, 0])
        XCTAssertEqual(series.map(\.provider), [.claude, .claude, .chatGPT])
    }

    /// Shades are an account's identity, so they must not depend on which other
    /// accounts happen to have history yet: when an earlier account starts
    /// recording, every later line would otherwise change colour and appear to
    /// swap identity.
    func testSeriesShadeSurvivesAnEarlierAccountHavingNoHistoryYet() {
        let empty = claude("One")
        let drawn = claude("Two")
        let series = HistoryOverlay.series(
            presentations: [empty, drawn], kind: .weekly, loaded: [drawn.id: buckets(days: [1])]
        )
        // "Two" is the second Claude account either way — slot 1, not slot 0.
        XCTAssertEqual(series.map(\.shadeIndex), [1])
    }

    func testSeriesDropsAccountsWithNoRecordedHistory() {
        let withHistory = claude("One")
        let withoutHistory = claude("Two")
        let series = HistoryOverlay.series(
            presentations: [withHistory, withoutHistory], kind: .weekly,
            loaded: [withHistory.id: buckets(days: [1])]
        )
        XCTAssertEqual(series.map(\.accountID), [withHistory.id])
    }

    func testSeriesExcludesAccountsThatDoNotOwnTheKind() {
        let ai = claudeMax("AI")
        let cu = cursor("Cu")
        let series = HistoryOverlay.series(
            presentations: [ai, cu], kind: .fiveHour,
            loaded: [ai.id: buckets(days: [1]), cu.id: buckets(days: [1])]
        )
        XCTAssertEqual(series.map(\.accountID), [ai.id])
    }

    func testSeriesPointsAreTheAccountsDailyBurn() {
        let ai = claude("AI")
        let series = HistoryOverlay.series(
            presentations: [ai], kind: .weekly,
            loaded: [ai.id: buckets(days: [1, 1, 2], consumed: 0.25)]
        )
        // Two buckets on day 1 fold into one point; day 2 is its own.
        XCTAssertEqual(series.first?.points.count, 2)
        XCTAssertEqual(series.first?.points.first?.consumed ?? 0, 0.5, accuracy: 0.0001)
    }

    // MARK: Combined heatmap

    func testCombinedBucketsMergeEveryIncludedAccount() {
        let ai = claude("AI")
        let work = chatGPT("Work")
        let combined = HistoryOverlay.combinedBuckets(
            presentations: [ai, work, cursor("Cu")], kind: .weekly,
            loaded: [ai.id: buckets(days: [1, 2]), work.id: buckets(days: [3])]
        )
        XCTAssertEqual(combined.count, 3)
    }

    // MARK: Palette

    func testPaletteGivesEachProviderItsOwnBrandLadder() {
        XCTAssertNotEqual(
            HistoryOverlayPalette.hex(provider: .claude, shadeIndex: 0, dark: true),
            HistoryOverlayPalette.hex(provider: .chatGPT, shadeIndex: 0, dark: true)
        )
        XCTAssertNotEqual(
            HistoryOverlayPalette.hex(provider: .cursor, shadeIndex: 0, dark: true),
            HistoryOverlayPalette.hex(provider: .claude, shadeIndex: 0, dark: true)
        )
    }

    func testPaletteFirstShadeIsTheProvidersBrandAccent() {
        // Slot 0 must match the accent the account card and Settings mark use,
        // so one account reads identically across every surface — in both
        // appearances.
        for dark in [true, false] {
            let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
            XCTAssertEqual(HistoryOverlayPalette.hex(provider: .claude, shadeIndex: 0, dark: dark), resolvedHex(Theme.goldNS, appearance))
            XCTAssertEqual(HistoryOverlayPalette.hex(provider: .chatGPT, shadeIndex: 0, dark: dark), resolvedHex(Theme.chatGPTGreenNS, appearance))
            XCTAssertEqual(HistoryOverlayPalette.hex(provider: .cursor, shadeIndex: 0, dark: dark), resolvedHex(Theme.irisNS, appearance))
        }
    }

    /// Checks the colour actually DRAWN: the line at full strength and the
    /// overlay point at `overlayPointOpacity` over the ground. A one-day
    /// series is only its point, so the point alone must clear 3 : 1.
    func testEveryShadeIsVisibleOnBothGrounds() {
        for dark in [true, false] {
            let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
            let grounds = [resolvedHex(Theme.inkNS, appearance), resolvedHex(Theme.panelNS, appearance)]
            for provider in Provider.allCases {
                for shade in HistoryOverlayPalette.ladder(for: provider, dark: dark) {
                    for ground in grounds {
                        XCTAssertGreaterThanOrEqual(contrast(shade, ground), 3.0, "\(provider) \(String(shade, radix: 16)) dark=\(dark)")
                        let point = composite(shade, alpha: HistoryOverlayPalette.overlayPointOpacity, over: ground)
                        XCTAssertGreaterThanOrEqual(contrast(point, ground), 3.0, "\(provider) point \(String(shade, radix: 16)) dark=\(dark)")
                    }
                }
            }
        }
    }

    /// Every slot of every ladder, pinned to its exact hex in both
    /// appearances — a nudged shade must fail here, not slip by on the
    /// >= 3 : 1 floor alone.
    func testEveryLadderSlotIsPinned() {
        let expected: [(Provider, dark: [UInt32], light: [UInt32])] = [
            (.claude, [0xD9B44A, 0xF0D99A, 0xA88420, 0xE6C46E], [0x836400, 0xA68212, 0x5E4700, 0x957200]),
            (.chatGPT, [0x5CC79F, 0xA3E3C8, 0x2FA27A, 0x7FD6B3], [0x0F7657, 0x2A8E6E, 0x0A5540, 0x2C7A66]),
            (.cursor, [0xB0A6EE, 0xD6D0F7, 0x8779D6, 0xC3BBF2], [0x5A55B5, 0x7F7ACB, 0x3B3787, 0x6C67C2]),
        ]
        for (provider, dark, light) in expected {
            XCTAssertEqual(HistoryOverlayPalette.ladder(for: provider, dark: true), dark, "\(provider) dark ladder")
            XCTAssertEqual(HistoryOverlayPalette.ladder(for: provider, dark: false), light, "\(provider) light ladder")
            for slot in 0..<4 {
                let color = NSColor(HistoryOverlayPalette.color(provider: provider, shadeIndex: slot))
                XCTAssertEqual(resolvedHex(color, .darkAqua), dark[slot], "\(provider) dark slot \(slot)")
                XCTAssertEqual(resolvedHex(color, .aqua), light[slot], "\(provider) light slot \(slot)")
            }
        }
        XCTAssertEqual(HistoryOverlayPalette.hex(provider: .claude, shadeIndex: 1, dark: false), 0xA68212)
    }

    /// Two ChatGPT accounts must not draw near-identical greens: every pair
    /// of slots is >= 7 ΔE (CIE76) apart in both appearances.
    func testChatGPTLadderSlotsAreDistinct() {
        for dark in [true, false] {
            let ladder = HistoryOverlayPalette.ladder(for: .chatGPT, dark: dark)
            for i in ladder.indices {
                for j in ladder.indices where j > i {
                    let distance = deltaE76(ladder[i], ladder[j])
                    XCTAssertGreaterThanOrEqual(distance, 7, "slots \(i)/\(j) ΔE \(distance) dark=\(dark)")
                }
            }
        }
    }

    func testPaletteColorIsDynamic() {
        let c = NSColor(HistoryOverlayPalette.color(provider: .chatGPT, shadeIndex: 2))
        XCTAssertEqual(resolvedHex(c, .darkAqua), 0x2FA27A)
        XCTAssertEqual(resolvedHex(c, .aqua), 0x0A5540)
    }

    func testPaletteShadesWithinAProviderAreDistinct() {
        for dark in [true, false] {
            let shades = (0..<4).map { HistoryOverlayPalette.hex(provider: .claude, shadeIndex: $0, dark: dark) }
            XCTAssertEqual(Set(shades).count, 4, "dark=\(dark)")
        }
    }

    func testPaletteCyclesBeyondTheLadderInsteadOfCrashing() {
        let ladderLength = 4
        XCTAssertEqual(
            HistoryOverlayPalette.hex(provider: .claude, shadeIndex: ladderLength, dark: true),
            HistoryOverlayPalette.hex(provider: .claude, shadeIndex: 0, dark: true)
        )
    }

    /// Two accounts of one provider share a hue family, so colour alone is a
    /// weak separator on a dark chart (and none at all for a colourblind
    /// viewer). Each slot also gets its own dash pattern.
    func testPaletteGivesEachShadeSlotItsOwnDashPattern() {
        let patterns = (0..<3).map { HistoryOverlayPalette.dash(shadeIndex: $0) }
        XCTAssertEqual(Set(patterns.map(\.description)).count, 3)
    }

    func testPaletteFirstSlotDrawsASolidLine() {
        XCTAssertEqual(HistoryOverlayPalette.dash(shadeIndex: 0), [])
    }

    /// Colour and dash cycle at different lengths (4 and 3) so the *pair* — what
    /// the eye actually reads — survives further than either encoding alone: the
    /// fifth account of one provider reuses gold but not gold-solid.
    func testPaletteColourAndDashPairStaysUniqueBeyondEitherLadder() {
        for dark in [true, false] {
            let pairs = (0..<12).map { index in
                "\(HistoryOverlayPalette.hex(provider: .claude, shadeIndex: index, dark: dark))"
                    + "/\(HistoryOverlayPalette.dash(shadeIndex: index))"
            }
            XCTAssertEqual(Set(pairs).count, 12, "dark=\(dark)")
        }
    }

    func testPaletteDashLadderCyclesOnItsOwnLength() {
        XCTAssertEqual(
            HistoryOverlayPalette.dash(shadeIndex: 3), HistoryOverlayPalette.dash(shadeIndex: 0)
        )
    }

    // MARK: Load identity

    /// The loader's identity must change when an account *gains* the selected
    /// window — a Max upgrade, or simply the first snapshot landing — or that
    /// account's line never appears until the window is reopened.
    func testLoadIdentityChangesWhenAnAccountGainsTheSelectedWindow() {
        let before = claude("AI")                 // 5h + weekly, no Fable
        let after = claudeMax("AI")               // same account, now with Fable
        let others = [chatGPT("Work")]
        XCTAssertNotEqual(
            HistoryOverlay.loadIdentity(presentations: [before] + others, scope: .all, kind: .weekly),
            HistoryOverlay.loadIdentity(presentations: [after] + others, scope: .all, kind: .weekly)
        )
    }

    func testLoadIdentityIsStableForAnUnchangedAccountSet() {
        let ai = claudeMax("AI")
        let work = chatGPT("Work")
        XCTAssertEqual(
            HistoryOverlay.loadIdentity(presentations: [ai, work], scope: .all, kind: .weekly),
            HistoryOverlay.loadIdentity(presentations: [ai, work], scope: .all, kind: .weekly)
        )
    }

    func testLoadIdentityDistinguishesScopeAndKind() {
        let ai = claudeMax("AI")
        let all = HistoryOverlay.loadIdentity(presentations: [ai], scope: .all, kind: .weekly)
        let one = HistoryOverlay.loadIdentity(
            presentations: [ai], scope: .account(ai.id), kind: .weekly
        )
        let otherKind = HistoryOverlay.loadIdentity(
            presentations: [ai], scope: .all, kind: .fiveHour
        )
        XCTAssertNotEqual(all, one)
        XCTAssertNotEqual(all, otherKind)
    }

    // MARK: Scope / kind resolution

    func testEffectiveScopeFallsBackToAllWhenTheSelectedAccountIsGone() {
        let ai = claude("AI")
        let scope = HistoryOverlay.effectiveScope(
            requested: .account(UUID()), presentations: [ai]
        )
        XCTAssertEqual(scope, .all)
    }

    func testEffectiveScopeKeepsALiveSelection() {
        let ai = claude("AI")
        XCTAssertEqual(
            HistoryOverlay.effectiveScope(requested: .account(ai.id), presentations: [ai]),
            .account(ai.id)
        )
    }

    func testEffectiveKindFallsBackToTheFirstAvailableWhenTheSelectionIsAbsent() {
        let work = chatGPT("Work")
        let kind = HistoryOverlay.effectiveKind(
            requested: .fiveHour, presentations: [work], scope: .account(work.id)
        )
        XCTAssertEqual(kind, .weekly)
    }

    func testEffectiveKindKeepsAnAvailableSelection() {
        let ai = claudeMax("AI")
        let kind = HistoryOverlay.effectiveKind(
            requested: .modelWeekly, presentations: [ai], scope: .all
        )
        XCTAssertEqual(kind, .modelWeekly)
    }
}
