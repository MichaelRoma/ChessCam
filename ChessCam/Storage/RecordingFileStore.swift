import Foundation

struct StoredRecordingFile {
    let id: UUID
    let url: URL
    let createdAt: Date
    let sizeInBytes: Int64
}

final class RecordingFileStore {
    enum StoreError: Error {
        case invalidPendingFile
        case emptyFile
        case recordingAlreadyExists
    }

    private let fileManager: FileManager
    private let recordingsDirectory: URL
    private let pendingDirectory: URL

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        recordingsDirectory = applicationSupport.appendingPathComponent("Recordings", isDirectory: true)
        pendingDirectory = recordingsDirectory.appendingPathComponent(".pending", isDirectory: true)

        try fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
    }

    /// Pass this URL to the recorder as the destination for a new .mov file.
    func makePendingURL() -> URL {
        pendingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    /// Moves a completed recording into the permanent library. The source remains
    /// in .pending if validation or the move fails.
    func finishRecording(at pendingURL: URL) throws -> StoredRecordingFile {
        let source = pendingURL.standardizedFileURL
        guard source.deletingLastPathComponent() == pendingDirectory.standardizedFileURL,
              source.pathExtension.lowercased() == "mov",
              let id = UUID(uuidString: source.deletingPathExtension().lastPathComponent),
              let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            throw StoreError.invalidPendingFile
        }
        guard (values.fileSize ?? 0) > 0 else { throw StoreError.emptyFile }

        let destination = recordingURL(for: id)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw StoreError.recordingAlreadyExists
        }
        try fileManager.moveItem(at: source, to: destination)
        return try fileInfo(at: destination, id: id)
    }

    /// Returns finished recordings only; incomplete files in .pending are omitted.
    func recordings() throws -> [StoredRecordingFile] {
        let urls = try fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url in
            guard url.pathExtension.lowercased() == "mov",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            return try fileInfo(at: url, id: id)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func deleteRecording(id: UUID) throws {
        try fileManager.removeItem(at: recordingURL(for: id))
    }

    func discardPendingRecording(at pendingURL: URL) throws {
        let source = pendingURL.standardizedFileURL
        guard source.deletingLastPathComponent() == pendingDirectory.standardizedFileURL,
              source.pathExtension.lowercased() == "mov",
              UUID(uuidString: source.deletingPathExtension().lastPathComponent) != nil else {
            throw StoreError.invalidPendingFile
        }
        try fileManager.removeItem(at: source)
    }

    private func recordingURL(for id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("mov")
    }

    private func fileInfo(at url: URL, id: UUID) throws -> StoredRecordingFile {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey])
        guard values.isRegularFile == true else { throw StoreError.invalidPendingFile }
        return StoredRecordingFile(
            id: id,
            url: url,
            createdAt: values.creationDate ?? .distantPast,
            sizeInBytes: Int64(values.fileSize ?? 0)
        )
    }
}
