import Foundation

@main
struct DeleteDedupRegression {
    static func main() async throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("FastDupDeleteDedupRegression-\(UUID().uuidString)")
        try fileManager.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: testDirectory) }

        let preservedURL = testDirectory.appendingPathComponent("keep.txt")
        let duplicateURL = testDirectory.appendingPathComponent("duplicate.txt")
        try Data("same contents".utf8).write(to: preservedURL)
        try Data("same contents".utf8).write(to: duplicateURL)

        let now = Date()
        let keep = makeFileItem(url: preservedURL, date: now.addingTimeInterval(-10))
        let duplicate = makeFileItem(url: duplicateURL, date: now)
        let groupOne = DuplicateGroup(
            id: UUID(),
            files: [keep, duplicate],
            matchingRules: [.sameSize, .sameExtension],
            confidence: .medium
        )
        let groupTwo = DuplicateGroup(
            id: UUID(),
            files: [keep, duplicate],
            matchingRules: [.sameSize, .sameExtension],
            confidence: .medium
        )

        let state = await MainActor.run { AppState() }
        await MainActor.run {
            state.duplicateGroups = [groupOne]
            state.selectAllInGroup(groupOne.id)
        }
        var selectedIDs = await MainActor.run { state.selectedFileIDs }
        guard selectedIDs == [duplicate.id] else {
            throw RegressionError.keepSwitchDidNotSelectDefaultDuplicate
        }
        await MainActor.run {
            state.setFileToPreserve(duplicate.id, in: groupOne.id)
        }
        selectedIDs = await MainActor.run { state.selectedFileIDs }
        guard selectedIDs == [keep.id] else {
            throw RegressionError.keepSwitchDidNotRetargetSelection
        }

        await MainActor.run {
            state.duplicateGroups = [groupOne, groupTwo]
            state.selectedFileIDs = [duplicate.id]
            state.deleteSelected()
        }

        try await Task.sleep(nanoseconds: 800_000_000)

        let error = await MainActor.run { state.deleteError }
        guard error == nil else {
            throw RegressionError.unexpectedDeleteError(error!)
        }
        guard !fileManager.fileExists(atPath: duplicateURL.path) else {
            throw RegressionError.duplicateStillExists
        }

        let canUndo = await MainActor.run { state.canUndo }
        guard canUndo else {
            throw RegressionError.undoUnavailable
        }
        await MainActor.run { state.undoLastDelete() }
        guard fileManager.fileExists(atPath: duplicateURL.path) else {
            throw RegressionError.undoDidNotRestoreFile
        }

        try fileManager.removeItem(at: duplicateURL)
        await MainActor.run {
            state.duplicateGroups = [groupOne]
            state.deleteSingleFile(duplicate)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let staleDeleteError = await MainActor.run { state.deleteError }
        guard staleDeleteError == nil else {
            throw RegressionError.unexpectedDeleteError(staleDeleteError!)
        }

        print("Delete dedup regression passed")
    }

    private static func makeFileItem(url: URL, date: Date) -> FileItem {
        FileItem(
            id: UUID(),
            path: url.path,
            name: url.lastPathComponent,
            size: 13,
            modificationDate: date,
            creationDate: date,
            fileExtension: url.pathExtension,
            mimeType: nil,
            md5Hash: nil,
            sha1Hash: nil,
            resolution: nil,
            duration: nil
        )
    }
}

enum RegressionError: Error {
    case unexpectedDeleteError(String)
    case duplicateStillExists
    case undoUnavailable
    case undoDidNotRestoreFile
    case keepSwitchDidNotSelectDefaultDuplicate
    case keepSwitchDidNotRetargetSelection
}
