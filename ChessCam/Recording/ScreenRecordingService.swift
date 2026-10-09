import Foundation
import AVFAudio
import ReplayKit

@MainActor
final class ScreenRecordingService {
    enum State: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    enum RecordingError: LocalizedError {
        case busy
        case unavailable
        case microphoneDenied
        case notRecording

        var errorDescription: String? {
            switch self {
            case .busy:
                return "Операция с записью уже выполняется."
            case .unavailable:
                return "Запись экрана сейчас недоступна."
            case .microphoneDenied:
                return "Для записи голоса нужен доступ к микрофону."
            case .notRecording:
                return "Активной записи нет."
            }
        }
    }

    private(set) var state: State = .idle

    private let recorder: RPScreenRecorder
    private let fileStore: RecordingFileStore

    init(fileStore: RecordingFileStore, recorder: RPScreenRecorder = .shared()) {
        self.fileStore = fileStore
        self.recorder = recorder
    }

    func start(includeMicrophone: Bool = true) async throws {
        guard state == .idle else { throw RecordingError.busy }
        guard recorder.isAvailable, !recorder.isRecording else {
            throw RecordingError.unavailable
        }

        state = .starting
        do {
            if includeMicrophone {
                guard await AVAudioApplication.requestRecordPermission() else {
                    throw RecordingError.microphoneDenied
                }
            }

            guard recorder.isAvailable else { throw RecordingError.unavailable }
            recorder.isMicrophoneEnabled = includeMicrophone
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                recorder.startRecording { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
            state = .recording
        } catch {
            state = recorder.isRecording ? .recording : .idle
            throw error
        }
    }

    func stop() async throws -> StoredRecordingFile {
        guard state == .recording else {
            throw state == .idle ? RecordingError.notRecording : RecordingError.busy
        }
        guard recorder.isRecording else {
            state = .idle
            throw RecordingError.notRecording
        }

        state = .stopping
        let pendingURL = fileStore.makePendingURL()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                recorder.stopRecording(withOutput: pendingURL) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
            let recording = try fileStore.finishRecording(at: pendingURL)
            state = .idle
            return recording
        } catch {
            state = recorder.isRecording ? .recording : .idle
            throw error
        }
    }
}
