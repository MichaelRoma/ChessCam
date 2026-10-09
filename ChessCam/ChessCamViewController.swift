import UIKit
import ReplayKit

final class ChessCamViewController: UIViewController {
    private let green = UIColor(red: 0.29, green: 0.49, blue: 0.30, alpha: 1)
    private var settings = AppSettings.load()
    private lazy var chessWebController = ChessWebViewController(site: settings.site)
    private lazy var cameraController = CameraViewController(mirrored: settings.mirrorCamera)
    private var webHeightConstraint: NSLayoutConstraint!
    private var fileStore: RecordingFileStore?
    private let photoExporter = PhotoLibraryExporter()
    private var storageError: Error?
    private let broadcastPicker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    private let recordingTimerLabel = UILabel()
    private var recordingTimer: Timer?
    private var statusTimer: Timer?
    private var recordingStartDate: Date?
    private var isRecordingUI = false
    private var isImporting = false
    private var handledStatusIDs = Set<String>()
    private var failedImportAt: [URL: Date] = [:]

    override var prefersStatusBarHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ChessCam"
        view.backgroundColor = .white
        do {
            let store = try RecordingFileStore()
            fileStore = store
        } catch {
            storageError = error
        }
        configureNavigationBar()
        buildContent()
        statusTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(pollBroadcastStatus),
            userInfo: nil,
            repeats: true
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pollBroadcastStatus),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        pollBroadcastStatus()
    }

    deinit {
        statusTimer?.invalidate()
        recordingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

private extension ChessCamViewController {
    func configureNavigationBar() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "‹ Записи", style: .plain, target: self, action: #selector(openRecordings)
        )
        navigationItem.leftBarButtonItem?.tintColor = green
        navigationItem.backButtonDisplayMode = .minimal
        navigationController?.navigationBar.tintColor = green
        let settingsButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(openSettings)
        )
        settingsButton.tintColor = green
        broadcastPicker.preferredExtension = "miromanovsky.ChessCam.BroadcastUpload"
        broadcastPicker.showsMicrophoneButton = true
        broadcastPicker.tintColor = green
        broadcastPicker.accessibilityLabel = "Начать или остановить запись"
        navigationItem.rightBarButtonItems = [settingsButton, UIBarButtonItem(customView: broadcastPicker)]

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .white
        appearance.shadowColor = UIColor.systemGray5
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
    }

    func buildContent() {
        addChild(chessWebController)
        addChild(cameraController)
        let webContentView = chessWebController.view!
        let cameraContentView = cameraController.view!

        let content = UIStackView(arrangedSubviews: [webContentView, cameraContentView])
        content.axis = .vertical
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        webHeightConstraint = webContentView.heightAnchor.constraint(
            equalTo: cameraContentView.heightAnchor,
            multiplier: CGFloat(settings.boardFraction / (1 - settings.boardFraction))
        )

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webHeightConstraint
        ])

        recordingTimerLabel.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        recordingTimerLabel.textColor = .white
        recordingTimerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        recordingTimerLabel.textAlignment = .center
        recordingTimerLabel.layer.cornerRadius = 8
        recordingTimerLabel.layer.masksToBounds = true
        recordingTimerLabel.isHidden = true
        recordingTimerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recordingTimerLabel)

        NSLayoutConstraint.activate([
            recordingTimerLabel.topAnchor.constraint(equalTo: cameraContentView.topAnchor, constant: 12),
            recordingTimerLabel.trailingAnchor.constraint(equalTo: cameraContentView.trailingAnchor, constant: -12),
            recordingTimerLabel.widthAnchor.constraint(equalToConstant: 86),
            recordingTimerLabel.heightAnchor.constraint(equalToConstant: 36)
        ])
        chessWebController.didMove(toParent: self)
        cameraController.didMove(toParent: self)
    }

    @objc func openRecordings() {
        guard let fileStore else {
            showError(storageError ?? RecordingFileStore.StoreError.invalidBroadcastFile)
            return
        }
        navigationController?.pushViewController(RecordingsViewController(fileStore: fileStore), animated: true)
    }

    @objc func openSettings() {
        let controller = SettingsViewController(settings: settings)
        controller.onSave = { [weak self] updatedSettings in
            self?.applySettings(updatedSettings)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    func applySettings(_ updatedSettings: AppSettings) {
        let siteChanged = settings.site != updatedSettings.site
        let fractionChanged = settings.boardFraction != updatedSettings.boardFraction
        settings = updatedSettings
        settings.save()
        if siteChanged { chessWebController.show(settings.site) }
        cameraController.setMirrored(settings.mirrorCamera)
        if fractionChanged {
            webHeightConstraint.isActive = false
            webHeightConstraint = chessWebController.view.heightAnchor.constraint(
                equalTo: cameraController.view.heightAnchor,
                multiplier: CGFloat(settings.boardFraction / (1 - settings.boardFraction))
            )
            webHeightConstraint.isActive = true
        }
    }

    @objc func pollBroadcastStatus() {
        let status = BroadcastRecordingStatus.load()
        if let status, status.isActive {
            if (status.phase == .recording || status.phase == .finishing), status.startedAt > 0 {
                let startedAt = Date(timeIntervalSince1970: status.startedAt)
                if !isRecordingUI { enterRecordingMode(startedAt: startedAt) }
            }
        } else if isRecordingUI {
            leaveRecordingMode()
        }

        if let status, !status.isActive, !handledStatusIDs.contains(status.id) {
            switch status.phase {
            case .failed:
                handledStatusIDs.insert(status.id)
                showMessage(status.message ?? "Запись не удалась.")
            case .finished:
                // The ready file is imported below; report completion afterwards.
                break
            case .starting, .recording, .finishing:
                if Date().timeIntervalSince1970 - status.updatedAt > 5 {
                    handledStatusIDs.insert(status.id)
                    showMessage("Трансляция прервалась до завершения записи.")
                }
            }
        }
        importFinishedBroadcasts()
    }

    func importFinishedBroadcasts() {
        guard !isImporting, let fileStore else { return }
        guard let ready = try? fileStore.readyBroadcastURLs() else { return }
        let due = ready.filter { url in
            guard let failedAt = failedImportAt[url] else { return true }
            return Date().timeIntervalSince(failedAt) > 30
        }
        guard !due.isEmpty else { return }
        isImporting = true
        broadcastPicker.isUserInteractionEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isImporting = false
                self.broadcastPicker.isUserInteractionEnabled = true
            }
            for url in due {
                do {
                    let recording = try await fileStore.importBroadcastRecording(at: url)
                    self.handledStatusIDs.insert(recording.id.uuidString)
                    if self.settings.saveToPhotos {
                        do {
                            try await self.photoExporter.saveVideo(at: recording.url)
                            self.showMessage("Видео сохранено в ChessCam и Фото")
                        } catch {
                            self.showMessage("Видео сохранено в ChessCam. Не удалось добавить его в Фото: \(error.localizedDescription)")
                        }
                    } else {
                        self.showMessage("Видео сохранено в ChessCam")
                    }
                } catch {
                    self.failedImportAt[url] = Date()
                    self.showError(error)
                    break
                }
            }
        }
    }

    func enterRecordingMode(startedAt: Date) {
        isRecordingUI = true
        recordingStartDate = startedAt
        recordingTimerLabel.isHidden = false
        updateRecordingTimer()
        recordingTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(updateRecordingTimer),
            userInfo: nil,
            repeats: true
        )
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func leaveRecordingMode() {
        isRecordingUI = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        recordingTimerLabel.isHidden = true
        UIApplication.shared.isIdleTimerDisabled = false
    }

    @objc func updateRecordingTimer() {
        guard let recordingStartDate else { return }
        let seconds = Int(Date().timeIntervalSince(recordingStartDate))
        recordingTimerLabel.text = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func showError(_ error: Error) {
        let alert = UIAlertController(title: "Ошибка", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
