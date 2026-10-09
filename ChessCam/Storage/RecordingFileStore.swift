import AVFoundation
import Foundation

struct StoredRecordingFile {
    let id: UUID
    let url: URL
    let createdAt: Date
    let sizeInBytes: Int64
}

final class RecordingFileStore {
    enum StoreError: LocalizedError {
        case invalidPendingFile
        case emptyFile
        case recordingAlreadyExists
        case invalidBroadcastFile
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .invalidPendingFile, .invalidBroadcastFile:
                return "Файл записи повреждён или недоступен."
            case .emptyFile:
                return "Запись получилась пустой."
            case .recordingAlreadyExists:
                return "Эта запись уже сохранена."
            case .exportFailed:
                return "Не удалось объединить звук сайта и микрофона."
            }
        }
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

    /// Imports a finalized broadcast movie from the shared App Group. Broadcasts
    /// contain separate app and microphone tracks; export renders them together.
    func importBroadcastRecording(at sourceURL: URL) async throws -> StoredRecordingFile {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.miromanovsky.ChessCam"
        ) else { throw StoreError.invalidBroadcastFile }
        let readyDirectory = groupURL.appendingPathComponent("Recordings/ready", isDirectory: true)
        let source = sourceURL.standardizedFileURL
        guard source.deletingLastPathComponent() == readyDirectory.standardizedFileURL,
              source.pathExtension.lowercased() == "mov",
              let id = UUID(uuidString: source.deletingPathExtension().lastPathComponent) else {
            throw StoreError.invalidBroadcastFile
        }

        let destination = recordingURL(for: id)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: source)
            return try fileInfo(at: destination, id: id)
        }

        let pending = pendingDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("mov")
        if fileManager.fileExists(atPath: pending.path) {
            try fileManager.removeItem(at: pending)
        }

        do {
            let asset = AVURLAsset(url: source)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if audioTracks.count > 1 {
                try await mixBroadcastTracks(asset: asset, audioTracks: audioTracks, outputURL: pending)
            } else {
                try fileManager.copyItem(at: source, to: pending)
            }
            let recording = try finishRecording(at: pending)
            try fileManager.removeItem(at: source)
            return recording
        } catch {
            try? fileManager.removeItem(at: pending)
            throw error
        }
    }

    func readyBroadcastURLs() throws -> [URL] {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.miromanovsky.ChessCam"
        ) else { throw StoreError.invalidBroadcastFile }
        let readyDirectory = groupURL.appendingPathComponent("Recordings/ready", isDirectory: true)
        try fileManager.createDirectory(at: readyDirectory, withIntermediateDirectories: true)
        return try fileManager.contentsOfDirectory(at: readyDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mov" }
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

    private func mixBroadcastTracks(
        asset: AVURLAsset,
        audioTracks: [AVAssetTrack],
        outputURL: URL
    ) async throws {
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first,
              let video = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else { throw StoreError.invalidBroadcastFile }

        let videoRange = try await sourceVideo.load(.timeRange)
        try video.insertTimeRange(videoRange, of: sourceVideo, at: videoRange.start)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)

        let audioMix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for sourceAudio in audioTracks {
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw StoreError.exportFailed }
            let range = try await sourceAudio.load(.timeRange)
            try track.insertTimeRange(range, of: sourceAudio, at: range.start)
            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(1, at: .zero)
            parameters.append(parameter)
        }
        audioMix.inputParameters = parameters

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StoreError.exportFailed
        }
        exporter.audioMix = audioMix
        try await exporter.export(to: outputURL, as: .mov)
    }
}
