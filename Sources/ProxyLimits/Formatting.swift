import Foundation

public enum LimitFormat {
    /// "68%". Rounds down so a nearly empty window never reads fuller than it is, but a
    /// window with anything left never reads "0%".
    public static func percent(_ fraction: Double) -> String {
        let clamped = min(1, max(0, fraction))
        // The nudge keeps 1 - 0.34 (0.6599999…) from reading as 65%.
        let whole = Int((clamped * 100 + 1e-9).rounded(.down))
        return "\(whole == 0 && clamped > 0 ? 1 : whole)%"
    }

    /// "2h 14m", "3d 4h", "45m" or "under 1m" for the time between `now` and `date`.
    public static func duration(until date: Date, from now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.down))
        if minutes < 1 { return "under 1m" }
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        let remainder = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return remainder > 0 ? "\(hours)h \(remainder)m" : "\(hours)h" }
        return "\(remainder)m"
    }

    /// "just now", "5m ago", "3h ago" for how long ago `date` was.
    public static func age(of date: Date, at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}
