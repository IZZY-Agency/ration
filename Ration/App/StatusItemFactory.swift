import AppKit

@MainActor
enum StatusItemFactory {
    static let iconName = "gauge.with.dots.needle.50percent"

    /// A unique, stable autosave name. Relying on AppKit's auto-assigned
    /// `"Item-0"` collides with the generic name macOS gives the first status
    /// item of many other apps, so their persisted visibility/position state
    /// (`"NSStatusItem VisibleCC Item-0"`) becomes shared and unreliable. A
    /// dedicated identifier decouples Ration from that collision and lets
    /// macOS persist a menu-bar slot for this item alone. (macOS 26 can still
    /// park the item off-screen when the notched menu bar is full; the reopen
    /// fallback window remains the escape hatch in that case.)
    static let autosaveName = "RationMenuBarItem"

    static func make(
        in statusBar: NSStatusBar = .system
    ) -> NSStatusItem {
        // Variable length so the usage rings can appear next to the icon and
        // the item collapses back to icon-only width when rings are off.
        let item = statusBar.statusItem(
            withLength: NSStatusItem.variableLength
        )
        item.autosaveName = autosaveName
        item.behavior = []

        if let button = item.button {
            let image = NSImage(
                systemSymbolName: iconName,
                accessibilityDescription: iconName
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Ration"
            button.setAccessibilityLabel("Ration")
        }

        item.isVisible = true
        return item
    }

    /// Renders the usage rings onto the status item button: one ring per
    /// visible account, stroke-filled in its provider's brand accent
    /// proportionally to the gauge's fraction, with a green center dot on
    /// accounts in the bright IN USE phase — the icon hidden while rings show
    /// (the rings already mark the item) — or back to the
    /// bare template icon when there are no gauges (no accounts, toggle off,
    /// or no account reports a rate window). While Keep awake is on, the eye
    /// trails the rings (or sits beside the icon when there are none): the
    /// outline at rest, the filled glyph in the reset blue while a hold is
    /// live — gold is Claude's ring colour, so the footer's gold stays there. The tooltip and accessibility
    /// label carry the names and exact values, and the hold — the ring alone
    /// never has to be decoded.
    static func applyGauges(
        _ gauges: [MenuBarGauge],
        displaysRemaining: Bool,
        keepAwake: KeepAwakeEye = .hidden,
        to button: NSStatusBarButton
    ) {
        // The menu bar's own appearance, not the app's: a forced-Dark app
        // still sits in a light menu bar (and vice versa), and macOS tints
        // the bar per wallpaper.
        button.attributedTitle = ringsTitle(
            for: gauges, keepAwake: keepAwake, appearance: button.effectiveAppearance
        )
        if gauges.isEmpty {
            // The eye alone keeps the icon beside it; nothing at all is the
            // bare icon again.
            button.imagePosition = keepAwake.isShown ? .imageLeading : .imageOnly
        } else {
            // The image stays on the button, so no gauges brings it back.
            button.imagePosition = .noImage
        }
        let toolTip = toolTip(for: gauges, displaysRemaining: displaysRemaining, keepAwake: keepAwake)
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
    }

    static let ringPointSize: CGFloat = 13
    /// The eye's box: an 11 pt `eye.fill` is wider than it is tall.
    static let keepAwakeWidth: CGFloat = 16

    static func ringsTitle(
        for gauges: [MenuBarGauge],
        keepAwake: KeepAwakeEye = .hidden,
        appearance: NSAppearance
    ) -> NSAttributedString {
        var glyphs: [(image: NSImage, width: CGFloat)] = gauges.map { gauge in
            (
                gaugeImage(
                    fraction: gauge.fraction,
                    color: gauge.source.accentNS,
                    shape: gauge.source.gaugeShape,
                    inUse: gauge.inUse,
                    appearance: appearance
                ),
                ringPointSize
            )
        }
        if keepAwake.isShown {
            glyphs.append((keepAwakeImage(keepAwake, appearance: appearance), keepAwakeWidth))
        }
        let title = NSMutableAttributedString()
        for (index, glyph) in glyphs.enumerated() {
            let attachment = NSTextAttachment()
            attachment.image = glyph.image
            // Dropped baseline so the ring sits optically centred in the bar.
            attachment.bounds = CGRect(
                x: 0, y: -2.5, width: glyph.width, height: ringPointSize
            )
            let ring = NSMutableAttributedString(attachment: attachment)
            if index < glyphs.count - 1 {
                // Kern trails each glyph, so the last one stays flush.
                ring.addAttribute(
                    .kern, value: 3, range: NSRange(location: 0, length: ring.length)
                )
            }
            title.append(ring)
        }
        return title
    }

    /// The menu bar's Keep awake mark: the footer's glyph for the state —
    /// the outline in the quiet grey at rest, the filled eye in the reset
    /// blue while held — resolved for the bar's appearance at draw time like
    /// the rings.
    static func keepAwakeImage(_ eye: KeepAwakeEye, appearance: NSAppearance) -> NSImage {
        let name = MenuBarView.keepAwakeGlyph(eye.status)
        let tint: NSColor = eye.status == .off ? Theme.creamDimNS : Theme.resetAccentNS
        return NSImage(size: NSSize(width: keepAwakeWidth, height: ringPointSize), flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration) else { return }
                let size = symbol.size
                symbol.draw(in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height
                ))
                tint.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
    }

