import XCTest
@testable import Ration

final class PlanTierTests: XCTestCase {
    // MARK: Capacity + copy

    func testCapacityUnits() {
        XCTAssertEqual(PlanTier.claudePro.capacityUnits, 1)
        XCTAssertEqual(PlanTier.claudeMax.capacityUnits, 5)
        // claude.com/pricing (2026-11-01): Ultra is "10x Pro usage" a week.
        XCTAssertEqual(PlanTier.claudeUltra.capacityUnits, 10)
        XCTAssertEqual(PlanTier.chatGPTPlus.capacityUnits, 1)
        XCTAssertEqual(PlanTier.chatGPTPro5x.capacityUnits, 5)
        XCTAssertEqual(PlanTier.chatGPTPro20x.capacityUnits, 20)
    }

    func testTagsMatchSpec() {
        XCTAssertEqual(PlanTier.claudeUltra.tag, "ULTRA")
        XCTAssertEqual(PlanTier.claudeMax.tag, "MAX")
        XCTAssertEqual(PlanTier.claudePro.tag, "PRO")
        XCTAssertEqual(PlanTier.chatGPTPro5x.tag, "PRO 5X")
        XCTAssertEqual(PlanTier.chatGPTPro20x.tag, "PRO 20X")
        XCTAssertEqual(PlanTier.chatGPTPlus.tag, "PLUS")
    }

    /// Anthropic's 2026-10-30 names: Max 5x → Max, Max 20x → Ultra.
    func testDisplayNamesFollowAnthropicsRename() {
        XCTAssertEqual(PlanTier.claudePro.displayName, "Pro")
        XCTAssertEqual(PlanTier.claudeMax.displayName, "Max")
        XCTAssertEqual(PlanTier.claudeUltra.displayName, "Ultra")
    }

