import AVFoundation
import Foundation

struct StoredRecordingFile {
    let id: UUID
    let url: URL
    let createdAt: Date
    let sizeInBytes: Int64
}

@MainActor
final class RecordingFileStore {
    static let didSaveRecording = Notification.Name("RecordingFileStore.didSaveRecording")

    enum RecordingFormat: String, CaseIterable {
        case mov
        case mp4
    }

    enum StoreError: Error {
        case invalidPendingFile
        case emptyFile
        case recordingAlreadyExists
    }

    private let fileManager: FileManager
    private let recordingsDirectory: URL
    private let pendingDirectory: URL
    private var activePendingURLs = Set<URL>()

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

    /// Pass this URL to the recorder as the destination for a new recording.
    func makePendingURL(format: RecordingFormat = .mov) -> URL {
        let url = pendingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.rawValue)
        activePendingURLs.insert(url.standardizedFileURL)
        return url
    }

    /// Moves a completed recording into the permanent library. The source remains
    /// in .pending if validation or the move fails.
    func finishRecording(at pendingURL: URL, notify: Bool = true) throws -> StoredRecordingFile {
        let source = pendingURL.standardizedFileURL
        guard source.deletingLastPathComponent() == pendingDirectory.standardizedFileURL,
              let format = RecordingFormat(rawValue: source.pathExtension.lowercased()),
              let id = UUID(uuidString: source.deletingPathExtension().lastPathComponent),
              let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            throw StoreError.invalidPendingFile
        }
        guard (values.fileSize ?? 0) > 0 else { throw StoreError.emptyFile }

        let destination = recordingURL(for: id, format: format)
        guard !RecordingFormat.allCases.contains(where: {
            fileManager.fileExists(atPath: recordingURL(for: id, format: $0).path)
        }) else {
            throw StoreError.recordingAlreadyExists
        }
        try fileManager.moveItem(at: source, to: destination)
        activePendingURLs.remove(source)
        let recording = try fileInfo(at: destination, id: id)
        if notify { NotificationCenter.default.post(name: Self.didSaveRecording, object: self) }
        return recording
    }

    /// Revisit files left by an interrupted capture after their container is readable.
    func recoverPendingRecordings() async throws -> [StoredRecordingFile] {
        let urls = try fileManager.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var recovered: [StoredRecordingFile] = []
        for url in urls {
            guard !Task.isCancelled else { break }
            guard !activePendingURLs.contains(url.standardizedFileURL),
                  RecordingFormat(rawValue: url.pathExtension.lowercased()) != nil,
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            let asset = AVURLAsset(url: url)
            guard let playable = try? await asset.load(.isPlayable), playable,
                  let duration = try? await asset.load(.duration),
                  CMTimeGetSeconds(duration).isFinite,
                  CMTimeGetSeconds(duration) > 0 else { continue }
            guard !Task.isCancelled else { break }
            if let file = try? finishRecording(at: url, notify: false) {
                recovered.append(file)
            }
        }
        return recovered
    }

    func releasePendingRecording(at pendingURL: URL) {
        activePendingURLs.remove(pendingURL.standardizedFileURL)
    }

    /// Returns finished recordings only; incomplete files in .pending are omitted.
    func recordings() throws -> [StoredRecordingFile] {
        let urls = try fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url in
            guard RecordingFormat(rawValue: url.pathExtension.lowercased()) != nil,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                return nil
            }
            return try fileInfo(at: url, id: id)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func deleteRecording(id: UUID) throws {
        let urls = RecordingFormat.allCases.map { recordingURL(for: id, format: $0) }
        let existingURLs = urls.filter { fileManager.fileExists(atPath: $0.path) }
        for url in existingURLs.isEmpty ? [urls[0]] : existingURLs {
            try fileManager.removeItem(at: url)
        }
    }

    func discardPendingRecording(at pendingURL: URL) throws {
        let source = pendingURL.standardizedFileURL
        guard source.deletingLastPathComponent() == pendingDirectory.standardizedFileURL,
              RecordingFormat(rawValue: source.pathExtension.lowercased()) != nil,
              UUID(uuidString: source.deletingPathExtension().lastPathComponent) != nil else {
            throw StoreError.invalidPendingFile
        }
        try fileManager.removeItem(at: source)
        activePendingURLs.remove(source)
    }

    private func recordingURL(for id: UUID, format: RecordingFormat) -> URL {
        recordingsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension(format.rawValue)
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
