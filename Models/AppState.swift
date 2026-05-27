import SwiftUI
import Combine
import AppKit

// MARK: - Scan Status

enum ScanStatus: Equatable {
    case idle
    case scanning
    case paused
    case stopped
    case completed

    var label: String {
        switch self {
        case .idle:      return "Ready"
        case .scanning:  return "Scanning..."
        case .paused:    return "Paused"
        case .stopped:   return "Stopped"
        case .completed: return "Completed"
        }
    }

    var systemImage: String {
        switch self {
        case .idle:      return "circle"
        case .scanning:  return "arrow.triangle.2.circlepath"
        case .paused:    return "pause.circle.fill"
        case .stopped:   return "stop.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

enum ResultsViewMode: String, CaseIterable {
    case list
    case thumbnail
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    @Published var monitoredDirectories: [String] = []
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var selectedRule = SearchRule.presets[0]
    @Published var scanStatus: ScanStatus = .idle
    @Published var scanProgress = 0.0
    @Published var currentFile = ""
    @Published var selectedFileIDs: Set<UUID> = []
    @Published var focusedFileID: UUID? = nil
    @Published var previewFile: FileItem?
    @Published var previewRequestCounter = 0
    @Published var showDeleteConfirmation = false
    @Published var totalFilesScanned = 0
    @Published var totalDuplicateGroups = 0
    @Published var resultsViewMode: ResultsViewMode = .list

    let scanner = FileScanner()
    let db = DatabaseManager()
    private var cancellables = Set<AnyCancellable>()
    private var groupMap: [UUID: DuplicateGroup] = [:]
    private var trashUndoStack: [(file: FileItem, originalURL: URL, trashURL: URL)] = []

    var isScanning: Bool { scanStatus == .scanning }
    var isPaused: Bool { scanStatus == .paused }
    var canStartScan: Bool { scanStatus == .idle || scanStatus == .stopped || scanStatus == .completed }
    var canPause: Bool { scanStatus == .scanning }
    var canResume: Bool { scanStatus == .paused }
    var canStop: Bool { scanStatus == .scanning || scanStatus == .paused }

    var allFiles: [FileItem] { duplicateGroups.flatMap { $0.files } }

    var totalSelectedCount: Int { selectedFileIDs.count }
    var totalDuplicateFileCount: Int { duplicateGroups.reduce(0) { $0 + $1.files.count } }

    init() {
        scanner.$progress.receive(on: DispatchQueue.main).assign(to: \.scanProgress, on: self).store(in: &cancellables)
        scanner.$currentFile.receive(on: DispatchQueue.main).assign(to: \.currentFile, on: self).store(in: &cancellables)
        scanner.fileScannedPublisher
            .collect(.byTimeOrCount(DispatchQueue.main, .milliseconds(250), 200))
            .sink { [weak self] files in
                self?.incrementalDuplicateCheck(files)
            }
            .store(in: &cancellables)
    }

    // MARK: - Directory management

    func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to scan for duplicates"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            guard !monitoredDirectories.contains(path) else { return }
            monitoredDirectories.append(path)
            Task { await startScan() }
        }
    }

    func removeDirectory(_ path: String) {
        monitoredDirectories.removeAll { $0 == path }
        if monitoredDirectories.isEmpty {
            duplicateGroups = []
            groupMap = [:]
            selectedFileIDs = []
            focusedFileID = nil
        }
    }

    func clearAllDirectories() {
        monitoredDirectories.removeAll()
        duplicateGroups = []
        groupMap = [:]
        selectedFileIDs = []
        focusedFileID = nil
        scanStatus = .idle
        totalFilesScanned = 0
        totalDuplicateGroups = 0
    }

    func rescanDirectory(_ path: String) {
        Task { await startScan() }
    }

    // MARK: - Scanning

    func startScan() async {
        guard !monitoredDirectories.isEmpty else { return }
        scanStatus = .scanning
        duplicateGroups = []
        groupMap = [:]
        db.deleteFiles(inScanRoots: monitoredDirectories)
        totalFilesScanned = 0
        totalDuplicateGroups = 0
        selectedFileIDs = []
        focusedFileID = nil
        for dir in monitoredDirectories {
            guard scanStatus == .scanning || scanStatus == .paused else { break }
            await scanner.scanDirectory(dir, db: db, rule: selectedRule, appState: self)
        }
        if scanStatus == .scanning { scanStatus = .completed }
    }

    func pauseScan() { if scanStatus == .scanning { scanStatus = .paused; scanner.pause() } }
    func resumeScan() { if scanStatus == .paused { scanStatus = .scanning; scanner.resume() } }
    func stopScan() { if scanStatus == .scanning || scanStatus == .paused { scanStatus = .stopped; scanner.cancel() } }

    // MARK: - Incremental duplicate detection

    private func incrementalDuplicateCheck(_ files: [FileItem]) {
        var changed = false
        for file in files {
            changed = incrementalDuplicateCheck(file, publishImmediately: false) || changed
        }
        if changed { publishDuplicateGroups() }
    }

    @discardableResult
    private func incrementalDuplicateCheck(_ file: FileItem, publishImmediately: Bool = true) -> Bool {
        guard !monitoredDirectories.isEmpty else { return false }
        if file.size < selectedRule.minFileSize { return false }
        if selectedRule.excludedExtensions.contains(file.fileExtension) { return false }
        totalFilesScanned += 1
        let matches = db.findMatchesFor(file: file, rule: selectedRule, dirs: monitoredDirectories)
        guard !matches.isEmpty else { return false }
        // Deduplicate by path: same file scanned from different dirs → single FileItem
        var seen = Set<String>()
        let allFiles = ([file] + matches).filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
        guard allFiles.count >= 2 else { return false }

        // Merge into existing group if any path overlaps
        let allPaths = Set(allFiles.map { $0.path })
        if let targetIdx = duplicateGroups.firstIndex(where: { group in
            group.files.contains(where: { allPaths.contains($0.path) })
        }) {
            var merged = duplicateGroups[targetIdx]
            let existingPaths = Set(merged.files.map { $0.path })
            let newcomers = allFiles.filter { !existingPaths.contains($0.path) }
            if !newcomers.isEmpty {
                merged.files.append(contentsOf: newcomers)
                merged.files.sort { $0.path < $1.path }
                groupMap[merged.id] = merged
            }
            if !newcomers.isEmpty, publishImmediately { publishDuplicateGroups() }
            return !newcomers.isEmpty
        }

        // Brand new group
        let confidence: DuplicateGroup.Confidence = selectedRule.ruleTypes.count >= 3 ? .high : (selectedRule.ruleTypes.count >= 2 ? .medium : .low)
        let newGroup = DuplicateGroup(id: UUID(), files: allFiles, matchingRules: selectedRule.ruleTypes, confidence: confidence, isNew: true)
        groupMap[newGroup.id] = newGroup
        if publishImmediately { publishDuplicateGroups() }
        return true
    }

    // MARK: - Focus

    func setFocus(_ fileID: UUID) { focusedFileID = fileID }
    func clearFocus() { focusedFileID = nil }
    func focusedFileForPreview() -> FileItem? {
        guard let fid = focusedFileID else { return nil }
        return allFiles.first(where: { $0.id == fid })
    }
    func requestPreview(_ file: FileItem) {
        focusedFileID = file.id
        previewFile = file
        previewRequestCounter += 1
    }

    // MARK: - Selection

    func toggleSelection(_ id: UUID) {
        if selectedFileIDs.contains(id) { selectedFileIDs.remove(id) } else { selectedFileIDs.insert(id) }
    }
    func selectAllInGroup(_ groupId: UUID) {
        guard let group = duplicateGroups.first(where: { $0.id == groupId }) else { return }
        for file in group.duplicateFiles { selectedFileIDs.insert(file.id) }
    }
    func deselectAllInGroup(_ groupId: UUID) {
        guard let group = duplicateGroups.first(where: { $0.id == groupId }) else { return }
        for file in group.files { selectedFileIDs.remove(file.id) }
    }
    func selectAllDuplicatesExceptOnePerGroup() {
        selectedFileIDs.removeAll()
        for group in duplicateGroups {
            let keepFile = group.fileToPreserve
            if let kf = keepFile {
                logDelete("[SelectDups] group \(group.id.uuidString.prefix(8)) keep: \(kf.name)")
            }
            for file in group.duplicateFiles {
                selectedFileIDs.insert(file.id)
                logDelete("[SelectDups]   select: \(file.name)")
            }
        }
        logDelete("[SelectDups] TOTAL selected: \(selectedFileIDs.count)")
    }
    func deselectAll() { selectedFileIDs.removeAll() }

    // MARK: - File operations

    @Published var deleteError: String?

    func requestDeleteConfirmation() {
        guard !selectedFileIDs.isEmpty else { return }
        selectedFileIDs = safeDeletionIDs(from: selectedFileIDs)
        guard !selectedFileIDs.isEmpty else { return }
        deleteSelected()
    }

    private static let deleteLogURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FastDup")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("delete.log")
    }()

