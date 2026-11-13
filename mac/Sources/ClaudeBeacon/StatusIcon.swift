import AppKit

/// Colors shared with the Windows client.
enum BeaconColor {
    static let amber = NSColor(srgbRed: 245 / 255, green: 170 / 255, blue: 0, alpha: 1)
    static let amberSeen = NSColor(srgbRed: 150 / 255, green: 115 / 255, blue: 40 / 255, alpha: 1)
    static let green = NSColor(srgbRed: 40 / 255, green: 170 / 255, blue: 80 / 255, alpha: 1)
    static let gray = NSColor(srgbRed: 125 / 255, green: 125 / 255, blue: 125 / 255, alpha: 1)
    static let graySeen = NSColor(srgbRed: 90 / 255, green: 90 / 255, blue: 90 / 255, alpha: 1)

    static func dot(for s: BeaconSession) -> NSColor {
        if s.isWorking { return green }
        if s.isAsking { return s.isAcked ? amberSeen : amber }
        return s.isAcked ? graySeen : gray
    }
}

/// One dot in the menu bar: a colored disc with a count, or a faint ring when the count is zero.
struct SlotView {
    let fill: NSColor
    let count: Int
    let rim: Bool           // white rim: an idle session finished since you last looked
    let tooltip: String

    static func make(_ slot: Slot, _ state: BeaconState) -> SlotView {
        let asking = state.asking, idle = state.idle, working = state.working
        let freshAsk = asking.contains { !$0.isAcked }
        let freshIdle = idle.contains { !$0.isAcked }
        func names(_ list: [BeaconSession]) -> String { list.map(\.short).joined(separator: ", ") }

        switch slot {
        case .attention:
            let list = asking + idle
            let fill = !asking.isEmpty ? (freshAsk ? BeaconColor.amber : BeaconColor.amberSeen)
                                       : (freshIdle ? BeaconColor.gray : BeaconColor.graySeen)
            var parts: [String] = []
            if !asking.isEmpty { parts.append("\(asking.count) asking") }
            if !idle.isEmpty { parts.append("\(idle.count) idle") }
            return SlotView(fill: list.isEmpty ? BeaconColor.gray : fill, count: list.count,
                            rim: asking.isEmpty && freshIdle,
                            tooltip: list.isEmpty ? "Nothing needs you" : "Needs you (\(parts.joined(separator: ", "))): \(names(list))")
        case .asking:
            return SlotView(fill: freshAsk || asking.isEmpty ? BeaconColor.amber : BeaconColor.amberSeen,
                            count: asking.count, rim: false,
                            tooltip: asking.isEmpty ? "Nothing asking you" : "Asking you (\(asking.count)): \(names(asking))")
        case .idle:
            return SlotView(fill: freshIdle || idle.isEmpty ? BeaconColor.gray : BeaconColor.graySeen,
                            count: idle.count, rim: freshIdle,
                            tooltip: idle.isEmpty ? "Nothing idle" : "Idle (\(idle.count)): \(names(idle))")
        case .work:
            return SlotView(fill: BeaconColor.green, count: working.count, rim: false,
                            tooltip: working.isEmpty ? "Nothing working" : "Working (\(working.count)): \(names(working))")
        }
    }
}

enum StatusIcon {
    static let diameter: CGFloat = 16
    static let gap: CGFloat = 4

    /// Draw the dots left to right in layout order.
    static func image(_ slots: [SlotView]) -> NSImage {
        let n = max(slots.count, 1)
        let d = StatusIcon.diameter, g = StatusIcon.gap
        let size = NSSize(width: CGFloat(n) * d + CGFloat(n - 1) * g, height: d)
        return NSImage(size: size, flipped: false) { _ in
            for (i, v) in slots.enumerated() {
                let rect = NSRect(x: CGFloat(i) * (d + g), y: 0, width: d, height: d)
                if v.count == 0 {
                    v.fill.withAlphaComponent(0.5).setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
                    ring.lineWidth = 1.5
                    ring.stroke()
                } else {
                    v.fill.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                    if v.rim {
                        NSColor.white.setStroke()
                        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                        ring.lineWidth = 1.5
                        ring.stroke()
                    }
                    StatusIcon.drawCount(v.count, in: rect)
                }
            }
            return true
        }
    }

    /// Offline: one gray disc with "!".
    static func offline() -> NSImage {
        let d = StatusIcon.diameter
        return NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            BeaconColor.graySeen.setFill()
            NSBezierPath(ovalIn: rect).fill()
            StatusIcon.drawText("!", in: rect)
            return true
        }
    }

    /// A small dot for menu items.
    static func menuDot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    private static func drawCount(_ count: Int, in rect: NSRect) {
        drawText(count > 9 ? "9+" : "\(count)", in: rect)
    }

    /// Center digits on their cap height, not the line box, so they sit in the middle of the disc.
    private static func drawText(_ text: String, in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: text.count > 1 ? 8.5 : 10.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let width = (text as NSString).size(withAttributes: attrs).width
        let baseline = rect.midY - font.capHeight / 2
        // draw(at:) takes the bottom of the line box; the baseline sits -descender above it
        let origin = NSPoint(x: rect.midX - width / 2, y: baseline + font.descender)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}
