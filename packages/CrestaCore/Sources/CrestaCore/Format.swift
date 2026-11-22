import Foundation

/// Italian formatting of numbers, distances and times.
public enum Format {
    static let it = Locale(identifier: "it_IT")

    public static func number(_ v: Double, decimals: Int = 0) -> String {
        let f = NumberFormatter()
        f.locale = it
        f.numberStyle = .decimal
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    public static func meters(_ m: Double) -> String { "\(number(m.rounded())) m" }

    public static func km(_ m: Double) -> String {
        m < 1000 ? "\(Int(m.rounded())) m" : "\(number(m / 1000, decimals: m < 100_000 ? 1 : 0)) km"
    }

    public static func speed(_ mps: Double) -> String { "\(number(mps * 3.6, decimals: 1)) km/h" }

    /// "3 h 25 min", "45 min".
    public static func duration(_ s: TimeInterval) -> String {
        let total = Int((s / 60).rounded())
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m) min" }
        if h >= 100 { return "\(h) h" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "3:25" for compact tiles.
    public static func clock(_ s: TimeInterval) -> String {
        let total = Int((s / 60).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public static func monthName(_ m: Int) -> String {
        let names = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"]
        return names[max(0, min(11, m - 1))]
    }

    public static func dayMonth(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month], from: d)
        return "\(c.day ?? 1) \(monthName(c.month ?? 1))"
    }

    public static func dayMonthYear(_ d: Date, calendar: Calendar = .current) -> String {
        "\(dayMonth(d, calendar: calendar)) \(calendar.component(.year, from: d))"
    }

    public static func time(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "yyyy-MM-dd" in the given time zone (API parameters).
    public static func isoDay(_ d: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
    }

    public static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}
