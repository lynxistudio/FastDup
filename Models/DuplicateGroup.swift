import Foundation

struct DuplicateGroup: Identifiable, Hashable {
    enum Confidence: String, Hashable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"
    }

    let id: UUID
    var files: [FileItem]
    let matchingRules: [SearchRule.RuleType]
    let confidence: Confidence
    var isNew: Bool = false  // For highlighting newly discovered groups

    var potentialSavings: Int64 {
        duplicateFiles.reduce(0) { $0 + Int64($1.size) }
    }
    var savingsFormatted: String { ByteCountFormatter.string(fromByteCount: potentialSavings, countStyle: .file) }
    var primaryFile: FileItem? { fileToPreserve }
    var duplicateFiles: [FileItem] {
        guard let keep = fileToPreserve else { return [] }
        return files.filter { $0.id != keep.id }
    }

    var fileToPreserve: FileItem? {
        files.min { lhs, rhs in
            if lhs.creationDate != rhs.creationDate { return lhs.creationDate < rhs.creationDate }
            if lhs.modificationDate != rhs.modificationDate { return lhs.modificationDate < rhs.modificationDate }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }
    }

    /// Returns true if all files in this group are selected (by ID set)
    func isAllSelected(in selectedIDs: Set<UUID>) -> Bool {
        let deletableFiles = duplicateFiles
        return !deletableFiles.isEmpty && deletableFiles.allSatisfy { selectedIDs.contains($0.id) }
    }

    /// Returns true if any file in this group is selected
    func isAnySelected(in selectedIDs: Set<UUID>) -> Bool {
        duplicateFiles.contains { selectedIDs.contains($0.id) }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DuplicateGroup, rhs: DuplicateGroup) -> Bool { lhs.id == rhs.id }
}