    /// A ring whose arc sweeps clockwise from 12 o'clock in proportion to
    /// `fraction`, over a faint same-color track so an almost-empty ring still
    /// reads as a ring. `inUse` fills the ring's center with a green dot —
    /// `Theme.active`, the same semantic green as the popover IN USE pill.
    ///
    /// Dynamic colours resolve against `appearance` at DRAW time: the image's
    /// drawing handler runs whenever it is rasterized, long after this call,
    /// under whatever appearance is current then — so the whole body runs
    /// inside `performAsCurrentDrawingAppearance`.
    static func ringImage(
        fraction: Double,
        color: NSColor,
        inUse: Bool = false,
        appearance: NSAppearance
    ) -> NSImage {
        gaugeImage(fraction: fraction, color: color, shape: .ring, inUse: inUse, appearance: appearance)
    }

    /// A rounded square traced CLOCKWISE from 12 o'clock, so a dash of
    /// `fraction × perimeter` fills like the ring does (API budget gauges).
    static func roundedSquarePath(in rect: NSRect, radius r: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let (minX, minY, maxX, maxY, midX) = (rect.minX, rect.minY, rect.maxX, rect.maxY, rect.midX)
        path.move(to: NSPoint(x: midX, y: maxY))
        path.line(to: NSPoint(x: maxX - r, y: maxY))
        path.appendArc(withCenter: NSPoint(x: maxX - r, y: maxY - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: maxX, y: minY + r))
        path.appendArc(withCenter: NSPoint(x: maxX - r, y: minY + r), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        path.line(to: NSPoint(x: minX + r, y: minY))
        path.appendArc(withCenter: NSPoint(x: minX + r, y: minY + r), radius: r, startAngle: -90, endAngle: -180, clockwise: true)
        path.line(to: NSPoint(x: minX, y: maxY - r))
        path.appendArc(withCenter: NSPoint(x: minX + r, y: maxY - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        path.close()
        return path
    }

    /// The menu-bar gauge in either shape: the subscription ring, or the API
    /// budget's rounded square (same stroke, track and fill direction).
    /// `side` and `stroke` default to the menu bar's; the ring bar draws the
    /// same gauge bigger.
    static func gaugeImage(
        fraction: Double,
        color: NSColor,
        shape: GaugeShape,
        inUse: Bool = false,
        side: CGFloat = ringPointSize,
        stroke: CGFloat = 2.5,
        appearance: NSAppearance
    ) -> NSImage {
        if shape == .roundedSquare {
            return roundedSquareImage(fraction: fraction, color: color, side: side, stroke: stroke, appearance: appearance)
        }
        let clamped = min(max(fraction, 0), 1)
        return NSImage(
            size: NSSize(width: side, height: side),
            flipped: false
        ) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let radius = (min(rect.width, rect.height) - stroke) / 2

                let track = NSBezierPath()
                track.appendArc(
                    withCenter: center, radius: radius, startAngle: 0, endAngle: 360
                )
                track.lineWidth = stroke
                // `withAlphaComponent` on a dynamic colour stays dynamic; it
                // resolves here, inside the block, like the rest.
                color.withAlphaComponent(trackAlpha).setStroke()
                track.stroke()

                if inUse {
                    let dotRadius: CGFloat = 2 * side / ringPointSize
                    let dot = NSBezierPath(ovalIn: NSRect(
                        x: center.x - dotRadius, y: center.y - dotRadius,
                        width: dotRadius * 2, height: dotRadius * 2
                    ))
                    Theme.activeNS.setFill()
                    dot.fill()
                }

                if clamped > 0 {
                    let arc = NSBezierPath()
                    // Non-flipped coordinates: 90° is 12 o'clock; a clockwise
                    // sweep matches how every macOS gauge fills.
                    arc.appendArc(
                        withCenter: center, radius: radius,
                        startAngle: 90, endAngle: 90 - clamped * 360, clockwise: true
                    )
                    arc.lineWidth = stroke
                    arc.lineCapStyle = .round
                    color.setStroke()
                    arc.stroke()
                }
            }
            return true
        }
    }

    private static func roundedSquareImage(fraction: Double, color: NSColor, side: CGFloat, stroke: CGFloat, appearance: NSAppearance) -> NSImage {
        let radius: CGFloat = 3.2 * side / ringPointSize
        let clamped = min(max(fraction, 0), 1)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let inset = rect.insetBy(dx: stroke / 2, dy: stroke / 2)
                let track = roundedSquarePath(in: inset, radius: radius)
                track.lineWidth = stroke
                color.withAlphaComponent(trackAlpha).setStroke()
                track.stroke()
                if clamped > 0 {
                    let fill = roundedSquarePath(in: inset, radius: radius)
                    let perimeter = 2 * (inset.width + inset.height) - (8 - 2 * .pi) * radius
                    fill.setLineDash([perimeter * clamped, perimeter], count: 2, phase: 0)
                    fill.lineWidth = stroke
                    fill.lineCapStyle = .round
                    color.setStroke()
                    fill.stroke()
                }
            }
            return true
        }
    }

    static func toolTip(
        for gauges: [MenuBarGauge],
        displaysRemaining: Bool,
        keepAwake: KeepAwakeEye = .hidden,
        locale: Locale = .current
    ) -> String {
        var parts: [String] = []
        for gauge in gauges {
            parts.append(toolTipEntry(gauge, displaysRemaining: displaysRemaining, locale: locale))
        }
        // The popover banner's line while held, so the eye reads the same
        // everywhere; the idle eye says nothing — there is no hold to name.
        if let banner = KeepAwakeCopy.banner(keepAwake.status, locale: locale) {
            parts.append(banner)
        }
        guard !parts.isEmpty else { return "Ration" }
        return "Ration — " + parts.joined(separator: " · ")
    }

    /// One account's part of the tooltip: "Claude AI 5h 14% left". Also the
    /// ring bar's gauge value for VoiceOver.
    /// The unfilled track, which tells how much is left; stronger with
    /// Increase Contrast. Read at draw time, so a change applies on redraw.
    static var trackAlpha: CGFloat { Theme.increaseContrast ? 0.5 : 0.28 }

    /// "Claude AI", but never "ChatGPT ChatGPT …": a label that is, or
    /// starts with, the provider's name (a whole word, any case — "chatgpt
    /// pro" too) keeps it once.
    nonisolated static func gaugeName(_ gauge: MenuBarGauge) -> String {
        let provider = gauge.source.displayName
        let label = gauge.label
        if label.caseInsensitiveCompare(provider) == .orderedSame { return label }
        if label.count > provider.count,
           String(label.prefix(provider.count)).caseInsensitiveCompare(provider) == .orderedSame,
           label.dropFirst(provider.count).first?.isWhitespace == true {
            return label
        }
        return "\(provider) \(label)"
    }

    nonisolated static func toolTipEntry(
        _ gauge: MenuBarGauge,
        displaysRemaining: Bool,
        locale: Locale
    ) -> String {
        let name = gaugeName(gauge)
        if let budget = gauge.budget {
            let resource: LocalizedStringResource
            if displaysRemaining {
                let left = APIMoney.wholePercent(100 - budget.exactPercent, budget.isLowerBound ? .up : .plain)
                resource = budget.isLowerBound ? .statusItemTooltipBudgetLeftUpperBound(name, left) : .statusItemTooltipBudgetLeft(name, left)
            } else {
                let used = APIMoney.wholePercent(budget.exactPercent, budget.isLowerBound ? .down : .plain)
                resource = budget.isLowerBound ? .statusItemTooltipBudgetUsedLowerBound(name, used) : .statusItemTooltipBudgetUsed(name, used)
            }
            return resource.string(in: locale)
        }
        let percent = Int((gauge.fraction * 100).rounded())
        if let credit = gauge.credit {
            // The money, not a percentage: "TypeSafe Lab $26.58 of $30.00 credit left".
            let granted: String = UsageFormatters.money(credit.granted, locale: locale)
            if displaysRemaining {
                return LocalizedStringResource.statusItemTooltipCreditLeft(name, UsageFormatters.money(credit.balance, locale: locale), granted).string(in: locale)
            }
            let used: String = credit.used.map { UsageFormatters.money($0, locale: locale) } ?? ""
            return LocalizedStringResource.statusItemTooltipCreditUsed(name, used, granted).string(in: locale)
        }
        let window: String = gauge.windowKind.map { windowLabel($0, locale: locale) } ?? ""
        let resource: LocalizedStringResource = displaysRemaining
            ? .statusItemTooltipLeft(name, window, percent)
            : .statusItemTooltipUsed(name, window, percent)
        let value: String = resource.string(in: locale)
        guard gauge.inUse else { return value }
        return LocalizedStringResource.statusItemTooltipInUse(value).string(in: locale)
    }

    nonisolated static func windowLabel(_ kind: UsageWindowKind, locale: Locale = .current) -> String {
        switch kind {
        case .fiveHour: LocalizedStringResource.focusShortNameFiveHour.string(in: locale)
        case .weekly: LocalizedStringResource.statusItemWindowWeekly.string(in: locale)
        // A model name — never translated.
        case .modelWeekly: "Fable"
        }
    }
}
