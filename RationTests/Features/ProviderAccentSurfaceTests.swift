import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Every surface that names a provider draws that provider's own accent —
/// not Claude's gold for everyone (the card chip and Add Account icons did).
@MainActor
final class ProviderAccentSurfaceTests: XCTestCase {
    func testAccountCardChipUsesTheProvidersAccent() {
        for provider in Provider.allCases {
            let chip = NSColor(AccountCardView.providerChipAccent(for: provider))
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                XCTAssertEqual(resolvedHex(chip, appearance), resolvedHex(provider.markAccentNS, appearance),
                               "\(provider) chip, \(appearance.rawValue)")
            }
        }
    }

    func testAddAccountRowIconUsesTheProvidersAccent() {
        for provider in Provider.allCases {
            let icon = NSColor(AddAccountView.iconAccent(for: provider))
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                XCTAssertEqual(resolvedHex(icon, appearance), resolvedHex(provider.markAccentNS, appearance),
                               "\(provider) icon, \(appearance.rawValue)")
            }
        }
    }

    func testOnboardingProviderIconUsesTheProvidersAccent() {
        for provider in Provider.allCases {
            let icon = NSColor(OnboardingConnectStep.iconAccent(for: provider))
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                XCTAssertEqual(resolvedHex(icon, appearance), resolvedHex(provider.markAccentNS, appearance),
                               "\(provider) onboarding icon, \(appearance.rawValue)")
            }
        }
    }
}
