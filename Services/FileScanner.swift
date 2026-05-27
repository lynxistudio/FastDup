import Foundation
import Combine
import CommonCrypto
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

final class FileScanner: ObservableObject {
    @Published var progress = 0.0
    @Published var currentFile = ""
    @Published var scannedFiles: [FileItem] = []

    /// Streaming publisher: emits each file as it's scanned and upserted to DB.
    let fileScannedPublisher = PassthroughSubject<FileItem, Never>()

    private var cancellationToken = false
    private var isPaused = false
    private let pauseLock = NSLock()
    private let queue = DispatchQueue(label: "com.fastdup.scanner", qos: .userInitiated)

    // MARK: - Control

    func cancel() {
        cancellationToken = true
        isPaused = false
    }

    func pause() {
        pauseLock.lock()
        isPaused = true
        pauseLock.unlock()
    }

    func resume() {
        pauseLock.lock()
        isPaused = false
        pauseLock.unlock()
    }

    private var isCurrentlyPaused: Bool {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        return isPaused
    }

    // MARK: - Scanning

    func scanDirectory(_ dir: String, db: DatabaseManager, rule: SearchRule, appState: AppState) async {
        cancellationToken = false
        isPaused = false
        await MainActor.run {
            scannedFiles = []
            progress = 0.0
            currentFile = ""
        }

        let fileManager = FileManager.default
        let dirURL = URL(fileURLWithPath: dir)
        var allURLs: [URL] = []

        // Enumerate all files first to get accurate progress
        if let enumerator = fileManager.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            while let url = enumerator.nextObject() as? URL {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    allURLs.append(url)
                }
            }
        }

        let total = Double(allURLs.count)
        var lastUIUpdate = Date.distantPast
        for (i, url) in allURLs.enumerated() {
            // Check cancellation
            if cancellationToken { break }

            // Check pause — spin-wait while paused
            while isCurrentlyPaused && !cancellationToken {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            if cancellationToken { break }

            let now = Date()
            if i == 0 || i == allURLs.count - 1 || now.timeIntervalSince(lastUIUpdate) >= 0.12 {
                await MainActor.run {
                    currentFile = url.lastPathComponent
                    progress = Double(i) / max(total, 1)
                }
                lastUIUpdate = now
            }

            if let fileItem = await processFile(url: url, rootDirectory: dir, db: db, rule: rule) {
                // Emit the file for incremental duplicate detection
                fileScannedPublisher.send(fileItem)
            }
        }
        await MainActor.run { progress = 1.0 }
    }

    // MARK: - File processing

    private func processFile(url: URL, rootDirectory: String, db: DatabaseManager, rule: SearchRule) async -> FileItem? {
        let fileManager = FileManager.default
        let path = url.path
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? Int) ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()
        let createDate = (attrs[.creationDate] as? Date) ?? Date()

        // MIME type
        let mimeType: String? = {
            if let uti = UTType(filenameExtension: ext) {
                return uti.preferredMIMEType
            }
            return nil
        }()

        let md5 = rule.requiresMD5 ? computeMD5(path: path) : nil
        let sha1 = rule.requiresSHA1 ? computeSHA1(path: path) : nil

        let resolution = rule.requiresImageMetadata ? getImageResolution(path: path) : nil

        let duration = rule.requiresVideoMetadata ? await getVideoDuration(path: path) : nil

        let fileItem = FileItem(
            id: UUID(),
            path: path,
            name: name,
            size: size,
            modificationDate: modDate,
            creationDate: createDate,
            fileExtension: ext,
            mimeType: mimeType,
            md5Hash: md5,
            sha1Hash: sha1,
            resolution: resolution,
            duration: duration
        )

        db.upsert(fileItem, directory: rootDirectory)
        return fileItem
    }

    // MARK: - Hashing & metadata

    private func computeMD5(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return nil
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func computeSHA1(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return nil
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func getImageResolution(path: String) -> FileItem.Resolution? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return FileItem.Resolution(width: width, height: height)
    }

    private func getVideoDuration(path: String) async -> TimeInterval? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            return nil
        }
    }
}