    /// `accounts.json` written before the rename stores the old raw values;
    /// they must keep decoding to the same plans.
    func testStoredRawValuesFromBeforeTheRenameStillDecode() throws {
        XCTAssertEqual(PlanTier.claudeMax.rawValue, "claudeMax5x")
        XCTAssertEqual(PlanTier.claudeUltra.rawValue, "claudeMax20x")
        let decoded = try JSONDecoder().decode([PlanTier].self, from: Data(#"["claudeMax5x","claudeMax20x"]"#.utf8))
        XCTAssertEqual(decoded, [.claudeMax, .claudeUltra])
    }

    func testOptionsPerProvider() {
        XCTAssertEqual(PlanTier.options(for: .claude), [.claudePro, .claudeMax, .claudeUltra])
        XCTAssertEqual(PlanTier.options(for: .chatGPT), [.chatGPTPlus, .chatGPTPro5x, .chatGPTPro20x])
        XCTAssertEqual(PlanTier.options(for: .cursor), [])
        for tier in PlanTier.allCases {
            XCTAssertTrue(PlanTier.options(for: tier.provider).contains(tier))
        }
    }

    // MARK: Claude mapping (rate_limit_tier + capabilities)

    func testClaudeMax20xTierIsUltra() {
        XCTAssertEqual(
            PlanTier.fromClaude(rateLimitTier: "default_claude_max_20x", capabilities: ["chat", "claude_max"]),
            .claudeUltra
        )
    }

    func testClaudeMax5xTierIsMax() {
        XCTAssertEqual(
            PlanTier.fromClaude(rateLimitTier: "default_claude_max_5x", capabilities: ["chat", "claude_max"]),
            .claudeMax
        )
    }

    func testClaudeProInferred() {
        XCTAssertEqual(
            PlanTier.fromClaude(rateLimitTier: "default_claude_ai", capabilities: ["chat", "claude_pro"]),
            .claudePro
        )
    }

    func testClaudeNonMaxTierWithMaxCapabilityIsUnknown() {
        XCTAssertNil(PlanTier.fromClaude(rateLimitTier: "default_claude_ai", capabilities: ["chat", "claude_max"]))
    }

    func testClaudeUnknownMaxVariantIsUnknown() {
        XCTAssertNil(PlanTier.fromClaude(rateLimitTier: "default_claude_max_50x", capabilities: ["claude_max"]))
    }

    /// A tier naming Ultra is a paid top plan, never Pro, whatever its
    /// capabilities say.
    func testClaudeTierMentioningUltraIsNeverPro() {
        XCTAssertNil(PlanTier.fromClaude(rateLimitTier: "default_claude_ultra", capabilities: ["chat"]))
        XCTAssertNotEqual(PlanTier.fromClaude(rateLimitTier: "default_claude_ultra", capabilities: []), .claudePro)
    }

    func testClaudeUnrelatedTiersAreUnknown() {
        XCTAssertNil(PlanTier.fromClaude(rateLimitTier: "enterprise_tier", capabilities: ["chat"]))
        XCTAssertNil(PlanTier.fromClaude(rateLimitTier: nil, capabilities: ["chat"]))
        XCTAssertNil(PlanTier.fromClaude(rateLimitTier: "", capabilities: []))
    }

    // MARK: ChatGPT mapping (plan_type)

    func testChatGPTMappings() {
        XCTAssertEqual(PlanTier.fromChatGPT(planType: "prolite"), .chatGPTPro5x)   // verified live
        XCTAssertEqual(PlanTier.fromChatGPT(planType: "pro"), .chatGPTPro20x)
        XCTAssertEqual(PlanTier.fromChatGPT(planType: "plus"), .chatGPTPlus)
        XCTAssertNil(PlanTier.fromChatGPT(planType: "team"))
        XCTAssertNil(PlanTier.fromChatGPT(planType: "free"))
        XCTAssertNil(PlanTier.fromChatGPT(planType: nil))
    }

    // MARK: Unrecognized-value log carries no raw value

    func testUnrecognizedLogNeverCarriesTheRawValueAndFiresOncePerProvider() {
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        let original = PlanDetectionLog.emit
        PlanDetectionLog.resetForTesting()
        PlanDetectionLog.emit = { lines.all.append($0) }
        defer {
            PlanDetectionLog.emit = original
            PlanDetectionLog.resetForTesting()
        }

        _ = PlanDetection.claude(rateLimitTier: "jane.doe@example.com", capabilities: [])
        _ = PlanDetection.claude(rateLimitTier: "Jane_Doe_team", capabilities: [])
        _ = PlanDetection.chatGPT(planType: "acme-corp-jdoe")

        XCTAssertEqual(lines.all, [
            "Ration: unrecognized claude plan value",
            "Ration: unrecognized chatgpt plan value"
        ])
        XCTAssertFalse(lines.all.joined().lowercased().contains("jane"))
        XCTAssertFalse(lines.all.joined().lowercased().contains("doe"))
    }

    // MARK: Detection result

    func testDetectionFromRawValues() {
        XCTAssertEqual(PlanDetection.claude(rateLimitTier: "default_claude_max_20x", capabilities: ["claude_max"]), .tier(.claudeUltra))
        XCTAssertEqual(PlanDetection.claude(rateLimitTier: "weird", capabilities: []), .unrecognized)
        XCTAssertNil(PlanDetection.claude(rateLimitTier: nil, capabilities: []))
        XCTAssertEqual(PlanDetection.chatGPT(planType: "prolite"), .tier(.chatGPTPro5x))
        XCTAssertEqual(PlanDetection.chatGPT(planType: "team"), .unrecognized)
        XCTAssertNil(PlanDetection.chatGPT(planType: nil))
    }

    // MARK: Record rules

    private func record(
        provider: Provider = .claude,
        plan: PlanTier? = nil,
        source: PlanSource? = nil
    ) -> AccountRecord {
        AccountRecord(
            id: UUID(), provider: provider, label: "A", webProfileID: UUID(),
            displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0),
            plan: plan, planSource: source
        )
    }

    func testDetectionFillsEmptyPlan() {
        let updated = record().applyingDetectedPlan(.tier(.claudeUltra))
        XCTAssertEqual(updated.plan, .claudeUltra)
        XCTAssertEqual(updated.planSource, .detected)
    }

    func testDetectionNeverOverwritesUserChoice() {
        let user = record(plan: .claudeMax, source: .user)
        XCTAssertEqual(user.applyingDetectedPlan(.tier(.claudeUltra)), user)
        XCTAssertEqual(user.applyingDetectedPlan(.unrecognized), user)
    }

    func testUnrecognizedClearsADetectedPlan() {
        let detected = record(plan: .claudeUltra, source: .detected)
        let updated = detected.applyingDetectedPlan(.unrecognized)
        XCTAssertNil(updated.plan)
        XCTAssertNil(updated.planSource)
    }

    func testDetectionOfOtherProvidersTierIsIgnored() {
        let chat = record(provider: .chatGPT)
        XCTAssertEqual(chat.applyingDetectedPlan(.tier(.claudeUltra)), chat)
    }

    func testEffectivePlanIgnoresMismatchedProvider() {
        XCTAssertNil(record(provider: .chatGPT, plan: .claudeUltra, source: .user).effectivePlan)
        XCTAssertEqual(record(plan: .claudeUltra, source: .user).effectivePlan, .claudeUltra)
    }
}
