import AppKit

/// Parsers for the little text prompts (times, sizes, page lists, colours).
enum Parse {
    /// "75", "1:15", "1:02:03.5" → seconds.
    static func time(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let part, part >= 0 else { return nil }
            total = total * 60 + part
        }
        return total
    }

    /// "0:05 - 1:20" → (5, 80).
    static func range(_ raw: String) -> (start: Double, end: Double)? {
        let normalized = raw
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " to ", with: "-")
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = time(String(parts[0])), let b = time(String(parts[1])), b > a else { return nil }
        return (a, b)
    }

    /// "0:05-0:06, 1:10-1:12" → [(5,6), (70,72)].
    static func ranges(_ raw: String) -> [(start: Double, end: Double)]? {
        let items = raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
        let parsed = items.compactMap { range(String($0)) }
        return !parsed.isEmpty && parsed.count == items.count ? parsed : nil
    }

    /// "500 KB", "2mb", "1.5 GB", "3" (MB) → bytes.
    static func byteSize(_ raw: String) -> Int64? {
        let s = raw.lowercased().replacingOccurrences(of: " ", with: "")
        let digits = s.prefix { "0123456789.".contains($0) }
        guard let n = Double(digits), n > 0 else { return nil }
        let multiplier: Double
        switch s.dropFirst(digits.count) {
        case "", "m", "mb": multiplier = 1_000_000
        case "k", "kb": multiplier = 1_000
        case "g", "gb": multiplier = 1_000_000_000
        case "b": multiplier = 1
        default: return nil
        }
        return Int64(n * multiplier)
    }

    /// "3,1,2,4-6" → zero-based page indices. Pages in the input are 1-based.
    static func pages(_ raw: String, count: Int) -> [Int]? {
        guard count > 0 else { return nil }
        var result: [Int] = []
        for item in raw.split(separator: ",") {
            let token = item.replacingOccurrences(of: " ", with: "")
            if token.isEmpty { continue }
            let bits = token.split(separator: "-", omittingEmptySubsequences: false)
            if bits.count == 1, let p = Int(bits[0]) {
                guard (1...count).contains(p) else { return nil }
                result.append(p - 1)
            } else if bits.count == 2 {
                let a = bits[0].isEmpty ? 1 : Int(bits[0])
                let b = bits[1].isEmpty ? count : Int(bits[1])
                guard let a, let b, (1...count).contains(a), (1...count).contains(b) else { return nil }
                result += a <= b ? Array((a - 1)...(b - 1)) : Array(stride(from: a - 1, through: b - 1, by: -1))
            } else {
                return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    /// "1-3, 4-6, 7" → groups of zero-based page indices.
    static func pageGroups(_ raw: String, count: Int) -> [[Int]]? {
        let groups = raw.split(separator: ",").map { pages(String($0), count: count) }
        guard !groups.isEmpty, groups.allSatisfy({ $0 != nil }) else { return nil }
        return groups.compactMap { $0 }
    }

    static func color(_ raw: String) -> NSColor? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let named: [String: NSColor] = [
            "white": .white, "black": .black, "red": .systemRed, "orange": .systemOrange,
            "yellow": .systemYellow, "green": .systemGreen, "blue": .systemBlue,
            "purple": .systemPurple, "pink": .systemPink, "gray": .systemGray, "grey": .systemGray,
        ]
        if let c = named[s] { return c }
        var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
