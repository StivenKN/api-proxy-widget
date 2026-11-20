import AppKit
import ProxyLimits

/// Draws the menu bar item: two gauges that drain as the pool is used.
/// The top one is the 5-hour window, the bottom one the weekly window.
enum MenuBarIcon {
    /// A warning sign replaces the gauges once they would show limits nobody can vouch for.
    static func image(for pool: ProviderPool?, isOutOfDate: Bool) -> NSImage {
        if isOutOfDate,
            let symbol = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "Proxy limits unavailable"
            )
        {
            symbol.isTemplate = true
            return symbol
        }
        let levels = [pool?.window("5h")?.remainingFraction, pool?.window("7d")?.remainingFraction]
        let size = NSSize(width: 20, height: 14)
        let image = NSImage(size: size, flipped: true) { _ in
            let barHeight: CGFloat = 5
            let gap: CGFloat = 3
            let top = (size.height - barHeight * 2 - gap) / 2
            for (index, level) in levels.enumerated() {
                let track = NSRect(
                    x: 0,
                    y: top + CGFloat(index) * (barHeight + gap),
                    width: size.width,
                    height: barHeight
                )
                let radius = barHeight / 2
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
                guard let level, level > 0 else { continue }
                // Never narrower than a dot, so "a little left" doesn't look empty.
                let width = max(barHeight, track.width * min(1, level))
                let fill = NSRect(x: track.minX, y: track.minY, width: width, height: barHeight)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityText(for: pool)
        return image
    }

    private static func accessibilityText(for pool: ProviderPool?) -> String {
        guard let pool, !pool.windows.isEmpty else { return "Proxy limits" }
        let parts = pool.windows.prefix(2).map { "\($0.label) \(LimitFormat.percent($0.remainingFraction)) left" }
        return "\(pool.provider.displayName): " + parts.joined(separator: ", ")
    }
}
