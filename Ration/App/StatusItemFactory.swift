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
    /// accounts in the bright IN USE phase — or back to the bare template
    /// icon when there are no gauges (toggle off, or no account reports a
    /// rate window). The tooltip and accessibility label carry the names and
    /// exact values — the ring alone never has to be decoded.
    static func applyGauges(
        _ gauges: [MenuBarGauge],
        displaysRemaining: Bool,
        to button: NSStatusBarButton
    ) {
        if gauges.isEmpty {
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
        } else {
            // The menu bar's own appearance, not the app's: a forced-Dark app
            // still sits in a light menu bar (and vice versa), and macOS tints
            // the bar per wallpaper.
            button.attributedTitle = ringsTitle(
                for: gauges, appearance: button.effectiveAppearance
            )
            button.imagePosition = .imageLeft
        }
        let toolTip = toolTip(for: gauges, displaysRemaining: displaysRemaining)
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
    }

    static let ringPointSize: CGFloat = 13

    static func ringsTitle(
        for gauges: [MenuBarGauge],
        appearance: NSAppearance
    ) -> NSAttributedString {
        let title = NSMutableAttributedString()
        for (index, gauge) in gauges.enumerated() {
            let attachment = NSTextAttachment()
            attachment.image = gaugeImage(
                fraction: gauge.fraction,
                color: gauge.source.accentNS,
                shape: gauge.source.gaugeShape,
                inUse: gauge.inUse,
                appearance: appearance
            )
            // Dropped baseline so the ring optically centers on the icon.
            attachment.bounds = CGRect(
                x: 0, y: -2.5, width: ringPointSize, height: ringPointSize
            )
            let ring = NSMutableAttributedString(attachment: attachment)
            if index < gauges.count - 1 {
                // Kern trails each glyph, so the last ring stays flush.
                ring.addAttribute(
                    .kern, value: 3, range: NSRange(location: 0, length: ring.length)
                )
            }
            title.append(ring)
        }
        return title
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
    static func gaugeImage(
        fraction: Double,
        color: NSColor,
        shape: GaugeShape,
        inUse: Bool = false,
        appearance: NSAppearance
    ) -> NSImage {
        if shape == .roundedSquare {
            return roundedSquareImage(fraction: fraction, color: color, appearance: appearance)
        }
        let side = ringPointSize
        let stroke: CGFloat = 2.5
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
                color.withAlphaComponent(0.28).setStroke()
                track.stroke()

                if inUse {
                    let dotRadius: CGFloat = 2
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

    private static func roundedSquareImage(fraction: Double, color: NSColor, appearance: NSAppearance) -> NSImage {
        let side = ringPointSize
        let stroke: CGFloat = 2.5
        let radius: CGFloat = 3.2
        let clamped = min(max(fraction, 0), 1)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let inset = rect.insetBy(dx: stroke / 2, dy: stroke / 2)
                let track = roundedSquarePath(in: inset, radius: radius)
                track.lineWidth = stroke
                color.withAlphaComponent(0.28).setStroke()
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
        locale: Locale = .current
    ) -> String {
        guard !gauges.isEmpty else { return "Ration" }
        var parts: [String] = []
        for gauge in gauges {
            parts.append(toolTipEntry(gauge, displaysRemaining: displaysRemaining, locale: locale))
        }
        return "Ration — " + parts.joined(separator: " · ")
    }

    /// One account's part of the tooltip: "Claude AI 5h 14% left".
    private static func toolTipEntry(
        _ gauge: MenuBarGauge,
        displaysRemaining: Bool,
        locale: Locale
    ) -> String {
        if let budget = gauge.budget {
            let name = "\(gauge.source.displayName) \(gauge.label)"
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
        // "Claude AI …", but never "ChatGPT ChatGPT …" when the label
        // already is the provider name (case-insensitively — a label
        // typed "chatgpt" must not repeat either).
        let name: String = gauge.label.caseInsensitiveCompare(gauge.source.displayName) == .orderedSame
            ? gauge.label
            : "\(gauge.source.displayName) \(gauge.label)"
        let window: String = gauge.windowKind.map { windowLabel($0, locale: locale) } ?? ""
        let resource: LocalizedStringResource = displaysRemaining
            ? .statusItemTooltipLeft(name, window, percent)
            : .statusItemTooltipUsed(name, window, percent)
        let value: String = resource.string(in: locale)
        guard gauge.inUse else { return value }
        return LocalizedStringResource.statusItemTooltipInUse(value).string(in: locale)
    }

    static func windowLabel(_ kind: UsageWindowKind, locale: Locale = .current) -> String {
        switch kind {
        case .fiveHour: LocalizedStringResource.focusShortNameFiveHour.string(in: locale)
        case .weekly: LocalizedStringResource.statusItemWindowWeekly.string(in: locale)
        // A model name — never translated.
        case .modelWeekly: "Fable"
        }
    }
}
