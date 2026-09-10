import Foundation

/// Dotted numeric versions. Pre-release and build suffixes are dropped, not
/// ordered: `1.2.0-beta` compares as `1.2.0`. Shared by both channels so the
/// offer and the install cannot disagree.
public enum Versions {
    public static func components(_ version: String) -> [Int] {
        let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? version
        return core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        var x = components(a), y = components(b)
        let n = max(x.count, y.count)
        x += Array(repeating: 0, count: n - x.count)
        y += Array(repeating: 0, count: n - y.count)
        for (p, q) in zip(x, y) where p != q { return p < q ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }
}