    private func logDelete(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: AppState.deleteLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? line.write(to: AppState.deleteLogURL, atomically: false, encoding: .utf8)
        }
    }

    func deleteSelected() {
        Task { await deleteSelectedNow() }
    }

    private func deleteSelectedNow() async {
        let deletionIDs = safeDeletionIDs(from: selectedFileIDs)
        let filesToDelete = allFiles.filter { deletionIDs.contains($0.id) }
        logDelete("=== deleteSelected: \(filesToDelete.count) files, selectedFileIDs count: \(selectedFileIDs.count) ===")
        trashUndoStack.removeAll()
        var errors: [String] = []
        var recycleFallbackFiles: [FileItem] = []
        var recycleFallbackErrors: [UUID: Error] = [:]
        for file in filesToDelete {
            do {
                let trashURL = try moveFileToTrashQuietly(file)
                trashUndoStack.append((file, file.url, trashURL))
            } catch {
                recycleFallbackFiles.append(file)
                recycleFallbackErrors[file.id] = error
            }
        }

        if !recycleFallbackFiles.isEmpty {
            let fallbackResult = await recycleWithWorkspace(recycleFallbackFiles, originalErrors: recycleFallbackErrors)
            trashUndoStack.append(contentsOf: fallbackResult.moved.map { (file: $0.file, originalURL: $0.file.url, trashURL: $0.trashURL) })
            errors.append(contentsOf: fallbackResult.errors)
        }

        if !errors.isEmpty {
            deleteError = errors.joined(separator: "\n")
            logDelete("ERRORS: \(deleteError!)")
        }
        let deletedIDs = Set(trashUndoStack.map { $0.file.id })
        db.deleteFiles(paths: trashUndoStack.map { $0.file.path })
        logDelete("Successfully deleted \(trashUndoStack.count)/\(filesToDelete.count) files")
        removeDeletedFilesFromResults(deletedIDs)
        selectedFileIDs.removeAll()
        focusedFileID = nil
        showDeleteConfirmation = false
    }

    func deleteSingleFile(_ file: FileItem) {
        Task { await deleteSingleFileNow(file) }
    }

    private func deleteSingleFileNow(_ file: FileItem) async {
        do {
            trashUndoStack.removeAll()
            let trashURL = try moveFileToTrashQuietly(file)
            trashUndoStack.append((file, file.url, trashURL))
            db.deleteFiles(paths: [file.path])
            removeDeletedFilesFromResults([file.id])
            selectedFileIDs.remove(file.id)
            focusedFileID = nil
        } catch {
            let fallbackResult = await recycleWithWorkspace([file], originalErrors: [file.id: error])
            if let moved = fallbackResult.moved.first {
                trashUndoStack.append((moved.file, moved.file.url, moved.trashURL))
                db.deleteFiles(paths: [file.path])
                removeDeletedFilesFromResults([file.id])
                selectedFileIDs.remove(file.id)
                focusedFileID = nil
            } else {
                deleteError = fallbackResult.errors.first ?? "\(file.name): \(error.localizedDescription)"
                logDelete("ERROR: \(deleteError!)")
            }
        }
    }

    private func moveFileToTrashQuietly(_ file: FileItem) throws -> URL {
        let originalURL = file.url
        let exists = FileManager.default.fileExists(atPath: file.path)
        logDelete("File: \(file.path), exists: \(exists)")
        guard exists else {
            logDelete("SKIP (not found): \(file.path)")
            throw NSError(domain: "FastDup", code: 404, userInfo: [NSLocalizedDescriptionKey: "File no longer exists."])
        }

        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: originalURL, resultingItemURL: &result)
            let trashURL = (result as URL?) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").appendingPathComponent(file.name)
            logDelete("  TRASH OK -> \(trashURL.path)")
            return trashURL
        } catch {
            logDelete("  TRASH FAIL: \(error.localizedDescription)")
            do {
                let trashURL = try moveDirectlyToUserTrash(originalURL)
                logDelete("  DIRECT TRASH OK -> \(trashURL.path)")
                return trashURL
            } catch {
                logDelete("  DIRECT TRASH FAIL: \(error.localizedDescription)")
                throw error
            }
        }
    }

    private func moveDirectlyToUserTrash(_ url: URL) throws -> URL {
        let trashDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let destination = uniqueTrashURL(for: url.lastPathComponent, in: trashDirectory)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    private func uniqueTrashURL(for fileName: String, in trashDirectory: URL) -> URL {
        let baseURL = URL(fileURLWithPath: fileName)
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        var candidate = trashDirectory.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            candidate = trashDirectory.appendingPathComponent(nextName)
            counter += 1
        }
        return candidate
    }

    private func recycleWithWorkspace(_ files: [FileItem], originalErrors: [UUID: Error]) async -> (moved: [(file: FileItem, trashURL: URL)], errors: [String]) {
        guard !files.isEmpty else { return ([], []) }
        let urls = files.map(\.url)
        logDelete("  RECYCLE FALLBACK for \(files.count) files")
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { [weak self] newURLs, recycleError in
                let movedFiles = files.compactMap { file -> (file: FileItem, trashURL: URL)? in
                    guard let trashURL = newURLs[file.url] else { return nil }
                    return (file, trashURL)
                }

                Task { @MainActor in
                    self?.logDelete("  RECYCLE OK: \(movedFiles.count)/\(files.count)")
                    if let recycleError {
                        self?.logDelete("  RECYCLE PARTIAL ERROR: \(recycleError.localizedDescription)")
                    }
                }

                let failedFiles = files.filter { file in !movedFiles.contains { $0.file.id == file.id } }
                var errors = failedFiles.prefix(8).map { file in
                    if let error = originalErrors[file.id] {
                        return "\(file.name): \(error.localizedDescription)"
                    }
                    return "\(file.name): Could not move to Trash."
                }
                if let recycleError, errors.isEmpty {
                    errors.append(recycleError.localizedDescription)
                }
                let moreCount = max(0, failedFiles.count - 8)
                if moreCount > 0 { errors.append("...and \(moreCount) more") }
                continuation.resume(returning: (movedFiles, errors))
            }
        }
    }

    private func safeDeletionIDs(from ids: Set<UUID>) -> Set<UUID> {
        var safeIDs = ids
        for group in duplicateGroups {
            let groupIDs = Set(group.files.map(\.id))
            let selectedInGroup = groupIDs.intersection(safeIDs)
            if selectedInGroup.count == group.files.count, let keep = group.fileToPreserve {
                safeIDs.remove(keep.id)
                logDelete("[SafeDelete] preserving \(keep.name) because the whole group was selected")
            }
        }
        return safeIDs
    }

    private func removeDeletedFilesFromResults(_ deletedIDs: Set<UUID>) {
        duplicateGroups = duplicateGroups.compactMap { group in
            var g = group
            g.files.removeAll { deletedIDs.contains($0.id) }
            return g.files.count >= 2 ? g : nil
        }
        groupMap = Dictionary(uniqueKeysWithValues: duplicateGroups.map { ($0.id, $0) })
        totalDuplicateGroups = duplicateGroups.count
    }

    private func publishDuplicateGroups() {
        duplicateGroups = groupMap.values.sorted { lhs, rhs in
            let lhsPath = lhs.primaryFile?.path ?? ""
            let rhsPath = rhs.primaryFile?.path ?? ""
            if lhsPath != rhsPath { return lhsPath < rhsPath }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        totalDuplicateGroups = duplicateGroups.count
    }

    func undoLastDelete() {
        guard !trashUndoStack.isEmpty else { return }
        for (_, originalURL, trashURL) in trashUndoStack {
            if FileManager.default.fileExists(atPath: trashURL.path) {
                try? FileManager.default.moveItem(at: trashURL, to: originalURL)
            }
        }
        trashUndoStack.removeAll()
        Task { await startScan() }
    }

    var canUndo: Bool { !trashUndoStack.isEmpty }
}
