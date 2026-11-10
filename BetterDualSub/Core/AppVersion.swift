import Foundation

/// A release version such as "1.2.0" or a tag such as "v1.2.0", compared number by number ("1.10" > "1.9").
/// Anything after a hyphen ("1.2.0-beta") is ignored.
nonisolated struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let core = text.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
            .split(separator: "-", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        components = parts.compactMap { $0 }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}
