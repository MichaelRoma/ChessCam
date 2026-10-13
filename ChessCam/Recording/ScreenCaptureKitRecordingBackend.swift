import Foundation
#if !targetEnvironment(simulator)
@preconcurrency import ScreenCaptureKit
#endif

@MainActor
protocol ScreenCaptureRecordingBackend: AnyObject {
    var isRecording: Bool { get }
    var onInterruption: ((Error) -> Void)? { get set }
    var onExternalFinishStarted: (() -> Void)? { get set }
    var onExternalCompletion: ((StoredRecordingFile) -> Void)? { get set }
    func start(includeMicrophone: Bool) async throws
    func stop() async throws -> StoredRecordingFile
}

#if !targetEnvironment(simulator)
@available(iOS 27.0, *)
@MainActor
final class ScreenCaptureKitRecordingBackend: ScreenCaptureRecordingBackend {
    private let fileStore: RecordingFileStore
    private let picker = SCContentSharingPicker.shared
    private lazy var delegate = CaptureDelegate(owner: self)
    private var selectionContinuation: CheckedContinuation<SCContentFilter, Error>?
    private var recordingStartContinuation: CheckedContinuation<Void, Error>?
    private var recordingStartTimeout: Task<Void, Never>?
    private var recordingFinishContinuation: CheckedContinuation<Void, Error>?
    private var recordingFinishTimeout: Task<Void, Never>?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var pendingURL: URL?
    private var recordingFinished = false
    private var recordingStarted = false
    private var recordingError: Error?
    private var startCompleted = false
    private var handlingInterruption = false
    private var isStopping = false

    var onInterruption: ((Error) -> Void)?
    var onExternalFinishStarted: (() -> Void)?
    var onExternalCompletion: ((StoredRecordingFile) -> Void)?

    var isRecording: Bool { stream != nil && recordingOutput != nil }

    init(fileStore: RecordingFileStore) {
        self.fileStore = fileStore
    }

