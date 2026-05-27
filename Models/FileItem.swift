import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    struct Resolution: Hashable {
        let width: Int
        let height: Int
        var description: String { "\(width)×\(height)" }
    }

    let id: UUID
    let path: String
    let name: String
    let size: Int
    let modificationDate: Date
    let creationDate: Date
    let fileExtension: String
    let mimeType: String?
    let md5Hash: String?
    let sha1Hash: String?
    let resolution: Resolution?
    let duration: TimeInterval?

    var url: URL { URL(fileURLWithPath: path) }
    var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    var modificationDateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.id == rhs.id }
}