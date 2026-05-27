import Foundation

struct SearchRule: Identifiable, Hashable {
    enum RuleType: String, CaseIterable, Hashable {
        case exactHash = "Exact Hash (MD5)"
        case exactHashSHA = "Exact Hash (SHA1)"
        case sameName = "Same Name"
        case sameSize = "Same Size"
        case sameExtension = "Same Extension"
        case similarName = "Similar Name"
        case sameResolution = "Same Resolution"
        case sameDuration = "Same Duration"

        /// Human-readable short label for checkbox display
        var shortLabel: String {
            switch self {
            case .exactHash:     return "File Hash (MD5)"
            case .exactHashSHA:  return "File Hash (SHA1)"
            case .sameName:      return "File Name"
            case .sameSize:      return "File Size"
            case .sameExtension: return "Extension"
            case .similarName:   return "Similar Name"
            case .sameResolution: return "Resolution"
            case .sameDuration:  return "Duration"
            }
        }

        /// Category for grouping in the config panel
        var category: String {
            switch self {
            case .exactHash, .exactHashSHA, .sameSize, .sameExtension:
                return "General"
            case .sameName, .similarName:
                return "Name"
            case .sameResolution, .sameDuration:
                return "Media"
            }
        }
    }

    let id: UUID
    let name: String
    var ruleTypes: [RuleType]
    var minFileSize: Int64
    var excludedExtensions: Set<String>

    static let presets: [SearchRule] = [
        SearchRule(id: UUID(), name: "Fast Scan", ruleTypes: [.sameSize, .sameExtension], minFileSize: 0, excludedExtensions: []),
        SearchRule(id: UUID(), name: "Exact Duplicates", ruleTypes: [.exactHash, .sameSize], minFileSize: 0, excludedExtensions: []),
        SearchRule(id: UUID(), name: "Same Name & Size", ruleTypes: [.sameName, .sameSize], minFileSize: 0, excludedExtensions: []),
        SearchRule(id: UUID(), name: "Same Name Only", ruleTypes: [.sameName], minFileSize: 0, excludedExtensions: []),
        SearchRule(id: UUID(), name: "Same Size Only", ruleTypes: [.sameSize], minFileSize: 1024*1024, excludedExtensions: []),
        SearchRule(id: UUID(), name: "Duplicate Images", ruleTypes: [.sameResolution, .sameSize], minFileSize: 0, excludedExtensions: [])
    ]

    var requiresMD5: Bool { ruleTypes.contains(.exactHash) }
    var requiresSHA1: Bool { ruleTypes.contains(.exactHashSHA) }
    var requiresImageMetadata: Bool { ruleTypes.contains(.sameResolution) }
    var requiresVideoMetadata: Bool { ruleTypes.contains(.sameDuration) }

    var hashAlgorithm: String {
        ruleTypes.contains(.exactHashSHA) ? "SHA1" : "MD5"
    }

    /// Dynamic name based on selected dimensions
    var displayName: String {
        if ruleTypes.isEmpty { return "No dimensions selected" }
        let labels = ruleTypes.map { $0.shortLabel }
        if labels.count <= 2 {
            return labels.joined(separator: " + ")
        }
        return "\(labels.count) dimensions"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SearchRule, rhs: SearchRule) -> Bool { lhs.id == rhs.id }
}
