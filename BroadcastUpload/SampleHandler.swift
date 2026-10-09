import AVFoundation
import ReplayKit

/// ReplayKit runs this extension in a separate process. It receives the
/// full-display broadcast and separate app and microphone audio buffers.
final class SampleHandler: RPBroadcastSampleHandler {
    private static let appGroup = "group.miromanovsky.ChessCam"

    private var recordingID: UUID?
    private var pendingURL: URL?
    private var writer: BroadcastMovieWriter?
    private var startedAt: TimeInterval = 0
    private var lastStateUpdate: TimeInterval = 0
    private var groupURL: URL?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else {
            finishBroadcastWithError(BroadcastError.groupUnavailable)
            return
        }

        do {
            let pending = groupURL.appendingPathComponent("Recordings/pending", isDirectory: true)
            let ready = groupURL.appendingPathComponent("Recordings/ready", isDirectory: true)
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: ready, withIntermediateDirectories: true)

            let id = UUID()
            let url = pending.appendingPathComponent(id.uuidString).appendingPathExtension("mov")
            recordingID = id
            pendingURL = url
            self.groupURL = groupURL
            writer = BroadcastMovieWriter(outputURL: url)
            writeState("starting")
        } catch {
            finishBroadcastWithError(error)
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard let writer else { return }
        do {
            let didStart = try writer.append(sampleBuffer, type: sampleBufferType)
            if didStart {
                startedAt = Date().timeIntervalSince1970
                writeState("recording")
            } else if startedAt > 0, Date().timeIntervalSince1970 - lastStateUpdate >= 1 {
                writeState("recording")
            }
        } catch {
            writeState("failed", message: error.localizedDescription)
            finishBroadcastWithError(error)
        }
    }

    override func broadcastFinished() {
        guard let writer, let pendingURL, let groupURL, let recordingID else { return }
        writeState("finishing")

        // Keep the extension alive until AVAssetWriter has finalized the movie.
        let completed = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finish { result in
            switch result {
            case .success:
                do {
                    let readyURL = groupURL
                        .appendingPathComponent("Recordings/ready", isDirectory: true)
                        .appendingPathComponent(recordingID.uuidString)
                        .appendingPathExtension("mov")
                    try FileManager.default.moveItem(at: pendingURL, to: readyURL)
                } catch {
                    finishError = error
                }
            case .failure(let error):
                finishError = error
            }
            completed.signal()
        }

        if completed.wait(timeout: .now() + 20) == .timedOut {
            writeState("failed", message: "Не удалось завершить видеофайл.")
        } else if let finishError {
            writeState("failed", message: finishError.localizedDescription)
        } else {
            writeState("finished")
        }
    }

    private func writeState(_ phase: String, message: String? = nil) {
        guard let groupURL, let recordingID else { return }
        let now = Date().timeIntervalSince1970
        let state = BroadcastState(
            id: recordingID.uuidString,
            phase: phase,
            startedAt: startedAt,
            updatedAt: now,
            message: message
        )
        let stateURL = groupURL.appendingPathComponent("broadcast-state.json")
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
            lastStateUpdate = now
        }
    }
}

private struct BroadcastState: Codable {
    let id: String
    let phase: String
    let startedAt: TimeInterval
    let updatedAt: TimeInterval
    let message: String?
}

private enum BroadcastError: LocalizedError {
    case groupUnavailable
    case invalidVideo
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .groupUnavailable: "Не удалось открыть общее хранилище ChessCam."
        case .invalidVideo: "Не удалось получить кадр экрана."
        case .writerFailed: "Не удалось записать видео."
        }
    }
}

private final class BroadcastMovieWriter {
    private let outputURL: URL
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var appAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var sessionStart: CMTime?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// Returns true after the first video frame starts the writer session.
    func append(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) throws -> Bool {
        if writer == nil {
            guard type == .video else { return false }
            try configure(using: sampleBuffer)
        }
        guard let writer, writer.status == .writing else {
            throw self.writer?.error ?? BroadcastError.writerFailed
        }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let sessionStart, time.isValid, time >= sessionStart else { return false }
        let input: AVAssetWriterInput?
        switch type {
        case .video: input = videoInput
        case .audioApp: input = appAudioInput
        case .audioMic: input = microphoneInput
        @unknown default: return false
        }
        if let input, input.isReadyForMoreMediaData, !input.append(sampleBuffer) {
            throw writer.error ?? BroadcastError.writerFailed
        }
        return time == sessionStart && type == .video
    }

    func finish(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard let writer, writer.status == .writing else {
            completion(.failure(writer?.error ?? BroadcastError.writerFailed))
            return
        }
        videoInput?.markAsFinished()
        appAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(writer.error ?? BroadcastError.writerFailed))
            }
        }
    }

    private func configure(using videoBuffer: CMSampleBuffer) throws {
        guard let image = CMSampleBufferGetImageBuffer(videoBuffer) else {
            throw BroadcastError.invalidVideo
        }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        // Separate tracks retain both sources without lossy microphone-to-speaker
        // loopback. The containing app mixes them after the broadcast completes.
        let appAudio = makeAudioInput(channels: 2)
        let micAudio = makeAudioInput(channels: 1)
        writer.add(appAudio)
        writer.add(micAudio)

        guard writer.startWriting() else { throw writer.error ?? BroadcastError.writerFailed }
        let start = CMSampleBufferGetPresentationTimeStamp(videoBuffer)
        writer.startSession(atSourceTime: start)
        self.writer = writer
        videoInput = video
        appAudioInput = appAudio
        microphoneInput = micAudio
        sessionStart = start
    }

    private func makeAudioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }
}
