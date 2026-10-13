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
    var onInterruption: ((Error) -> Void)?
    var onExternalFinishStarted: (() -> Void)?
    var onExternalCompletion: ((StoredRecordingFile) -> Void)?

    private let recorder: RPScreenRecorder
    private let fileStore: RecordingFileStore
    private let screenCaptureBackend: (any ScreenCaptureRecordingBackend)?

    init(fileStore: RecordingFileStore, recorder: RPScreenRecorder = .shared()) {
        self.fileStore = fileStore
        self.recorder = recorder
        #if targetEnvironment(simulator)
        screenCaptureBackend = nil
        #else
        if #available(iOS 27.0, *) {
            screenCaptureBackend = ScreenCaptureKitRecordingBackend(fileStore: fileStore)
        } else {
            screenCaptureBackend = nil
        }
        #endif
        screenCaptureBackend?.onInterruption = { [weak self] error in
            guard let self, self.state != .idle else { return }
            self.state = .idle
            self.onInterruption?(error)
        }
        screenCaptureBackend?.onExternalFinishStarted = { [weak self] in
            guard let self, self.state == .recording else { return }
            self.state = .stopping
            self.onExternalFinishStarted?()
        }
        screenCaptureBackend?.onExternalCompletion = { [weak self] recording in
            guard let self, self.state == .stopping else { return }
            self.state = .idle
            self.onExternalCompletion?(recording)
        }
    }

    func start(includeMicrophone: Bool = true) async throws {
        guard state == .idle else { throw RecordingError.busy }
        guard screenCaptureBackend != nil || (recorder.isAvailable && !recorder.isRecording) else {
            throw RecordingError.unavailable
        }

        state = .starting
        do {
            if let screenCaptureBackend {
                try await screenCaptureBackend.start(includeMicrophone: includeMicrophone)
            } else {
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
            }
            state = .recording
        } catch {
            state = (screenCaptureBackend?.isRecording ?? recorder.isRecording) ? .recording : .idle
            throw error
        }
    }

    func stop() async throws -> StoredRecordingFile {
        guard state == .recording else {
            throw state == .idle ? RecordingError.notRecording : RecordingError.busy
        }
        guard screenCaptureBackend?.isRecording ?? recorder.isRecording else {
            state = .idle
            throw RecordingError.notRecording
        }

        state = .stopping
        do {
            let recording: StoredRecordingFile
            if let screenCaptureBackend {
                recording = try await screenCaptureBackend.stop()
            } else {
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
                    recording = try fileStore.finishRecording(at: pendingURL)
                } catch {
                    fileStore.releasePendingRecording(at: pendingURL)
                    throw error
                }
            }
            state = .idle
            return recording
        } catch {
            state = (screenCaptureBackend?.isRecording ?? recorder.isRecording) ? .recording : .idle
            throw error
        }
    }
}