    func start(includeMicrophone: Bool) async throws {
        guard picker.isAvailable else { throw ScreenRecordingService.RecordingError.unavailable }

        var pickerConfiguration = SCContentSharingPickerConfiguration()
        pickerConfiguration.showsMicrophoneControl = includeMicrophone
        picker.defaultConfiguration = pickerConfiguration
        picker.add(delegate)
        picker.isActive = true

        let filter: SCContentFilter
        do {
            filter = try await withCheckedThrowingContinuation { continuation in
                selectionContinuation = continuation
                picker.present(using: .display)
            }
        } catch {
            deactivatePicker()
            throw error
        }

        let pendingURL = fileStore.makePendingURL(format: .mp4)
        do {
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = false
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)

            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = pendingURL
            let output = SCRecordingOutput(configuration: outputConfiguration, delegate: delegate)
            try stream.addRecordingOutput(output)

            self.stream = stream
            recordingOutput = output
            self.pendingURL = pendingURL
            recordingFinished = false
            recordingStarted = false
            recordingError = nil
            try await stream.startCapture()
            if let recordingError { throw recordingError }
            if !recordingStarted {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    recordingStartContinuation = continuation
                    recordingStartTimeout = Task {
                        do {
                            try await Task.sleep(for: .seconds(10))
                        } catch {
                            return
                        }
                        recordingStartContinuation?.resume(throwing: ScreenRecordingService.RecordingError.unavailable)
                        recordingStartContinuation = nil
                        recordingStartTimeout = nil
                    }
                }
            }
            if let recordingError { throw recordingError }
            guard !recordingFinished else { throw ScreenRecordingService.RecordingError.unavailable }
            startCompleted = true
        } catch {
            if let stream { try? await stream.stopCapture() }
            clearSession()
            try? fileStore.discardPendingRecording(at: pendingURL)
            throw error
        }
    }

    func stop() async throws -> StoredRecordingFile {
        guard let stream, let recordingOutput, let pendingURL else {
            throw ScreenRecordingService.RecordingError.notRecording
        }
        isStopping = true

        do {
            if let recordingError { throw recordingError }
            if !recordingFinished {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    recordingFinishContinuation = continuation
                    do {
                        try stream.removeRecordingOutput(recordingOutput)
                        recordingFinishTimeout = Task {
                            do {
                                try await Task.sleep(for: .seconds(10))
                            } catch {
                                return
                            }
                            recordingFinishContinuation?.resume(throwing: ScreenRecordingService.RecordingError.unavailable)
                            recordingFinishContinuation = nil
                            recordingFinishTimeout = nil
                        }
                    } catch {
                        recordingFinishContinuation = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
            try await stream.stopCapture()
        } catch {
            try? await stream.stopCapture()
            if recordingStarted && !recordingFinished { await waitForRecordingFinish() }
            let recovered = recordingFinished ? try? fileStore.finishRecording(at: pendingURL) : nil
            clearSession()
            if let recovered { return recovered }
            throw error
        }
        clearSession()
        return try fileStore.finishRecording(at: pendingURL)
    }

    fileprivate func selected(_ filter: SCContentFilter) {
        selectionContinuation?.resume(returning: filter)
        selectionContinuation = nil
    }

    fileprivate func selectionCancelled() {
        selectionContinuation?.resume(throwing: CancellationError())
        selectionContinuation = nil
    }

    fileprivate func selectionFailed(_ error: Error) {
        selectionContinuation?.resume(throwing: error)
        selectionContinuation = nil
    }

    fileprivate func recordingDidFinish(_ output: SCRecordingOutput) {
        guard output === recordingOutput else { return }
        recordingFinished = true
        recordingFinishTimeout?.cancel()
        recordingFinishTimeout = nil
        recordingFinishContinuation?.resume()
        recordingFinishContinuation = nil

        guard startCompleted, !isStopping, !handlingInterruption,
              recordingError == nil, let stream, let pendingURL else { return }
        isStopping = true
        onExternalFinishStarted?()
        Task {
            let stopError: Error?
            do {
                try await stream.stopCapture()
                stopError = nil
            } catch {
                stopError = error
            }
            let captureError = recordingError ?? stopError
            clearSession()
            do {
                let saved = try fileStore.finishRecording(at: pendingURL)
                if let captureError {
                    onInterruption?(PartialRecordingError(cause: captureError))
                } else {
                    onExternalCompletion?(saved)
                }
            } catch {
                onInterruption?(captureError ?? error)
            }
        }
    }

    fileprivate func recordingDidStart(_ output: SCRecordingOutput) {
        guard output === recordingOutput else { return }
        recordingStarted = true
        recordingStartTimeout?.cancel()
        recordingStartTimeout = nil
        recordingStartContinuation?.resume()
        recordingStartContinuation = nil
    }

    fileprivate func recordingDidFail(_ error: Error, output: SCRecordingOutput) {
        guard output === recordingOutput else { return }
        recordingError = error
        recordingStartTimeout?.cancel()
        recordingStartTimeout = nil
        recordingStartContinuation?.resume(throwing: error)
        recordingStartContinuation = nil
        recordingFinishTimeout?.cancel()
        recordingFinishTimeout = nil
        recordingFinishContinuation?.resume(throwing: error)
        recordingFinishContinuation = nil
        interruptIfNeeded(error)
    }

    fileprivate func streamDidFail(_ error: Error, stream: SCStream) {
        guard stream === self.stream else { return }
        recordingError = error
        recordingStartTimeout?.cancel()
        recordingStartTimeout = nil
        recordingStartContinuation?.resume(throwing: error)
        recordingStartContinuation = nil
        recordingFinishTimeout?.cancel()
        recordingFinishTimeout = nil
        recordingFinishContinuation?.resume(throwing: error)
        recordingFinishContinuation = nil
        interruptIfNeeded(error)
    }

    private func interruptIfNeeded(_ error: Error) {
        guard startCompleted, !isStopping, !handlingInterruption else { return }
        handlingInterruption = true
        let activeStream = stream
        let activeOutput = recordingOutput
        let activePendingURL = pendingURL
        Task {
            if let activeStream, let activeOutput, !recordingFinished {
                try? activeStream.removeRecordingOutput(activeOutput)
            }
            if let activeStream { try? await activeStream.stopCapture() }
            if recordingStarted && !recordingFinished { await waitForRecordingFinish() }
            let recovered: StoredRecordingFile?
            if recordingFinished, let activePendingURL {
                recovered = try? fileStore.finishRecording(at: activePendingURL)
            } else {
                recovered = nil
            }
            clearSession()
            onInterruption?(recovered == nil ? error : PartialRecordingError(cause: error))
        }
    }

    private func waitForRecordingFinish() async {
        for _ in 0..<20 {
            if recordingFinished { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func deactivatePicker() {
        picker.isActive = false
        picker.remove(delegate)
    }

    private func clearSession() {
        if let pendingURL { fileStore.releasePendingRecording(at: pendingURL) }
        stream = nil
        recordingOutput = nil
        pendingURL = nil
        recordingStartTimeout?.cancel()
        recordingStartTimeout = nil
        recordingFinishTimeout?.cancel()
        recordingFinishTimeout = nil
        recordingStartContinuation = nil
        recordingFinishContinuation = nil
        recordingFinished = false
        recordingStarted = false
        recordingError = nil
        startCompleted = false
        handlingInterruption = false
        isStopping = false
        deactivatePicker()
    }
}

@available(iOS 27.0, *)
private struct PartialRecordingError: LocalizedError {
    let cause: Error

    var errorDescription: String? {
        "Запись прервана: \(cause.localizedDescription) Записанный фрагмент сохранён в ChessCam."
    }
}

@available(iOS 27.0, *)
private final class CaptureDelegate: NSObject,
    SCContentSharingPickerObserver,
    SCRecordingOutputDelegate,
    SCStreamDelegate,
    @unchecked Sendable {
    nonisolated(unsafe) private weak var owner: ScreenCaptureKitRecordingBackend?

    init(owner: ScreenCaptureKitRecordingBackend) {
        self.owner = owner
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak owner] in owner?.selected(filter) }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak owner] in owner?.selectionCancelled() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak owner] in owner?.selectionFailed(error) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak owner] in owner?.recordingDidFinish(recordingOutput) }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak owner] in owner?.recordingDidStart(recordingOutput) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak owner] in owner?.recordingDidFail(error, output: recordingOutput) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak owner] in owner?.streamDidFail(error, stream: stream) }
    }
}
#endif
